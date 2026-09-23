#!/usr/bin/env python3
"""Trusted host launcher for agent containers (one harness per session).

  agent.py build
  agent.py start NAME --harness claude|codex --task TASK [--start-in REPO] [--project P]...
                 [--mode start|resume|shell] [--note-read ID]... [--note-write ID]...
  agent.py attach NAME [--notify-to TERMINAL_ID]... [--takeover]
  agent.py up NAME [start options] [attach options]     start if needed, then attach
  agent.py notes NAME [--note-read ID]... [--note-write ID]...
  agent.py stop NAME
  agent.py list
  agent.py migrate NAME [--start-in REPO]    move a stopped pre-unified session to all four repos

A session is long-running: `start` launches its gateway and dev containers
detached. In the dev container a tmux session holds an interactive shell
(the harness's environment already set) that first runs the harness, or its
resume picker, or nothing (--mode). Leaving the harness drops to that shell;
leaving the shell ends the session. `attach`, run in a Minerva terminal,
joins the tmux session as its only client. Closing or crashing Minerva only
detaches; `attach` from any new terminal reconnects to the same shell, never
starting a new harness or model turn.

Attaching binds the session to that terminal for notify routing: a binding
file carries the terminal id, the notify targets, a generation token and a
lease that the attached launcher renews. An attach that dies without
cleaning up stops routing once its lease lapses. A per-session lock
serializes start, stop and attach ownership.

Everything a session keeps lives under the state root
(${MINERVA_AGENT_STATE:-${XDG_STATE_HOME:-~/.local/state}/minerva-agent}):
  sessions/NAME/session.json          what it was started with (never replaced)
  sessions/NAME/home/                 the harness's own config dir: login,
                                      settings, transcripts (the owner logs in
                                      there once, inside the harness)
  sessions/NAME/control/binding.json  attached terminal, notify targets, lease
  sessions/NAME/control/notes.json    Minerva notes the session may read/write
  sessions/NAME/launcher.json         the attached launcher's process group and
                                      the container's init, for Minerva to see
                                      the harness in front (host-only)
  run/NAME-*/                         one gateway run's sessions.json + sockets,
                                      and natives.json (see natives_manifest)
Every session mounts all four task repositories (REPOS), independent clones
under ${MINERVA_AGENT_WORK:-~/agent-work}/TASK/, made once from the host
checkouts and mounted at the same absolute path. --start-in only picks the
directory the harness starts in (default Minerva, whose CLAUDE.md it loads).
Sessions saved before this (a "repos" subset, no "start_in") are legacy:
start and up refuse them and attach warns, until `migrate` rewrites their
session.json (keeping the old one as session.legacy.json).
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
COMPOSE = HERE / "docker-compose.yml"
IMAGE_FILES = ["Dockerfile", "forwarder.py", "minerva-session", "agent-env.sh", "agent-bashrc",
               "agent-upgrade", "tmux.conf", "claude-mcp.json", "smoke.py"]
# The four repositories an agent session may work on, relative to the source
# root (HOME, or MINERVA_AGENT_SOURCE_ROOT).
REPOS = {"Minerva": "github/Minerva", "minerva-plugins": "github/minerva-plugins",
         "minervaservices": "gitlab/minervaservices", "ccsandbox": "gitlab/ccsandbox"}
DOCKET_PROJECTS = ["minerva", "plugins.dct", "minerva-services", "Master"]
MODES = ["start", "resume", "shell"]
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
TERMINAL_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
NOTE_ID = re.compile(r"[0-9a-f]{32,64}")
# Characters that would change the meaning of a `docker -v src:dst[:ro]`.
NATIVES_MANIFEST = "/run/minerva-natives.json"
UNSAFE_PATH = re.compile(r"[:,\n\r\0]")
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


def source_root():
    return Path(os.environ.get("MINERVA_AGENT_SOURCE_ROOT") or Path.home())


def lease_s():
    value = os.environ.get("MINERVA_AGENT_LEASE_S", "60")
    if not value.isdigit() or not 2 <= int(value) <= 3600:
        raise Refused("MINERVA_AGENT_LEASE_S must be 2-3600 seconds")
    return int(value)


def _within(inner, outer):
    return inner == outer or outer in inner.parents


def check_layout():
    """Before anything is written, stopped or cloned: the state and work roots
    must be plain absolute paths (no symlinked component, nothing docker -v
    would misparse), the work root must not expose HOME or a host checkout,
    and the state root (control files, sockets) must be disjoint from the work
    root, whose clones the dev container can write."""
    home = Path(os.path.realpath(Path.home()))
    roots = {"state root": state_root(), "work root": work_root(), "source root": source_root()}
    for label, path in roots.items():
        if not path.is_absolute() or UNSAFE_PATH.search(str(path)):
            raise Refused(f"{label} {path} must be an absolute path without ':' or ','")
        if os.path.realpath(path) != os.path.abspath(path):
            raise Refused(f"{label} {path} goes through a symlink")
    state, work = Path(os.path.abspath(state_root())), Path(os.path.abspath(work_root()))
    checkouts = [Path(os.path.realpath(source_root() / rel)) for rel in REPOS.values()]
    if _within(home, work):
        raise Refused(f"work root {work} would expose all of {home}")
    if _within(home, state):
        raise Refused(f"state root {state} would hold all of {home}")
    if _within(state, work) or _within(work, state):
        raise Refused(f"state root {state} and work root {work} must not contain each other")
    for checkout in checkouts:
        if _within(work, checkout) or _within(checkout, work):
            raise Refused(f"work root {work} overlaps the host checkout {checkout}")
        if _within(state, checkout) or _within(checkout, state):
            raise Refused(f"state root {state} overlaps the host checkout {checkout}")


def check_clone_paths(task, repos):
    """Every existing component below the work root on the way to each clone
    must be a real directory: a symlinked TASK or REPO would otherwise mount
    somewhere the work-root checks never looked. Called before any side
    effect and again just before the mounts."""
    work = Path(os.path.abspath(work_root()))
    for repo in repos:
        for path in (work / task, work / task / repo):
            if os.path.lexists(path) and (os.path.islink(path) or not os.path.isdir(path)
                                          or os.path.realpath(path) != str(path)):
                raise Refused(f"{path} is not a plain directory inside the work root")


def check_sources(task, repos):
    """Every repository still to be cloned must have its host checkout, so a
    missing one is refused before anything is written or started."""
    for repo in repos:
        src = source_root() / REPOS[repo]
        if not os.path.lexists(work_root() / task / repo) and not (src / ".git").is_dir():
            raise Refused(f"{src} is not a git checkout (needed for {repo})")


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


def running(container):
    probe = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                           capture_output=True, text=True)
    return probe.returncode == 0 and probe.stdout.strip() == "true"


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
def session_lock(name):
    """Serializes start, stop and binding changes for one session."""
    private_dir(state_root())
    private_dir(state_root() / "sessions")
    sdir = private_dir(session_dir(name))
    fd = os.open(sdir / "lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def binding_path(name):
    return session_dir(name) / "control" / "binding.json"


def launcher_path(name):
    return session_dir(name) / "launcher.json"


def write_notes(name, read, write):
    for note in (read or []) + (write or []):
        if not NOTE_ID.fullmatch(note):
            raise Refused(f"bad note id {note!r}")
    control = private_dir(session_dir(name) / "control")
    write_json(control / "notes.json", {"read": sorted(set(read or [])), "write": sorted(set(write or []))})


def sockets_ready(sock):
    paths = [sock / f"{s}.sock" for s in SOCKETS]
    return all(os.path.lexists(p) and stat.S_ISSOCK(os.lstat(p).st_mode) for p in paths)


# ── repositories ──────────────────────────────────────────────────────────

def ensure_clone(repo, task):
    """The task clone of repo, made once with independent object files. An
    existing clone is used as it is: the host never runs git inside a clone
    an agent can modify (its .git/config could make git run code)."""
    src = source_root() / REPOS[repo]
    dest = work_root() / task / repo
    if os.path.lexists(dest):
        if dest.is_symlink() or not dest.is_dir():
            raise Refused(f"{dest} exists and is not a directory")
        return dest
    if not (src / ".git").is_dir():
        raise Refused(f"{src} is not a git checkout")
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "--no-hardlinks", "--quiet", "--", str(src), str(dest)],
                   check=True)
    return dest


# ── commands ─────────────────────────────────────────────────────────────

def settings(args):
    if args.repo:
        raise Refused("--repo is gone: every session mounts all four repositories; "
                      "use --start-in REPO to choose where the harness starts")
    return {"harness": args.harness, "task": args.task, "repos": sorted(REPOS),
            "start_in": args.start_in, "projects": args.project or DOCKET_PROJECTS}


def is_legacy(saved):
    """A session.json from before every session mounted all four repositories."""
    return isinstance(saved, dict) and "repos" in saved and "start_in" not in saved


def legacy_refusal(name, saved):
    return Refused(f"session {name} is a legacy session that mounts only {', '.join(saved['repos'])}; "
                   f"stop it, then `agent.py migrate {name}` to mount all four repositories "
                   "(its home and clones are kept), or use a new name")


def check_saved(name, config):
    """False when the session has no saved settings yet; True when they match.
    Different or unreadable saved settings are refused, never replaced."""
    path = session_dir(name) / "session.json"
    if not os.path.lexists(path):
        return False
    try:
        saved = json.loads(path.read_text())
    except (OSError, ValueError):
        saved = None
    if is_legacy(saved):
        raise legacy_refusal(name, saved)
    if not isinstance(saved, dict) or set(saved) != set(config):
        raise Refused(f"{path} is unreadable or incomplete; fix it by hand or use a new name")
    if saved != config:
        raise Refused(f"session {name} was started with different settings ({path}); "
                      "use those, or a new name")
    return True


def cmd_build(args):
    container_build.ensure_image()  # the agent image is built on the builder image
    return run(compose("build", "build", "gateway")).returncode


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


def cmd_start(args):
    check_layout()
    name, config = args.name, settings(args)
    check_clone_paths(args.task, config["repos"])
    check_sources(args.task, config["repos"])
    dev, gw = containers(name)
    tag = image_tag()
    if subprocess.run(["docker", "image", "inspect", tag], capture_output=True).returncode != 0:
        raise Refused(f"image {tag} is not built: run `agent.py build` first")
    with session_lock(name):
        if running(dev):
            raise Refused(f"session {name} is already running: use `agent.py attach {name}`")
        home = private_dir(session_dir(name) / "home")
        control = private_dir(session_dir(name) / "control")
        if not check_saved(name, config):
            write_json(session_dir(name) / "session.json", config)
        stop(gw)  # a gateway whose harness already exited
        if not (control / "binding.json").exists():
            write_json(control / "binding.json", {})
        if args.note_read or args.note_write or not (control / "notes.json").exists():
            write_notes(name, args.note_read, args.note_write)
        clones = [ensure_clone(repo, args.task) for repo in config["repos"]]
        check_clone_paths(args.task, config["repos"])

        run_dir = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=private_dir(state_root() / "run")))
        sock = private_dir(run_dir / "sock")
        native_mounts = natives_manifest(run_dir)  # may refuse: before anything starts
        write_json(run_dir / "sessions.json", {"sessions": [{
            "name": name, "harness": args.harness, "socket_dir": "/run/minerva-agent/sock",
            "docket_projects": config["projects"], "control_dir": "/run/minerva-agent/control"}]})

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

        mounts = bind_mount(sock, "/run/minerva-agent", True) + bind_mount(home, "/agent-home")
        mounts += native_mounts
        for clone in clones:
            mounts += bind_mount(clone, clone)
        workdir = work_root() / args.task / config["start_in"]
        started = run(compose(name, "run", "-d", "--rm", "--name", dev, "--workdir", str(workdir),
                              "-e", f"MINERVA_AGENT_SESSION={name}",
                              # Which image this session runs, so it can tell
                              # an image older than its checkout's recipe.
                              "-e", f"MINERVA_AGENT_IMAGE={image_tag()}",
                              "-e", f"MINERVA_NATIVES_MANIFEST={NATIVES_MANIFEST}", *mounts,
                              "dev", "/opt/minerva-agent/minerva-session", args.harness, args.mode),
                      stdout=subprocess.DEVNULL)
        if started.returncode != 0:
            stop(gw)
            raise Refused("dev container did not start")
    print(f"session {name} running ({args.harness}, task {args.task}, mode {args.mode}); "
          f"attach from a Minerva terminal: agent.py attach {name}")
    return 0


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

    def claim_locked(self, takeover):
        """Under the session lock: take the binding unless another live lease holds it."""
        current = read_json(self.path)
        live = isinstance(current.get("expires_at"), (int, float)) and current["expires_at"] > time.time()
        if live and not takeover:
            raise Refused(f"session {self.name} is attached from terminal {current.get('terminal_id')}; "
                          "pass --takeover to move it here")
        write_json(launcher_path(self.name), self.launcher)
        self._write()

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
    saved = read_json(session_dir(name) / "session.json")
    if is_legacy(saved):
        # Attach still works, so a live legacy session is never cut off.
        print(f"agent.py: warning: legacy session {name} mounts only {', '.join(saved['repos'])}; "
              f"after it stops, `agent.py migrate {name}`", file=sys.stderr)
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
            lease.claim_locked(args.takeover)
            before = tmux_clients(dev)
            # The pane-mode title names this attachment (tmux.conf), so Minerva
            # never takes an earlier attachment's late title for this one's.
            client = subprocess.Popen(["docker", "exec", "-it", dev, "tmux",
                                       "set-option", "-g", "@minerva_attachment",
                                       lease.value["generation"], ";",
                                       "attach-session", "-d", "-t", "harness"])
            state = attach_established(dev, before, client)
            if state == "exited":   # attached and already gone, or tmux refused (its message shown)
                return client.returncode
            if state != "attached":
                raise Refused(f"could not attach to session {name}")
        lease.renew_until_released()
        return client.wait()
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
    check_clone_paths(args.task, settings(args)["repos"])
    if running(containers(args.name)[0]):
        check_saved(args.name, settings(args))  # never attach to a session started differently
        if args.note_read or args.note_write:
            with session_lock(args.name):
                write_notes(args.name, args.note_read, args.note_write)
    else:
        cmd_start(args)
    return cmd_attach(args)


def cmd_notes(args):
    check_layout()
    with session_lock(args.name):
        write_notes(args.name, args.note_read, args.note_write)
    return 0


def cmd_stop(args):
    check_layout()
    with session_lock(args.name):
        stop(*containers(args.name))
        if binding_path(args.name).exists():
            write_json(binding_path(args.name), {})
    print(f"session {args.name} stopped; its home, clones and state are kept")
    return 0


def cmd_migrate(args):
    """Rewrite a stopped legacy session's settings to the unified shape. The old
    file is kept beside it; the home (login, transcripts) is untouched. The
    missing clones are made by the next start."""
    check_layout()
    with session_lock(args.name):
        if running(containers(args.name)[0]):
            raise Refused(f"session {args.name} is running: stop it first")
        path = session_dir(args.name) / "session.json"
        saved = read_json(path)
        if not is_legacy(saved):
            raise Refused(f"{path} is not a legacy session")
        backup = session_dir(args.name) / "session.legacy.json"
        try:
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise Refused(f"{backup} already exists") from None
        with os.fdopen(fd, "wb") as f:
            f.write(path.read_bytes())
        config = {**saved, "repos": sorted(REPOS), "start_in": args.start_in}
        write_json(path, config)
    print(f"session {args.name} is configured to mount all four repositories on its next start, "
          f"starting in {args.start_in}; "
          f"previous settings kept in {backup}; start it with the same --harness/--task")
    return 0


def cmd_list(args):
    root = state_root() / "sessions"
    for sdir in sorted(root.iterdir()) if root.is_dir() else []:
        config = read_json(sdir / "session.json")
        state = "running" if running(containers(sdir.name)[0]) else "stopped"
        print(f"{sdir.name:24} {state:8} {config.get('harness', '?'):7} task={config.get('task', '?')}")
    return 0


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")

    def session_name(value):
        if not NAME.fullmatch(value):
            raise argparse.ArgumentTypeError("names are lowercase letters, digits and -")
        return value

    def note_options(p):
        p.add_argument("--note-read", action="append", metavar="NOTE_ID")
        p.add_argument("--note-write", action="append", metavar="NOTE_ID")

    def start_options(p):
        p.add_argument("--harness", required=True, choices=["claude", "codex"])
        p.add_argument("--task", required=True, type=session_name)
        p.add_argument("--start-in", default="Minerva", choices=sorted(REPOS))
        p.add_argument("--repo", action="append", help=argparse.SUPPRESS)  # refused: see settings()
        p.add_argument("--project", action="append", choices=DOCKET_PROJECTS)
        p.add_argument("--mode", default="start", choices=MODES)

    def attach_options(p):
        p.add_argument("--notify-to", action="append", metavar="TERMINAL_ID")
        p.add_argument("--takeover", action="store_true")

    for command, options in (("start", [start_options, note_options]), ("attach", [attach_options]),
                             ("up", [start_options, note_options, attach_options]),
                             ("notes", [note_options]), ("stop", []), ("list", []),
                             ("migrate", [lambda p: p.add_argument("--start-in", default="Minerva",
                                                                   choices=sorted(REPOS))])):
        p = sub.add_parser(command)
        if command != "list":
            p.add_argument("name", type=session_name)
        for add in options:
            add(p)
    return parser.parse_args(argv)


COMMANDS = {"build": cmd_build, "start": cmd_start, "attach": cmd_attach, "up": cmd_up,
            "notes": cmd_notes, "stop": cmd_stop, "list": cmd_list, "migrate": cmd_migrate}


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    try:
        return COMMANDS[args.command](args)
    except Refused as exc:
        print(f"agent.py: {exc}", file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired as exc:
        print(f"agent.py: docker did not answer within {exc.timeout:g} s", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
