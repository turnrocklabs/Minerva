#!/usr/bin/env python3
"""Trusted host launcher for agent containers (one harness per session).

  agent.py build
  agent.py create NAME --harness claude|codex --folder PATH... [--start-in PATH]
                  [--project P]... [--mode start|resume|shell] [--profile PROFILE]
  agent.py start NAME [--mode MODE] [--note-read ID]... [--note-write ID]...
  agent.py attach NAME
  agent.py up NAME [start options] [attach options]     start if needed, then attach
  agent.py grant NAME [--note-read ID]... [--note-write ID]... [--notify]
  agent.py revoke NAME [--note-read ID]... [--note-write ID]... [--notify]
  agent.py notes NAME [--note-read ID]... [--note-write ID]...   replace the note grants
  agent.py identity NAME [--identity ID [--role ROLE]]   set (or, bare, clear) the Docket identity
  agent.py stop NAME
  agent.py status NAME
  agent.py info NAME [--map HOST_PATH]...
  agent.py readiness NAME [--profile PROFILE]
  agent.py provision NAME [--tool TOOL]...
  agent.py profiles
  agent.py list
  agent.py run-job NAME --rev REV --command CMD [--env K=V]... [--artifact PATH]...
                   [--cpus N] [--memory SIZE] [--seconds S] [--folder PATH]
  agent.py job-status NAME [JOB]
  agent.py job-log NAME JOB [--tail BYTES]
  agent.py drain NAME [--wait S] [--lift]
Every command takes --json: one JSON object on stdout, {"ok": true, ...} or
{"ok": false, "error": ...}. Minerva drives sessions this way.

A session is a record: harness, the host folders it mounts, the folder the
harness starts in, its Docket projects, its default mode and its toolchain
profile ("profile"; a record without one uses "default"). `create` writes
it; `start` and `up` also create it when given --harness and --folder and no
record exists, and otherwise refuse options that differ from it.

A session is long-running: `start` launches its gateway and dev containers
detached. In the dev container a tmux session holds an interactive shell
(the harness's environment already set) that first runs the harness, or its
resume picker, or nothing (--mode). Leaving the harness drops to that shell;
leaving the shell ends the session. `attach`, run in a Minerva terminal,
joins the tmux session as its only client. Closing or crashing Minerva only
detaches; `attach` from any new terminal reconnects to the same shell, never
starting a new harness or model turn. Minerva runs it for the owner: the tab
action "Attach agent session here" and minerva_agent_session_attach write
this command into a tab at its shell prompt (AgentSessionStore.attach).

Attaching binds the session to that terminal for notify routing: a binding
file carries the terminal id (the reply address, and the one terminal the
session may not notify), a generation token and a lease that the attached
launcher renews. An attach that dies without cleaning up stops routing once
its lease lapses. A per-session lock serializes create, start, stop and
attach ownership; grant changes have a lock of their own.

One tab fronts a session at a time, and the newest attach wins: attaching
while another tab holds the lease takes the session over. The new client
attaches with tmux -d, which detaches the old one, and the binding moves to
the new terminal; the old tab's launcher sees the binding is no longer its
own, says the session was attached from another tab, and returns that tab to
its shell. An attach that fails to establish puts the previous holder's
binding back, so a failed takeover leaves the old tab fronting. Since any
attach takes over, a lease left by a crashed launcher never blocks one (it
also lapses on its own), and no recovery flag exists.

Grants. What a session may do beyond the fixed gateway policy is one record,
control/grants.json: {"version": 1, "note_read": [NOTE_ID...], "note_write":
[NOTE_ID...], "notify": true|false}. Write implies read. notify lets the
session notify any Minerva tab with a harness in front except its own; there
is no per-target list. Minerva changes the record with `grant` and `revoke`
(GUI and minerva_agent_session_grant/revoke) at any time, running or not,
with no re-attach; the gateway reads it on every call, so the next
call sees the change. `revoke --note-read` removes only the read entry and
`revoke --note-write` only the write entry.
The record also carries the session identity and role Minerva registered for
it (HarnessSessionRegistry), as "identity" and "role", written by `identity`
whenever that registration changes and absent while there is none. The
gateway scopes the session's Docket access to the work assigned or directed
to them (gateway/docket_scope.py).
Migration: a session with no grants.json (started by an earlier agent.py)
gets one from its control/notes.json, with notify on, when it next starts or
its grants are next changed. Every grant change also rewrites notes.json
({"read", "write"}), which is what a gateway started by an earlier agent.py
reads per call, so such a running session follows note grants without a
restart; its notify still follows attach --notify-to until it restarts.

Everything a session keeps lives under the state root
(${MINERVA_AGENT_STATE:-${XDG_STATE_HOME:-~/.local/state}/minerva-agent}):
  sessions/NAME/session.json          the session record (never replaced)
  sessions/NAME/home/                 the harness's own config dir: login,
                                      settings, transcripts (the owner logs in
                                      there once, inside the harness)
  sessions/NAME/control/binding.json  attached terminal and its lease
  sessions/NAME/control/grants.json   notes the session may read/write, notify
  sessions/NAME/control/notes.json    the note grants, for gateways that predate
                                      grants.json
  sessions/NAME/launcher.json         the attached launcher's process group and
                                      the container's init, for Minerva to see
                                      the harness in front (host-only)
  run/NAME-*/                         one gateway run's sessions.json + sockets,
                                      and natives.json (see natives_manifest)

Folders. A folder that is a git checkout is never mounted itself: the session
gets an independent clone of it under ${MINERVA_AGENT_WORK:-~/agent-work}/NAME/,
made once at the first start and mounted at its own absolute path, so the
host never runs git inside a directory the container can write. Any other
folder is mounted read-write at its own path; one holding a git checkout
within a few levels is refused (choose that checkout, which is cloned). The
start folder is a host path inside one of the folders; the harness starts at
the matching path inside the container. Docket projects are --project, or
else discovered from the .dct files near the top of each folder.

`info` adds what a session is, for inspection: the path mappings (host
folder, the path the harness sees, and the session home at /agent-home),
the Git author identity git reports in its start folder, and its toolchain
profile with its tools. `readiness` checks the session's profile (or, for a
what-if, --profile) for tools and minimum versions, the folders and the Git
identity inside the running container, and the session's Docket projects
against the Docket service, and lists what is missing. Both are read-only
(readiness.py). `profiles` lists the profiles on offer: the shipped
profiles.json plus the user's file named by $MINERVA_AGENT_PROFILES.
`provision` installs, inside the running session, the profile tools that are
missing or too old and whose profile entry names an official download
(provision.py); the image is not rebuilt.

Jobs. `run-job` runs one planned command at an exact revision of a session
clone in its own bounded container and classifies how it ended: succeeded,
failed, timed_out, interrupted or unknown. `drain` stops new jobs and stops
only the jobs it started, which end interrupted and are never retried.
jobs.py has the revision, dirty-tree and classification rules.

Records written before folders existed (a task and a list of repository
names, cloned under the work root's TASK/) still start, stop and attach:
their folders are the task clones they already have.
This tool never deletes files and never runs git inside an existing clone.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent / "container-build"))
import build as container_build  # noqa: E402  the builder image and native cache
import readiness  # noqa: E402  profiles and the read-only probe
import jobs  # noqa: E402  planned jobs and drain
import provision  # noqa: E402  profile tools installed into a running session
COMPOSE = HERE / "docker-compose.yml"
IMAGE_FILES = ["Dockerfile", "forwarder.py", "minerva-session", "agent-env.sh", "agent-bashrc",
               "agent-upgrade", "tmux.conf", "claude-mcp.json", "smoke.py"]
HARNESSES = ["claude", "codex"]
MODES = ["start", "resume", "shell"]
RECORD_VERSION = 2
RECORD_KEYS = {"version", "harness", "folders", "start_in", "projects", "mode"}
# Optional in a record: records from before profiles use the default.
PROFILE_KEY = "profile"
LEGACY_KEYS = {"harness", "task", "repos", "projects"}
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
TERMINAL_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
NOTE_ID = re.compile(r"[0-9a-f]{32,64}")
GRANTS_VERSION = 1
GRANTS_KEYS = {"version", "note_read", "note_write", "notify"}
IDENTITY_KEYS = {"identity", "role"}
# The registry's identity and role alphabet (HarnessSessionRegistry._validate).
PRINCIPAL = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
# Keeps grants.json under the gateway's read limit (gateway.MAX_GRANTS).
MAX_GRANTED_NOTES = 256
PROJECT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
LEGACY_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
NATIVES_MANIFEST = "/run/minerva-natives.json"
# The session home (the harness's config dir) as the dev container mounts it.
HOME_IN_CONTAINER = "/agent-home"
# Characters that would change the meaning of a `docker -v src:dst[:ro]`.
UNSAFE_PATH = re.compile(r"[:,\n\r\0]")
# How far below a folder's top .dct files are discovered and nested git
# checkouts refused; these directories are never entered.
SCAN_DEPTH = 3
SCAN_SKIP = {".git", "node_modules", ".godot", "__pycache__"}
SOCKETS = ("minerva", "docket", "nudge", "proxy")
SOCKET_WAIT_S = 15
ATTACH_WAIT_S = 10
TMUX_QUERY_TIMEOUT_S = float(os.environ.get("MINERVA_AGENT_TMUX_QUERY_TIMEOUT_S", "10"))


class Refused(Exception):
    """A request the launcher will not carry out; the message says why."""


# ── locations and their safety ─────────────────────────────────────────────

def state_root():
    if os.environ.get("MINERVA_AGENT_STATE"):
        return Path(os.environ["MINERVA_AGENT_STATE"])
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(base) / "minerva-agent"


def work_root():
    return Path(os.environ.get("MINERVA_AGENT_WORK") or Path.home() / "agent-work")


def lease_s():
    value = os.environ.get("MINERVA_AGENT_LEASE_S", "60")
    if not value.isdigit() or not 2 <= int(value) <= 3600:
        raise Refused("MINERVA_AGENT_LEASE_S must be 2-3600 seconds")
    return int(value)


def _within(inner, outer):
    return inner == outer or outer in inner.parents


def check_layout(folders=()):
    """Before anything is written, stopped or cloned: the state and work roots
    must be plain absolute paths (no symlinked component, nothing docker -v
    would misparse), neither may hold all of HOME, the state root (control
    files, sockets) must be disjoint from the work root, whose clones the dev
    container can write, and no session folder may overlap either root."""
    home = Path(os.path.realpath(Path.home()))
    for label, path in {"state root": state_root(), "work root": work_root()}.items():
        if not path.is_absolute() or UNSAFE_PATH.search(str(path)):
            raise Refused(f"{label} {path} must be an absolute path without ':' or ','")
        if os.path.realpath(path) != os.path.abspath(path):
            raise Refused(f"{label} {path} goes through a symlink")
    state, work = Path(os.path.abspath(state_root())), Path(os.path.abspath(work_root()))
    if _within(home, work):
        raise Refused(f"work root {work} would expose all of {home}")
    if _within(home, state):
        raise Refused(f"state root {state} would hold all of {home}")
    if _within(state, work) or _within(work, state):
        raise Refused(f"state root {state} and work root {work} must not contain each other")
    for folder in map(Path, folders):
        for label, root in (("work root", work), ("state root", state)):
            if _within(root, folder) or _within(folder, root):
                raise Refused(f"{label} {root} overlaps the folder {folder}")


def plain_folder(value):
    """value as an absolute, existing directory reached through no symlink,
    that docker -v reads unchanged and that does not hold all of HOME."""
    path = Path(os.path.abspath(os.path.expanduser(value)))
    if UNSAFE_PATH.search(str(path)):
        raise Refused(f"folder {path} contains ':' or ','")
    if not path.is_dir():
        raise Refused(f"{path} is not a directory")
    if os.path.realpath(path) != str(path):
        raise Refused(f"{path} goes through a symlink")
    home = Path(os.path.realpath(Path.home()))
    if _within(home, path):
        raise Refused(f"folder {path} would expose all of {home}")
    return path


def scan(root):
    """Every entry within SCAN_DEPTH directory levels of root (root's own
    entries are the first level), in name order level by level, never
    following symlinks or entering SCAN_SKIP."""
    level = [str(root)]
    for _ in range(SCAN_DEPTH):
        deeper = []
        for directory in level:
            try:
                with os.scandir(directory) as it:
                    found = sorted(it, key=lambda e: e.name)
            except OSError:
                continue
            for entry in found:
                yield entry
                if entry.name not in SCAN_SKIP and entry.is_dir(follow_symlinks=False):
                    deeper.append(entry.path)
        level = deeper


def is_checkout(path):
    return os.path.lexists(Path(path) / ".git")


def discover_projects(folders):
    """Docket project names for the .dct files near the top of each folder.
    Docket registers a file under its stem or its whole name, so both are
    allowed; a name no project uses matches nothing."""
    names = []
    for folder in folders:
        for entry in scan(folder):
            if entry.name.endswith(".dct") and entry.is_file(follow_symlinks=False):
                for name in (entry.name[:-4], entry.name):
                    if PROJECT.fullmatch(name) and name not in names:
                        names.append(name)
    return names


def build_record(name, harness, folders, start_in, projects, mode, profile=""):
    """The record for a new session, from host paths; nothing is written. An
    empty profile is left out of the record, which then uses the default."""
    if harness not in HARNESSES:
        raise Refused(f"harness must be one of {', '.join(HARNESSES)}")
    if mode not in MODES:
        raise Refused(f"mode must be one of {', '.join(MODES)}")
    hosts = [plain_folder(f) for f in folders or []]
    if not hosts:
        raise Refused("a session mounts at least one folder (--folder)")
    for i, a in enumerate(hosts):
        for b in hosts[i + 1:]:
            if _within(a, b) or _within(b, a):
                raise Refused(f"folders {a} and {b} overlap")
    check_layout(hosts)
    records, labels = [], set()
    for host in hosts:
        if is_checkout(host):
            label, n = host.name, 2
            while label in labels:
                label, n = f"{host.name}-{n}", n + 1
            labels.add(label)
            records.append({"host": str(host), "path": str(work_root() / name / label), "kind": "clone"})
            continue
        nested = next((e.path for e in scan(host) if e.name == ".git"), None)
        if nested:
            raise Refused(f"{host} holds the git checkout {Path(nested).parent}: choose that checkout "
                          "(it is cloned) or a folder without one")
        records.append({"host": str(host), "path": str(host), "kind": "mount"})
    start = plain_folder(start_in) if start_in else hosts[0]
    workdir = container_path(records, start)
    if workdir is None:
        raise Refused(f"start folder {start} is not inside a session folder")
    projects = list(projects) if projects else discover_projects(hosts)
    for project in projects:
        if not PROJECT.fullmatch(project):
            raise Refused(f"bad Docket project name {project!r}")
    record = {"version": RECORD_VERSION, "harness": harness, "folders": records,
              "start_in": workdir, "projects": projects, "mode": mode}
    if profile:
        try:
            readiness.load_profile(profile)
        except readiness.ProfileError as exc:
            raise Refused(str(exc))
        record[PROFILE_KEY] = profile
    return record


def record_profile(record):
    """(profile name, how it was chosen): the record's, else the default."""
    if record.get(PROFILE_KEY):
        return record[PROFILE_KEY], "session"
    return readiness.DEFAULT_PROFILE, "default"


def container_path(folders, host_path):
    """The path the harness sees for a host path, or None when no session
    folder holds it. `folders` are record folders ({host, path}); a host path
    inside a checkout, or inside its clone, maps into the clone's path."""
    path = Path(os.path.abspath(os.path.expanduser(str(host_path))))
    for folder in folders:
        for root in (folder["host"], folder["path"]):
            if root and _within(path, Path(root)):
                return str(Path(folder["path"]) / path.relative_to(root))
    return None


def record_view(name, saved):
    """A saved record in the current shape, or Refused when it is unreadable.
    A record from before folders (task + repository names) becomes the task
    clones it already has, starting in its start_in repository."""
    path = record_path(name)
    if isinstance(saved, dict) and set(saved) - {PROFILE_KEY} == RECORD_KEYS \
            and saved["version"] == RECORD_VERSION \
            and (PROFILE_KEY not in saved or (isinstance(saved[PROFILE_KEY], str)
                                             and readiness.PROFILE_NAME.fullmatch(saved[PROFILE_KEY]))) \
            and saved["harness"] in HARNESSES and saved["mode"] in MODES \
            and isinstance(saved["folders"], list) and saved["folders"] \
            and all(isinstance(f, dict) and set(f) == {"host", "path", "kind"}
                    and f["kind"] in ("clone", "mount") for f in saved["folders"]) \
            and isinstance(saved["projects"], list):
        return saved
    if isinstance(saved, dict) and LEGACY_KEYS <= set(saved) <= LEGACY_KEYS | {"start_in"} \
            and saved["harness"] in HARNESSES and isinstance(saved["task"], str) \
            and NAME.fullmatch(saved["task"]) and isinstance(saved["repos"], list) and saved["repos"] \
            and all(isinstance(r, str) and LEGACY_REPO.fullmatch(r) for r in saved["repos"]) \
            and isinstance(saved["projects"], list):
        work = work_root() / saved["task"]
        start = saved.get("start_in") or saved["repos"][0]
        if start not in saved["repos"]:
            raise Refused(f"{path} starts in {start!r}, which it does not mount")
        return {"version": 1, "harness": saved["harness"], "task": saved["task"],
                "folders": [{"host": "", "path": str(work / r), "kind": "clone"} for r in saved["repos"]],
                "start_in": str(work / start), "projects": saved["projects"], "mode": "start"}
    raise Refused(f"{path} is unreadable or incomplete; fix it by hand or use a new name")


def load_record(name):
    """The session's record in the current shape, or None when it has none."""
    path = record_path(name)
    if not os.path.lexists(path):
        return None
    try:
        saved = json.loads(path.read_text())
    except (OSError, ValueError):
        saved = None
    return record_view(name, saved)


def check_folders(record):
    """Before any side effect, and again just before the mounts: every clone
    lies inside the work root with no symlinked component below it and is
    either present or clonable, and every directly mounted folder is still a
    plain directory at the path the record names."""
    work = Path(os.path.abspath(work_root()))
    for folder in record["folders"]:
        path = Path(folder["path"])
        if folder["kind"] == "mount":
            if plain_folder(path) != path or folder["host"] != folder["path"]:
                raise Refused(f"mounted folder {path} is no longer the plain directory recorded")
            continue
        if not path.is_absolute() or not _within(path.parent, work) or path.parent == work \
                or UNSAFE_PATH.search(str(path)):
            raise Refused(f"clone {path} is not inside the work root {work}")
        for p in (path.parent, path):
            if os.path.lexists(p) and (os.path.islink(p) or not os.path.isdir(p)
                                       or os.path.realpath(p) != str(p)):
                raise Refused(f"{p} is not a plain directory inside the work root")
        if not os.path.lexists(path):
            if not folder["host"]:
                raise Refused(f"{path} is missing and this session was created before folders, "
                              "so there is nothing to clone it from; create a new session")
            if not is_checkout(folder["host"]):
                raise Refused(f"{folder['host']} is not a git checkout")


def private_dir(path):
    """A directory only this user can use: created 0700, and an existing one
    must be a real directory, ours, with no group or other access."""
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refused(f"{path} must be a directory owned by you with no group/other access")
    return path


def containers(name):
    return f"minerva-agent-{name}", f"minerva-agent-gw-{name}"


def session_dir(name):
    return state_root() / "sessions" / name


def record_path(name):
    return session_dir(name) / "session.json"


def image_tag():
    """Content hash of everything that goes into the image."""
    digest = hashlib.sha256(container_build.builder_tag().encode() + b"\0")  # the base image
    files = [HERE / f for f in IMAGE_FILES] + sorted((HERE / "gateway").glob("*.py")) \
        + sorted((HERE / "gateway").glob("*.json"))
    for path in files:
        digest.update(str(path.relative_to(HERE)).encode() + b"\0" + path.read_bytes() + b"\0")
    return f"minerva-agent:{digest.hexdigest()[:12]}"


# ── docker ──────────────────────────────────────────────────────────────

def compose_env():
    return {**os.environ, "MINERVA_AGENT_IMAGE": image_tag(),
            "MINERVA_BUILDER_IMAGE": container_build.builder_tag(),
            "AGENT_UID": str(os.getuid()), "AGENT_GID": str(os.getgid())}


def compose(name, *args):
    return ["docker", "compose", "-f", str(COMPOSE), "--profile", "session",
            "-p", f"minerva-agent-{name}", *args]


def run(cmd, **kwargs):
    return subprocess.run(cmd, env=compose_env(), **kwargs)


def docker_state(container):
    """"running", "stopped", or "unknown" when docker cannot be asked."""
    try:
        probe = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                               capture_output=True, text=True)
    except FileNotFoundError:
        return "unknown"
    return "running" if probe.returncode == 0 and probe.stdout.strip() == "true" else "stopped"


def running(container):
    return docker_state(container) == "running"


def image_built(tag):
    try:
        return subprocess.run(["docker", "image", "inspect", tag], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


def container_identity(container):
    """(host pid, /proc start time) of the container's init, or (0, 0)."""
    probe = subprocess.run(["docker", "inspect", "-f", "{{.State.Pid}}", container],
                           capture_output=True, text=True)
    pid = probe.stdout.strip()
    if probe.returncode != 0 or not pid.isdigit() or int(pid) <= 0:
        return 0, 0
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return 0, 0
    fields = stat[stat.rfind(")") + 1:].split()
    start = fields[19] if len(fields) > 19 else ""
    return (int(pid), int(start)) if start.isdigit() and int(start) > 0 else (0, 0)


def stop(*names):
    for container in names:
        if running(container):
            subprocess.run(["docker", "stop", container], capture_output=True)


def bind_mount(source, target, read_only=False):
    for path in (source, target):
        if UNSAFE_PATH.search(str(path)):
            raise Refused(f"mount path {path} contains ':' or ','")
    return ["-v", f"{source}:{target}" + (":ro" if read_only else "")]


# ── control files ────────────────────────────────────────────────────────────

def write_json(path, value, mode=0o600):
    """Write via a temp file and rename, so readers never see a partial file."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


@contextlib.contextmanager
def session_lock(name, lock="lock"):
    """Serializes create, start, stop and binding changes for one session.
    Grant changes take their own lock ("grants.lock"), so they never wait
    behind a start that is cloning."""
    private_dir(state_root())
    private_dir(state_root() / "sessions")
    sdir = private_dir(session_dir(name))
    fd = os.open(sdir / lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def binding_path(name):
    return session_dir(name) / "control" / "binding.json"


def launcher_path(name):
    return session_dir(name) / "launcher.json"


def attached_terminal(name):
    """The terminal holding a live attach lease, or ""."""
    binding = read_json(binding_path(name))
    expires = binding.get("expires_at") if isinstance(binding, dict) else None
    if isinstance(expires, (int, float)) and not isinstance(expires, bool) and expires > time.time():
        return str(binding.get("terminal_id", ""))
    return ""


def grants_path(name):
    return session_dir(name) / "control" / "grants.json"


def _note_ids(value):
    return isinstance(value, list) and all(isinstance(i, str) and NOTE_ID.fullmatch(i) for i in value)


def _principals(identity, role):
    return isinstance(identity, str) and bool(PRINCIPAL.fullmatch(identity)) \
        and isinstance(role, str) and (role == "" or bool(PRINCIPAL.fullmatch(role)))


def load_grants(name):
    """(grants, problem) for session `name`. With no grants.json the record is
    the one migration gives: notes.json's note grants, notify on. A malformed
    grants.json reads as no grants at all, as the gateway reads it, and
    `problem` says so."""
    empty = {"version": GRANTS_VERSION, "note_read": [], "note_write": [], "notify": False}
    path = grants_path(name)
    if os.path.lexists(path):
        data = read_json(path)
        if isinstance(data, dict) and set(data) in (GRANTS_KEYS, GRANTS_KEYS | IDENTITY_KEYS) \
                and type(data["version"]) is int \
                and data["version"] == GRANTS_VERSION and isinstance(data["notify"], bool) \
                and _note_ids(data["note_read"]) and _note_ids(data["note_write"]) \
                and ("identity" not in data or _principals(data["identity"], data["role"])):
            return data, ""
        return empty, f"{path} is malformed, so the session holds no grants; grant again to rewrite it"
    notes = read_json(session_dir(name) / "control" / "notes.json")
    ok = isinstance(notes, dict) and set(notes) == {"read", "write"} \
        and _note_ids(notes["read"]) and _note_ids(notes["write"])
    return {"version": GRANTS_VERSION, "note_read": notes["read"] if ok else [],
            "note_write": notes["write"] if ok else [], "notify": True}, ""


def save_grants(name, grants):
    """Under the grants lock: write grants.json, and notes.json in step for a
    gateway started before grants.json."""
    for key in ("note_read", "note_write"):
        for note in grants[key]:
            if not NOTE_ID.fullmatch(note):
                raise Refused(f"bad note id {note!r}")
        grants[key] = sorted(set(grants[key]))
        if len(grants[key]) > MAX_GRANTED_NOTES:
            raise Refused(f"a session holds at most {MAX_GRANTED_NOTES} {key} grants")
    control = private_dir(session_dir(name) / "control")
    write_json(control / "grants.json", grants)
    write_json(control / "notes.json", {"read": grants["note_read"], "write": grants["note_write"]})
    return grants


def write_notes(name, read, write):
    """Replace the note grants, keeping the notify grant."""
    with session_lock(name, "grants.lock"):
        grants, _ = load_grants(name)
        return save_grants(name, {**grants, "note_read": list(read or []), "note_write": list(write or [])})


def ensure_grants(name):
    """Migration: a session with no grants.json gets the record load_grants
    derives from its notes.json."""
    with session_lock(name, "grants.lock"):
        if not grants_path(name).exists():
            save_grants(name, load_grants(name)[0])


def change_grants(name, add, read, write, notify):
    """grant (add=True) or revoke the given entries; returns the new record."""
    for note in (read or []) + (write or []):
        if not NOTE_ID.fullmatch(note):
            raise Refused(f"bad note id {note!r}")
    if not (read or write or notify):
        raise Refused("name at least one grant: --note-read, --note-write or --notify")
    with session_lock(name, "grants.lock"):
        grants = dict(load_grants(name)[0])
        for key, ids in (("note_read", read or []), ("note_write", write or [])):
            current = set(grants[key])
            grants[key] = list(current | set(ids) if add else current - set(ids))
        if notify:
            grants["notify"] = add
        return save_grants(name, grants)


def set_identity(name, identity, role):
    """Record the session identity and role (or, with identity "", remove
    them), keeping every other grant."""
    if identity and not _principals(identity, role or ""):
        raise Refused("identity and role are 1-64 letters, digits and . _ : -")
    if role and not identity:
        raise Refused("a role needs an identity")
    with session_lock(name, "grants.lock"):
        grants = {k: v for k, v in load_grants(name)[0].items() if k not in IDENTITY_KEYS}
        if identity:
            grants.update(identity=identity, role=role or "")
        return save_grants(name, grants)


def sockets_ready(sock):
    paths = [sock / f"{s}.sock" for s in SOCKETS]
    return all(os.path.lexists(p) and stat.S_ISSOCK(os.lstat(p).st_mode) for p in paths)


# ── folders ──────────────────────────────────────────────────────────────

def ensure_clone(folder):
    """The session's clone of a checkout folder, made once with independent
    object files. An existing clone is used as it is: the host never runs git
    inside a clone an agent can modify (its .git/config could make git run
    code)."""
    dest = Path(folder["path"])
    if os.path.lexists(dest):
        if dest.is_symlink() or not dest.is_dir():
            raise Refused(f"{dest} exists and is not a directory")
        return dest
    src = Path(folder["host"])
    if not folder["host"] or not is_checkout(src):
        raise Refused(f"{src} is not a git checkout")
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--no-hardlinks", "--quiet", "--", str(src), str(dest)],
                   check=True)
    return dest


# ── records ──────────────────────────────────────────────────────────────

def resolve_record(args):
    """(record, new) for start and up: the saved record, refusing any option
    that differs from it, or a new record from --harness and --folder."""
    saved = load_record(args.name)
    if saved is None:
        if args.task:
            raise Refused(f"no session {args.name}; --task only names a session created before "
                          "folders, a new one takes --folder")
        if not (args.harness and args.folder):
            raise Refused(f"no session {args.name}: create it first "
                          f"(agent.py create {args.name} --harness H --folder PATH)")
        return build_record(args.name, args.harness, args.folder, args.start_in, args.project,
                            args.mode or "start", args.profile or ""), True
    differs = (args.harness and args.harness != saved["harness"]) \
        or (args.task and args.task != saved.get("task")) \
        or (args.profile and args.profile != record_profile(saved)[0])
    if not differs and (args.folder or args.start_in or args.project):
        if saved["version"] != RECORD_VERSION:
            raise Refused(f"session {args.name} was created before folders; its folders cannot be "
                          "given again, start it by name")
        wanted = build_record(args.name, saved["harness"],
                              args.folder or [f["host"] for f in saved["folders"]],
                              args.start_in, args.project, saved["mode"])
        differs = (args.folder and wanted["folders"] != saved["folders"]) \
            or (args.start_in and wanted["start_in"] != saved["start_in"]) \
            or (args.project and wanted["projects"] != saved["projects"])
    if differs:
        raise Refused(f"session {args.name} was created with different settings "
                      f"({record_path(args.name)}); use those, or a new name")
    return saved, False


def describe(name, record):
    """A record as Minerva lists it, with its live state."""
    state = docker_state(containers(name)[0])
    result = {"ok": True, "id": name, "harness": record["harness"], "folders": record["folders"],
              "start_in": record["start_in"], "projects": record["projects"], "mode": record["mode"],
              "profile": record_profile(record)[0],
              "state": state, "attached_terminal": attached_terminal(name) if state == "running" else "",
              "record": "folders" if record["version"] == RECORD_VERSION else "legacy"}
    result["grants"], problem = load_grants(name)
    if problem:
        result["grants_error"] = problem
    if "task" in record:
        result["task"] = record["task"]
    folders = ", ".join(f["host"] or f["path"] for f in record["folders"])
    result["message"] = f"{name:24} {state:8} {record['harness']:7} {folders}"
    return result


# ── commands ─────────────────────────────────────────────────────────────

def cmd_build(args):
    container_build.ensure_image()  # the agent image is built on the builder image
    code = run(compose("build", "build", "gateway")).returncode
    if args.json:
        tag = image_tag()
        return {"ok": code == 0, "image": tag, "error": "" if code == 0 else f"building {tag} failed",
                "message": tag}
    return code


def natives_manifest(run_dir):
    """Write run_dir/natives.json for dev-natives.py and return the mounts that
    carry it: the builder image the agent image was built on, and the native
    build cache, mounted read-only at its own path so symlinks into it resolve
    on the host too. The container reads this but cannot change it."""
    tag = container_build.builder_tag()
    probe = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", tag],
                           capture_output=True, text=True)
    if probe.returncode != 0 or not probe.stdout.strip():
        raise Refused(f"builder image {tag} is missing: run `agent.py build` first")
    try:
        cache = container_build.cache_root()
    except SystemExit as exc:
        raise Refused(str(exc))
    builds = cache / "builds"
    has_cache = builds.is_dir() and not builds.is_symlink()
    write_json(run_dir / "natives.json", {"builder_image": {"tag": tag, "id": probe.stdout.strip()},
                                          "cache": str(cache) if has_cache else None})
    mounts = bind_mount(run_dir / "natives.json", NATIVES_MANIFEST, True)
    return mounts + (bind_mount(builds, builds, True) if has_cache else [])


def cmd_create(args):
    check_layout()
    record = build_record(args.name, args.harness, args.folder, args.start_in, args.project,
                          args.mode or "start", args.profile or "")
    with session_lock(args.name):
        saved = load_record(args.name)
        if saved is None:
            write_json(record_path(args.name), record)
        elif saved != record:
            raise Refused(f"session {args.name} already exists with different settings; use a new name")
    result = describe(args.name, record)
    result["message"] = f"session {args.name} created; start it with `agent.py start {args.name}`"
    return result


def cmd_start(args):
    check_layout()
    name = args.name
    record, new = resolve_record(args)
    check_layout([f["host"] for f in record["folders"] if f["host"]])
    check_folders(record)
    mode = args.mode or record["mode"]
    dev, gw = containers(name)
    tag = image_tag()
    if not image_built(tag):
        raise Refused(f"image {tag} is not built: run `agent.py build` first")
    with session_lock(name):
        if running(dev):
            raise Refused(f"session {name} is already running: use `agent.py attach {name}`")
        home = private_dir(session_dir(name) / "home")
        control = private_dir(session_dir(name) / "control")
        if new:
            if load_record(name) is not None:
                raise Refused(f"session {name} was created meanwhile; start it by name")
            write_json(record_path(name), record)
        stop(gw)  # a gateway whose harness already exited
        if not (control / "binding.json").exists():
            write_json(control / "binding.json", {})
        if args.note_read or args.note_write:
            write_notes(name, args.note_read, args.note_write)
        else:
            ensure_grants(name)
        for folder in record["folders"]:
            if folder["kind"] == "clone":
                ensure_clone(folder)
        check_folders(record)

        run_dir = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=private_dir(state_root() / "run")))
        sock = private_dir(run_dir / "sock")
        native_mounts = natives_manifest(run_dir)  # may refuse: before anything starts
        write_json(run_dir / "sessions.json", {"sessions": [{
            "name": name, "harness": record["harness"], "socket_dir": "/run/minerva-agent/sock",
            "docket_projects": record["projects"], "control_dir": "/run/minerva-agent/control"}]})

        started = run(compose(name, "run", "-d", "--rm", "--name", gw,
                              *bind_mount(sock, "/run/minerva-agent/sock"),
                              *bind_mount(run_dir / "sessions.json", "/run/minerva-agent/sessions.json", True),
                              *bind_mount(control, "/run/minerva-agent/control", True),
                              "gateway"), stdout=subprocess.DEVNULL)
        if started.returncode != 0:
            raise Refused("gateway did not start")
        deadline = time.monotonic() + SOCKET_WAIT_S
        while not sockets_ready(sock):
            if time.monotonic() > deadline:
                stop(gw)
                raise Refused(f"gateway sockets did not appear in {sock}")
            time.sleep(0.2)

        mounts = bind_mount(sock, "/run/minerva-agent", True) + bind_mount(home, HOME_IN_CONTAINER)
        mounts += native_mounts
        for folder in record["folders"]:   # clones and direct mounts, each at its own path
            mounts += bind_mount(folder["path"], folder["path"])
        started = run(compose(name, "run", "-d", "--rm", "--name", dev, "--workdir", record["start_in"],
                              "-e", f"MINERVA_AGENT_SESSION={name}",
                              # Which image this session runs, so it can tell
                              # an image older than its checkout's recipe.
                              "-e", f"MINERVA_AGENT_IMAGE={tag}",
                              "-e", f"MINERVA_NATIVES_MANIFEST={NATIVES_MANIFEST}", *mounts,
                              "dev", "/opt/minerva-agent/minerva-session", record["harness"], mode),
                      stdout=subprocess.DEVNULL)
        if started.returncode != 0:
            stop(gw)
            raise Refused("dev container did not start")
    result = describe(name, record)
    result["message"] = (f"session {name} running ({record['harness']}, mode {mode}); "
                         f"attach it from a terminal tab's menu (Attach agent session here) "
                         f"or run agent.py attach {name} in a Minerva terminal")
    return result


class Lease:
    """This attach's claim on the session binding, renewed until released.
    Every change happens under the session lock and only while the binding
    still carries this generation, so a client that was taken over can
    neither renew nor clear its successor's binding."""

    def __init__(self, name, terminal, targets, container=(0, 0)):
        self.name, self.path, self.seconds = name, binding_path(name), lease_s()
        self.value = {"terminal_id": terminal, "notify_targets": targets,
                      "generation": secrets.token_hex(8), "expires_at": 0}
        # Beside the binding, never in it (the gateway reads the binding's
        # exact keys): Minerva matches this generation, the launcher group in
        # front of the tab and the container's init to find the harness the
        # tab shows (AgentContainerForeground.gd). Zeros make it hold.
        self.launcher = {"generation": self.value["generation"], "launcher_pgid": os.getpgrp(),
                         "container_pid": container[0], "container_start": container[1]}
        self._stop = threading.Event()
        # The binding and launcher.json this attach replaced (claim_locked).
        self.previous = ({}, {})

    def claim_locked(self):
        """Under the session lock: take the binding, live lease or not (the
        newest attach wins), remembering the one it replaces for
        restore_locked. Answers the terminal that held a live lease, or ""."""
        self.previous = (read_json(self.path), read_json(launcher_path(self.name)))
        current = self.previous[0]
        live = isinstance(current.get("expires_at"), (int, float)) and current["expires_at"] > time.time()
        write_json(launcher_path(self.name), self.launcher)
        self._write()
        return str(current.get("terminal_id", "")) if live else ""

    def restore_locked(self):
        """Under the session lock, when this attach failed to establish: put
        back the binding it replaced, so a holder that is still attached keeps
        renewing it (a holder that was detached clears it as it exits)."""
        self._stop.set()
        if self._mine():
            write_json(self.path, self.previous[0])
            write_json(launcher_path(self.name), self.previous[1])

    def taken_over(self):
        with session_lock(self.name):
            return not self._mine()

    def _write(self):
        self.value["expires_at"] = time.time() + self.seconds
        write_json(self.path, self.value)

    def _mine(self):
        return read_json(self.path).get("generation") == self.value["generation"]

    def renew_until_released(self):
        def renew():
            while not self._stop.wait(self.seconds / 3):
                with session_lock(self.name):
                    if not self._mine():
                        return
                    self._write()
        threading.Thread(target=renew, daemon=True).start()

    def release_locked(self):
        self._stop.set()
        if self._mine():
            write_json(self.path, {})
            write_json(launcher_path(self.name), {})

    def release(self):
        with session_lock(self.name):
            self.release_locked()


def cmd_attach(args):
    check_layout()
    name = args.name
    dev, _ = containers(name)
    terminal = os.environ.get("MINERVA_TERMINAL_ID", "")
    if not TERMINAL_ID.fullmatch(terminal):
        raise Refused("attach runs inside a Minerva terminal (MINERVA_TERMINAL_ID is not set)")
    for target in args.notify_to or []:
        if not TERMINAL_ID.fullmatch(target):
            raise Refused(f"bad terminal id {target!r}")
    if not running(dev):
        raise Refused(f"session {name} is not running: use `agent.py up` or `agent.py start`")
    lease = Lease(name, terminal, args.notify_to or [], container_identity(dev))
    client = None

    def hang_up(signum, frame):
        raise SystemExit(128 + signum)
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, hang_up)
    # The finally covers establishment too: a hangup or a timed-out tmux query
    # while attaching still kills the client and releases the lease (only if
    # it is still this generation). It runs after the lock below is left.
    try:
        # Claim and establish under one lock: a takeover can only begin once
        # this client is really attached, so its -d is what detaches us, never
        # the reverse. -d detaches any other client: one controlling tab.
        with session_lock(name):
            previous = lease.claim_locked()
            try:
                before = tmux_clients(dev)
                # The pane-mode title names this attachment (tmux.conf), so Minerva
                # never takes an earlier attachment's late title for this one's.
                client = subprocess.Popen(["docker", "exec", "-it", dev, "tmux",
                                           "set-option", "-g", "@minerva_attachment",
                                           lease.value["generation"], ";",
                                           "attach-session", "-d", "-t", "harness"])
                state = attach_established(dev, before, client)
                if state == "exited":   # attached and already gone, or tmux refused (its message shown)
                    lease.restore_locked()
                    return client.returncode
                if state != "attached":
                    raise Refused(f"could not attach to session {name}")
            except BaseException:
                lease.restore_locked()
                raise
        if previous and previous != terminal:
            print(f"agent.py: session {name} taken over from terminal {previous}", file=sys.stderr)
        lease.renew_until_released()
        code = client.wait()
        if lease.taken_over():
            print(f"\nagent.py: session {name} is now attached from another tab; this tab is detached "
                  "(attach it here again from the tab's menu)", file=sys.stderr)
        return code
    finally:
        if client is not None and client.poll() is None:
            client.kill()
            client.wait()
        lease.release()


def tmux_clients(dev):
    probe = subprocess.run(["docker", "exec", dev, "tmux", "list-clients", "-t", "harness",
                            "-F", "#{client_tty}"], capture_output=True, text=True,
                           timeout=TMUX_QUERY_TIMEOUT_S)
    return set(probe.stdout.split()) if probe.returncode == 0 else set()


def attach_established(dev, before, client, timeout_s=ATTACH_WAIT_S):
    """"attached" once a tmux client that was not there before appears (this
    attach), "exited" if the attach process ends first, "timeout" otherwise."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if tmux_clients(dev) - before:
            return "attached"
        if client.poll() is not None:
            return "exited"
        time.sleep(0.1)
    return "timeout"


def cmd_up(args):
    check_layout()
    resolve_record(args)   # never attach to a session created differently
    if running(containers(args.name)[0]):
        if args.note_read or args.note_write:
            write_notes(args.name, args.note_read, args.note_write)
    else:
        print(cmd_start(args)["message"])
    return cmd_attach(args)


def cmd_notes(args):
    check_layout()
    write_notes(args.name, args.note_read, args.note_write)
    return 0


def cmd_grant(args, add=True):
    check_layout()
    if load_record(args.name) is None:
        raise Refused(f"no session {args.name}")
    grants = change_grants(args.name, add, args.note_read, args.note_write, args.notify)
    return {"ok": True, "id": args.name, "grants": grants,
            "message": f"{args.name}: read {len(grants['note_read'])} note(s), write "
                       f"{len(grants['note_write'])}, notify {'on' if grants['notify'] else 'off'}"}


def cmd_identity(args):
    check_layout()
    if load_record(args.name) is None:
        raise Refused(f"no session {args.name}")
    grants = set_identity(args.name, args.identity, args.role)
    who = grants.get("identity", "")
    return {"ok": True, "id": args.name, "grants": grants,
            "message": f"{args.name}: Docket identity {who or 'none'}"
                       + (f", role {grants['role']}" if grants.get("role") else "")}


def cmd_revoke(args):
    return cmd_grant(args, add=False)


def cmd_stop(args):
    check_layout()
    with session_lock(args.name):
        stop(*containers(args.name))
        if binding_path(args.name).exists():
            write_json(binding_path(args.name), {})
    return {"ok": True, "id": args.name, "state": docker_state(containers(args.name)[0]),
            "message": f"session {args.name} stopped; its home, clones and state are kept"}


def cmd_status(args):
    check_layout()
    record = load_record(args.name)
    if record is None:
        raise Refused(f"no session {args.name}")
    return describe(args.name, record)


def cmd_info(args):
    check_layout()
    record = load_record(args.name)
    if record is None:
        raise Refused(f"no session {args.name}")
    result = describe(args.name, record)
    home = {"host": str(session_dir(args.name) / "home"), "path": HOME_IN_CONTAINER, "kind": "home"}
    result["path_mappings"] = [{"host": f["host"] or f["path"], "container": f["path"], "kind": f["kind"],
                                "mounted_from": f["path"]} for f in record["folders"] + [home]]
    if args.map:
        result["mapped"] = {p: container_path(record["folders"] + [home], p) for p in args.map}
    if result["state"] == "running":
        measured = readiness.probe(containers(args.name)[0], record["start_in"], [], {})
        ident = measured.get("identity", {})
        result["git_identity"] = {"set": bool(ident), "name": ident.get("name", ""),
                                  "email": ident.get("email", ""), "measured": "container",
                                  "detail": measured.get("error", "") if "error" in measured else
                                  ("" if ident else "git has no author identity in the start folder: commits fail")}
    else:
        result["git_identity"] = {"set": False, "name": "", "email": "", "measured": "",
                                  "detail": "measured inside the running session; it is not running"}
    name, selected_by = record_profile(record)
    result["toolchain_profile"] = {"name": name, "selected_by": selected_by}
    try:
        profile = readiness.load_profile(name)
        result["toolchain_profile"].update(description=profile["description"], source=profile["source"],
                                           tools=readiness.summary(profile))
        result["toolchain_profile"]["available"] = readiness.profile_names()
    except readiness.ProfileError as exc:
        result["toolchain_profile"]["error"] = str(exc)
    tools = result["toolchain_profile"].get("tools", {})
    ident = result["git_identity"]
    result["message"] = "\n".join(
        [result["message"], f"  commits as: {ident['name']} <{ident['email']}>" if ident["set"]
         else f"  commits as: unknown ({ident['detail']})",
         f"  toolchain profile: {name} ({selected_by})"
         + (": " + ", ".join(f"{t} {v}" for t, v in tools.items()) if tools
            else f": {result['toolchain_profile'].get('error', '')}")]
        + [f"  {m['host']} -> {m['container']} ({m['kind']})" for m in result["path_mappings"]])
    return result


def cmd_readiness(args):
    check_layout()
    record = load_record(args.name)
    if record is None:
        raise Refused(f"no session {args.name}")
    try:
        profile = readiness.load_profile(args.profile or record_profile(record)[0])
    except readiness.ProfileError as exc:
        raise Refused(str(exc))
    tools = readiness.with_harness(profile, record["harness"])
    dev = containers(args.name)[0]
    running_now = docker_state(dev) == "running"
    measured = readiness.probe(dev, record["start_in"], [f["path"] for f in record["folders"]], tools) \
        if running_now else {}
    known, docket_error = readiness.docket_projects() if record["projects"] else (set(), "")
    claims = readiness.docket_claims() if record["projects"] else None
    results = readiness.checks(record, running_now, measured, tools, known, docket_error, claims)
    missing = [f"{c['check']} {c['name']}: {c['detail']}" for c in results if not c["ok"]]
    where = f"inside {dev} (docker exec) and the host's Docket service" if running_now \
        else "the host's Docket service only"
    return {"ok": True, "id": args.name, "ready": not missing, "profile": profile["name"],
            "profile_selected_by": "argument" if args.profile else record_profile(record)[1],
            "toolchain": readiness.summary(profile), "checked": where, "checks": results, "missing": missing,
            "message": "ready" if not missing else "not ready:\n  " + "\n  ".join(missing)}


def cmd_provision(args):
    check_layout()
    record = load_record(args.name)
    if record is None:
        raise Refused(f"no session {args.name}")
    dev = containers(args.name)[0]
    if docker_state(dev) != "running":
        raise Refused(f"session {args.name} is not running: tools are provisioned inside it")
    try:
        profile = readiness.load_profile(record_profile(record)[0])
    except readiness.ProfileError as exc:
        raise Refused(str(exc))
    tools = profile["tools"]
    for tool in args.tool or []:
        if not tools.get(tool, {}).get("provision"):
            raise Refused(f"profile {profile['name']} has no provisioning for {tool!r}")
    wanted = list(args.tool or [])
    if not wanted:
        measured = readiness.probe(dev, record["start_in"], [], tools)
        if "error" in measured:
            raise Refused(measured["error"])
        wanted = [t for t, spec in tools.items() if spec["provision"]
                  and not readiness.tool_check(spec, measured["tools"].get(t, {}))[0]]
    results = provision.provision(dev, tools, wanted)
    failed = [r for r in results if not r["ok"]]
    lines = [f"{r['tool']}: {'ok' if r['ok'] else 'FAILED'} {r['detail']}" for r in results]
    return {"ok": not failed, "id": args.name, "profile": profile["name"], "provisioned": results,
            "error": "; ".join(lines) if failed else "",
            "message": "\n".join(lines) if results else "nothing to provision: the profile's "
                       "provisionable tools are present"}


def cmd_profiles(args):
    user = readiness.user_profiles_path()
    try:
        profiles = readiness.list_profiles()
    except readiness.ProfileError as exc:
        raise Refused(str(exc))
    return {"ok": True, "profiles": profiles, "default": readiness.DEFAULT_PROFILE,
            "shipped_file": str(readiness.PROFILES), "user_file": str(user) if user else "",
            "user_file_exists": bool(user and user.exists()),
            "message": "\n".join(f"{p['name']:20} {p['source']:8} "
                                 + (", ".join(f"{t} {v}" for t, v in p["tools"].items()) if "tools" in p
                                    else p["error"]) for p in profiles)}


def cmd_list(args):
    check_layout()
    root = state_root() / "sessions"
    sessions = []
    for sdir in sorted(root.iterdir()) if root.is_dir() else []:
        if not NAME.fullmatch(sdir.name) or not sdir.is_dir():
            continue
        try:
            record = load_record(sdir.name)
        except Refused as exc:
            sessions.append({"ok": False, "id": sdir.name, "error": str(exc),
                             "message": f"{sdir.name:24} {exc}"})
            continue
        if record is not None:
            sessions.append(describe(sdir.name, record))
    tag = image_tag()
    return {"ok": True, "sessions": sessions, "image": {"tag": tag, "built": image_built(tag)},
            "message": "\n".join(s["message"] for s in sessions)}


def cmd_run_job(args):
    return jobs.run_job(HOST, args.name, args.rev, args.job_command, args.env, args.artifact,
                        args.cpus, args.memory, args.seconds, args.folder)


def cmd_job_status(args):
    return jobs.job_status(HOST, args.name, args.job)


def cmd_job_log(args):
    return jobs.job_log(HOST, args.name, args.job, args.tail)


def cmd_drain(args):
    return jobs.drain(HOST, args.name, args.wait, args.lift)


def job_options(p):
    p.add_argument("--rev", required=True, metavar="REV")
    # dest differs from the subcommand's own "command".
    p.add_argument("--command", dest="job_command", required=True, metavar="SHELL_COMMAND")
    p.add_argument("--env", action="append", metavar="KEY=VALUE")
    p.add_argument("--artifact", action="append", metavar="PATH")
    p.add_argument("--cpus", type=float)
    p.add_argument("--memory", metavar="SIZE")
    p.add_argument("--seconds", type=int)
    p.add_argument("--folder", metavar="PATH")


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def session_name(value):
        if not NAME.fullmatch(value):
            raise argparse.ArgumentTypeError("names are lowercase letters, digits and -")
        return value

    def note_options(p):
        p.add_argument("--note-read", action="append", metavar="NOTE_ID")
        p.add_argument("--note-write", action="append", metavar="NOTE_ID")

    def record_options(p, required):
        p.add_argument("--harness", required=required, choices=HARNESSES)
        p.add_argument("--folder", action="append", required=required, metavar="PATH")
        p.add_argument("--start-in", metavar="PATH")
        p.add_argument("--project", action="append", metavar="DOCKET_PROJECT")
        p.add_argument("--mode", choices=MODES)
        p.add_argument("--profile", metavar="PROFILE")

    def start_options(p):
        record_options(p, False)
        # Matches a record from before folders; never creates one.
        p.add_argument("--task", type=session_name)

    def grant_options(p):
        p.add_argument("--notify", action="store_true",
                       help="the notify grant: any harness tab except the session's own")

    def attach_options(p):
        # Only a gateway started before grants.json reads this list; a current
        # gateway lets the session notify any harness tab but its own.
        p.add_argument("--notify-to", action="append", metavar="TERMINAL_ID", help=argparse.SUPPRESS)

    for command, options in (("build", []), ("create", [lambda p: record_options(p, True)]),
                             ("start", [start_options, note_options]), ("attach", [attach_options]),
                             ("up", [start_options, note_options, attach_options]),
                             ("notes", [note_options]), ("stop", []), ("status", []),
                             ("grant", [note_options, grant_options]),
                             ("revoke", [note_options, grant_options]),
                             ("identity", [lambda p: p.add_argument("--identity", default=""),
                                           lambda p: p.add_argument("--role", default="")]),
                             ("info", [lambda p: p.add_argument("--map", action="append", metavar="HOST_PATH")]),
                             ("readiness", [lambda p: p.add_argument("--profile", metavar="PROFILE")]),
                             ("provision", [lambda p: p.add_argument("--tool", action="append",
                                                                     metavar="TOOL")]),
                             ("profiles", []),
                             ("run-job", [job_options]),
                             ("job-status", [lambda p: p.add_argument("job", nargs="?", default="")]),
                             ("job-log", [lambda p: p.add_argument("job"),
                                          lambda p: p.add_argument("--tail", type=int, metavar="BYTES")]),
                             ("drain", [lambda p: p.add_argument("--wait", type=int, metavar="SECONDS"),
                                        lambda p: p.add_argument("--lift", action="store_true")]),
                             ("list", [])):
        p = sub.add_parser(command)
        p.add_argument("--json", action="store_true", help="answer with one JSON object on stdout")
        if command not in ("build", "list", "profiles"):
            p.add_argument("name", type=session_name)
        for add in options:
            add(p)
    return parser.parse_args(argv)


COMMANDS = {"build": cmd_build, "create": cmd_create, "start": cmd_start, "attach": cmd_attach,
            "up": cmd_up, "notes": cmd_notes, "grant": cmd_grant, "revoke": cmd_revoke,
            "identity": cmd_identity,
            "stop": cmd_stop, "status": cmd_status,
            "info": cmd_info, "readiness": cmd_readiness, "provision": cmd_provision,
            "profiles": cmd_profiles, "list": cmd_list,
            "run-job": cmd_run_job, "job-status": cmd_job_status, "job-log": cmd_job_log,
            "drain": cmd_drain}
# This module as jobs.py's host: its docker, lock and control-file helpers.
HOST = sys.modules[__name__]


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    try:
        result = COMMANDS[args.command](args)
    except Refused as exc:
        result = {"ok": False, "error": str(exc)}
    except subprocess.TimeoutExpired as exc:
        result = {"ok": False, "error": f"docker did not answer within {exc.timeout:g} s"}
    except FileNotFoundError as exc:
        result = {"ok": False, "error": f"{exc.filename or exc} was not found (is it installed?)"}
    if isinstance(result, int):
        return result
    if args.json:
        print(json.dumps(result))
    elif result["ok"]:
        if result.get("message"):
            print(result["message"])
    else:
        print(f"agent.py: {result['error']}", file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
