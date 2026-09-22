#!/usr/bin/env python3
"""Agent-container gateway: serves each registered session's Unix sockets.

For every session in the sessions file (agent.py writes one, for one
long-running agent session) it creates, inside that session's own socket
directory:
  minerva.sock, docket.sock, nudge.sock  filtered MCP (mcp_http + mcp_policy)
  proxy.sock                             HTTPS CONNECT egress (connect_proxy)
A dev container mounts only its own session's directory. Nothing here listens
on TCP; the upstreams are the host's loopback MCP services. Which Minerva
terminal is attached (and may be notified) is read from the session's
binding file on every call: agent.py rewrites it on each attach, since a
restarted Minerva hands out new terminal ids. A binding carries a lease
(expires_at) that the attached launcher keeps renewing, so an attach that
died without cleaning up stops routing notifications once its lease lapses.
The session's note grants (control/notes.json) are read the same way.

Usage: gateway.py --config gateway.json --sessions sessions.json
The gateway never removes files: an existing socket path refuses startup, so
each run gets a fresh socket directory from the launcher.
"""
import argparse
import os
from pathlib import Path
import re
import stat
import sys
import threading
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import connect_proxy  # noqa: E402
import mcp_http  # noqa: E402
import mcp_policy  # noqa: E402
import strict_json  # noqa: E402

SERVICES = ("minerva", "docket", "nudge")
SESSION_KEYS = {"name", "harness", "socket_dir", "docket_projects", "control_dir"}
SESSION_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
TERMINAL_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
MAX_BINDING = 4096


def _control_json(path):
    try:
        with open(path, "rb") as f:
            return strict_json.loads(f.read(MAX_BINDING + 1), MAX_BINDING)
    except (OSError, strict_json.StrictJSONError):
        return None


def read_binding(path, now=time.time):
    """The session's current Binding. Anything missing, malformed or past its
    lease reads as unattached, so a broken or abandoned file can only take
    notify away, never widen it."""
    data = _control_json(path)
    if not isinstance(data, dict) or set(data) != {"terminal_id", "notify_targets", "generation",
                                                   "expires_at"}:
        return mcp_policy.UNATTACHED
    terminal_id, targets, expires = data["terminal_id"], data["notify_targets"], data["expires_at"]
    if not isinstance(terminal_id, str) or not TERMINAL_ID.fullmatch(terminal_id) \
            or not isinstance(targets, list) \
            or not all(isinstance(t, str) and TERMINAL_ID.fullmatch(t) for t in targets) \
            or not isinstance(data["generation"], str) \
            or isinstance(expires, bool) or not isinstance(expires, (int, float)) or expires <= now():
        return mcp_policy.UNATTACHED
    return mcp_policy.Binding(terminal_id, frozenset(targets))


def read_notes(path):
    """The session's NoteGrants; anything missing or malformed grants none."""
    data = _control_json(path)
    if not isinstance(data, dict) or set(data) != {"read", "write"}:
        return mcp_policy.NO_NOTES
    ids = [data["read"], data["write"]]
    if not all(isinstance(v, list) and all(isinstance(i, str) and mcp_policy.NOTE_ID.fullmatch(i)
                                           for i in v) for v in ids):
        return mcp_policy.NO_NOTES
    return mcp_policy.NoteGrants(frozenset(data["read"]), frozenset(data["write"]))


def load_json(path):
    with open(path, "rb") as f:
        return strict_json.loads(f.read(), 1024 * 1024)


def check_socket_dir(path):
    """The directory must be a real directory owned by us and closed to
    everyone else: its sockets are that session's only credential."""
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"socket_dir is not a directory: {path}")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError(f"socket_dir must be owned by this user with mode 0700: {path}")


def parse_session(entry):
    if not isinstance(entry, dict) or set(entry) != SESSION_KEYS:
        raise ValueError(f"session needs exactly {sorted(SESSION_KEYS)}")
    if not isinstance(entry["name"], str) or not SESSION_NAME.fullmatch(entry["name"]):
        raise ValueError("session name malformed")
    if entry["harness"] not in ("claude", "codex"):
        raise ValueError("harness must be claude or codex")
    projects = entry["docket_projects"]
    if not isinstance(projects, list) or not all(isinstance(v, str) for v in projects):
        raise ValueError("docket_projects must be a list of strings")
    if not isinstance(entry["control_dir"], str) or not entry["control_dir"].startswith("/"):
        raise ValueError("control_dir must be an absolute path")
    check_socket_dir(entry["socket_dir"])
    control = Path(entry["control_dir"])
    session = mcp_policy.Session(entry["name"], entry["harness"], frozenset(projects),
                                 lambda: read_binding(control / "binding.json"),
                                 lambda: read_notes(control / "notes.json"))
    return session, Path(entry["socket_dir"])


def build_servers(config, sessions_data, resolve=connect_proxy.system_resolve,
                  connect=connect_proxy.system_connect):
    """All servers for all sessions, bound but not yet serving. Everything is
    validated before the first socket is created."""
    if set(config) != {"upstreams", "policy", "egress"}:
        raise ValueError("config needs exactly upstreams, policy, egress")
    upstreams = {name: mcp_http.Upstream.parse(config["upstreams"][name]) for name in SERVICES}
    policy = mcp_policy.Policy.load(HERE / config["policy"])
    allowlist = connect_proxy.Allowlist.load(HERE / config["egress"])
    if set(sessions_data) != {"sessions"}:
        raise ValueError("sessions file needs exactly a sessions list")
    sessions = [parse_session(e) for e in sessions_data["sessions"]]
    names = [s.name for s, _ in sessions]
    if len(names) != len(set(names)):
        raise ValueError("duplicate session name")
    names = [f"{n}.sock" for n in SERVICES] + ["proxy.sock"]
    taken = [str(d / n) for _, d in sessions for n in names if os.path.lexists(d / n)]
    if taken:
        raise ValueError(f"socket path(s) already exist, not replacing: {taken}")
    servers = []
    for session, sock_dir in sessions:
        for name in SERVICES:
            service = mcp_http.Service(name, upstreams[name], policy, session)
            servers.append(mcp_http.make_server(str(sock_dir / f"{name}.sock"), service))
        servers.append(connect_proxy.make_server(str(sock_dir / "proxy.sock"),
                                                 session.name, allowlist, resolve, connect))
    return servers


def serve(servers):
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in threads:
        t.start()
    return threads


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True)
    parser.add_argument("--sessions", required=True)
    args = parser.parse_args()
    servers = build_servers(load_json(args.config), load_json(args.sessions))
    mcp_http.log({"kind": "start", "sockets": len(servers)})
    for t in serve(servers):
        t.join()


if __name__ == "__main__":
    main()
