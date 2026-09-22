#!/usr/bin/env python3
"""Agent-container launcher, image and forwarder (scripts/agent-container),
without Docker: a fake `docker` on PATH records every call and plays the
container side (the gateway's sockets appear, containers run and stop, an
attach waits). Real git clones tiny scratch repositories. Scratch is kept;
nothing here starts a container, reads credentials or deletes files.
"""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "scripts/agent-container"
REPOS = {"Minerva": "github/Minerva", "minerva-plugins": "github/minerva-plugins",
         "minervaservices": "gitlab/minervaservices", "ccsandbox": "gitlab/ccsandbox"}
sys.dont_write_bytecode = True

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, socket, sys, time
from pathlib import Path
state = Path(os.environ["FAKE_DOCKER_STATE"])
data = json.loads(state.read_text()) if state.exists() else {"running": []}
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a") as log:
    log.write(json.dumps({"argv": args, "image": os.environ.get("MINERVA_AGENT_IMAGE")}) + "\n")
def save():
    state.write_text(json.dumps(data))
if args[:2] == ["image", "inspect"]:
    sys.exit(0 if os.environ.get("FAKE_IMAGE") == "present" else 1)
if args[0] == "inspect" and "{{.State.Pid}}" in args:
    if args[-1] in data["running"]:
        print(1); sys.exit(0)     # the host's init stands in for the container's
    sys.exit(1)
if args[0] == "inspect":
    if args[-1] in data["running"]:
        print("true"); sys.exit(0)
    sys.exit(1)
if args[0] == "stop":
    data["running"] = [c for c in data["running"] if c not in args[1:]]; save(); sys.exit(0)
if args[0] == "compose" and "run" in args:
    name = args[args.index("--name") + 1]
    if "gateway" in args:
        for i, a in enumerate(args):
            if a == "-v" and args[i + 1].endswith(":/run/minerva-agent/sock"):
                sock_dir = args[i + 1].rsplit(":", 1)[0]
                for s in ("minerva", "docket", "nudge", "proxy"):
                    socket.socket(socket.AF_UNIX).bind(f"{sock_dir}/{s}.sock")
    data["running"].append(name); save(); sys.exit(0)
if args[0] == "exec" and "list-clients" in args:
    if data.get("attaching") and os.environ.get("FAKE_LIST_SLEEP"):
        time.sleep(float(os.environ["FAKE_LIST_SLEEP"]))   # tmux stops answering mid-attach
    print("\n".join(data.get("clients", []))); sys.exit(0)
if args[0] == "exec":
    # tmux attach-session -d: after an optional delay this client replaces
    # every other one (clients are named by the attaching terminal id).
    me = os.environ.get("MINERVA_TERMINAL_ID", "?") + "-" + str(os.getpid())
    data["attaching"] = True; save()
    time.sleep(float(os.environ.get("FAKE_ATTACH_DELAY", "0")))
    data = json.loads(state.read_text()) if state.exists() else {"running": []}
    data["clients"] = [me]; save()
    time.sleep(float(os.environ.get("FAKE_ATTACH_SECONDS", "0")))
    data = json.loads(state.read_text())
    data["clients"] = [c for c in data.get("clients", []) if c != me]; save()
    sys.exit(0)
sys.exit(0)
'''

GIT_SHIM = r'''#!/usr/bin/env bash
printf '%s\t%s\n' "$PWD" "$*" >> "$FAKE_GIT_LOG"
exec /usr/bin/git "$@"
'''


def short_scratch():
    base = tempfile.gettempdir()
    return Path(tempfile.mkdtemp(prefix="agl-", dir=base if len(base) <= 60 else "/tmp"))


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.s = short_scratch()
        (self.s / "bin").mkdir()
        for name, text in (("docker", FAKE_DOCKER), ("git", GIT_SHIM)):
            path = self.s / "bin" / name
            path.write_text(text)
            path.chmod(0o755)
        self.home = self.s / "home"
        for rel in REPOS.values():
            src = self.home / rel
            src.mkdir(parents=True)
            subprocess.run(["/usr/bin/git", "init", "-q", str(src)], check=True)
            (src / "README").write_text("hello\n")
            subprocess.run(["/usr/bin/git", "-C", str(src), "add", "README"], check=True)
            subprocess.run(["/usr/bin/git", "-C", str(src), "-c", "user.name=t", "-c", "user.email=t@t",
                            "commit", "-qm", "init"], check=True)
        self.env = {**os.environ, "HOME": str(self.home), "PATH": f"{self.s / 'bin'}:{os.environ['PATH']}",
                    "MINERVA_AGENT_STATE": str(self.home / "state"),
                    "FAKE_DOCKER_STATE": str(self.s / "docker-state.json"),
                    "FAKE_DOCKER_LOG": str(self.s / "docker.log"), "FAKE_GIT_LOG": str(self.s / "git.log"),
                    "FAKE_IMAGE": "present", "MINERVA_TERMINAL_ID": "1111"}
        self.env.pop("MINERVA_AGENT_WORK", None)
        self.env.pop("MINERVA_AGENT_SOURCE_ROOT", None)
        self.env.pop("XDG_STATE_HOME", None)

    def agent(self, *args, env=None, wait=True):
        cmd = [sys.executable, "-B", str(AGENT / "agent.py"), *args]
        # Run from the scratch dir, so even a relative path a broken launcher
        # accepted would land inside the tree the tests inspect.
        if not wait:
            return subprocess.Popen(cmd, env=env or self.env, cwd=self.s, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        return subprocess.run(cmd, env=env or self.env, cwd=self.s, capture_output=True, text=True,
                              timeout=60)

    def docker_calls(self):
        log = self.s / "docker.log"
        return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

    def runs(self):
        return [c["argv"] for c in self.docker_calls() if c["argv"][0] == "compose" and "run" in c["argv"]]

    @staticmethod
    def mounts(argv):
        return [argv[i + 1] for i, a in enumerate(argv) if a == "-v"]

    def tree(self):
        return sorted(str(p.relative_to(self.s)) for p in self.s.rglob("*"))

    def binding(self):
        return json.loads((self.home / "state/sessions/alpha/control/binding.json").read_text())

    def wait_bound(self, terminal, timeout=5):
        deadline = time.monotonic() + timeout
        while self.binding().get("terminal_id") != terminal:
            if time.monotonic() > deadline:
                self.fail(f"binding never showed {terminal}: {self.binding()}")
            time.sleep(0.05)

    def start_alpha(self, *extra, env=None):
        result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1", *extra, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

    # ── start ──
    def test_start_mounts_only_what_the_design_allows(self):
        result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        gateway, dev = self.runs()
        clone = self.home / "agent-work/t1/Minerva"
        clones = [self.home / "agent-work/t1" / repo for repo in REPOS]
        state = self.home / "state"
        run_dir = next((state / "run").iterdir())

        self.assertEqual(gateway[gateway.index("--name") + 1], "minerva-agent-gw-alpha")
        self.assertEqual(sorted(self.mounts(gateway)), sorted([
            f"{run_dir}/sock:/run/minerva-agent/sock",
            f"{run_dir}/sessions.json:/run/minerva-agent/sessions.json:ro",
            f"{state}/sessions/alpha/control:/run/minerva-agent/control:ro"]))
        self.assertEqual(sorted(self.mounts(dev)), sorted([
            f"{run_dir}/sock:/run/minerva-agent:ro",
            f"{state}/sessions/alpha/home:/agent-home"] + [f"{c}:{c}" for c in clones]))
        self.assertEqual(dev[-4:], ["dev", "/opt/minerva-agent/minerva-session", "claude", "start"])
        self.assertEqual(dev[dev.index("--workdir") + 1], str(clone))
        for argv in (gateway, dev):
            joined = " ".join(argv)
            self.assertNotIn("docker.sock", joined)
            self.assertNotIn(f"{self.home}:", joined)                      # never HOME itself
            for rel in REPOS.values():
                self.assertNotIn(f"{self.home}/{rel}", joined)             # never a host checkout
            self.assertNotIn("TOKEN", joined)
            self.assertNotIn("MINERVA_TERMINAL_ID", joined)                # identity is the binding's job
        self.assertTrue(all(c["image"] and c["image"].startswith("minerva-agent:")
                            for c in self.docker_calls() if c["argv"][0] == "compose"))

        sessions = json.loads((run_dir / "sessions.json").read_text())["sessions"]
        self.assertEqual(sessions, [{"name": "alpha", "harness": "claude",
                                     "socket_dir": "/run/minerva-agent/sock",
                                     "docket_projects": ["minerva", "plugins.dct", "minerva-services", "Master"],
                                     "control_dir": "/run/minerva-agent/control"}])
        self.assertEqual(self.binding(), {})
        for d in (state / "sessions/alpha/home", state / "sessions/alpha/control", run_dir / "sock"):
            self.assertEqual(d.stat().st_mode & 0o777, 0o700, d)
        # An independent clone: object files are copies, not hardlinks into the host repo.
        for c in clones:
            objects = [p for p in (c / ".git/objects").rglob("*") if p.is_file()]
            self.assertTrue(objects)
            self.assertTrue(all(p.stat().st_nlink == 1 for p in objects))

    def test_start_in_picks_the_directory_and_never_reduces_mounts(self):
        self.start_alpha("--start-in", "ccsandbox")
        dev = self.runs()[-1]
        work = self.home / "agent-work/t1"
        self.assertEqual(dev[dev.index("--workdir") + 1], str(work / "ccsandbox"))
        for repo in REPOS:
            self.assertIn(f"{work / repo}:{work / repo}", self.mounts(dev))
        saved = json.loads((self.home / "state/sessions/alpha/session.json").read_text())
        self.assertEqual((saved["repos"], saved["start_in"]), (sorted(REPOS), "ccsandbox"))
        # Same session, other starting directory: different settings, refused.
        self.agent("stop", "alpha")
        other = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(other.returncode, 1)
        self.assertIn("different settings", other.stderr)
        # The old repo filter is refused, never read as a subset or a start directory.
        legacy = self.agent("start", "beta", "--harness", "claude", "--task", "t2", "--repo", "Minerva")
        self.assertEqual(legacy.returncode, 1)
        self.assertIn("--start-in", legacy.stderr)
        self.assertEqual(len(self.runs()), 2)

    def test_a_missing_source_checkout_is_refused_before_anything_happens(self):
        missing = self.home / "gitlab/minervaservices"
        missing.rename(self.s / "moved-away")
        before = self.tree()
        result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{missing} is not a git checkout", result.stderr)
        self.assertEqual(self.tree(), before)
        self.assertEqual(self.runs(), [])
        self.assertFalse((self.s / "git.log").exists())

    def test_legacy_single_repo_session_is_refused_until_migrated(self):
        sdir = self.home / "state/sessions/alpha"
        (sdir / "home").mkdir(parents=True)
        for d in (self.home / "state", self.home / "state/sessions", sdir, sdir / "home"):
            d.chmod(0o700)
        (sdir / "home/transcript").write_text("kept\n")
        legacy = {"harness": "claude", "task": "t1", "repos": ["ccsandbox"],
                  "projects": ["minerva", "plugins.dct", "minerva-services", "Master"]}
        (sdir / "session.json").write_text(json.dumps(legacy))
        # The legacy session's own clone, made earlier; the host never runs git inside it.
        old_clone = self.home / "agent-work/t1/ccsandbox"
        subprocess.run(["/usr/bin/git", "clone", "-q", str(self.home / "gitlab/ccsandbox"), str(old_clone)],
                       check=True)
        for command in ("start", "up"):
            result = self.agent(command, "alpha", "--harness", "claude", "--task", "t1")
            self.assertEqual(result.returncode, 1)
            self.assertIn("legacy session that mounts only ccsandbox", result.stderr)
        self.assertEqual(self.runs(), [])

        # Attaching a running legacy session still works, with a warning.
        state = self.s / "docker-state.json"
        state.write_text(json.dumps({"running": ["minerva-agent-alpha"]}))
        refused = self.agent("migrate", "alpha")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("stop it first", refused.stderr)
        attached = self.agent("attach", "alpha")
        self.assertEqual(attached.returncode, 0, attached.stderr)
        self.assertIn("legacy session alpha mounts only ccsandbox", attached.stderr)
        state.write_text(json.dumps({"running": []}))

        migrated = self.agent("migrate", "alpha")
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertEqual(json.loads((sdir / "session.legacy.json").read_text()), legacy)
        self.assertEqual(json.loads((sdir / "session.json").read_text()),
                         {**legacy, "repos": sorted(REPOS), "start_in": "Minerva"})
        self.assertEqual(self.agent("migrate", "alpha").returncode, 1)     # never twice
        self.start_alpha()
        dev = self.runs()[-1]
        for repo in REPOS:
            clone = self.home / "agent-work/t1" / repo
            self.assertIn(f"{clone}:{clone}", self.mounts(dev))
        self.assertEqual((sdir / "home/transcript").read_text(), "kept\n")
        git_log = (self.s / "git.log").read_text().splitlines()
        self.assertEqual(len(git_log), 3, git_log)                    # only the three missing clones
        self.assertFalse(any("ccsandbox" in line for line in git_log))

    def test_no_duplicate_launch_and_no_git_inside_existing_clones(self):
        self.assertEqual(self.agent("start", "alpha", "--harness", "claude", "--task", "t1").returncode, 0)
        again = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(again.returncode, 1)
        self.assertIn("already running", again.stderr)
        self.assertEqual(len(self.runs()), 2)
        # Restart after a stop: the clone is reused; the host runs no git inside it.
        clone = self.home / "agent-work/t1/Minerva"
        (clone / ".git/hooks/post-checkout").write_text("#!/bin/sh\ntouch /tmp/SHOULD-NOT-RUN\n")
        self.assertEqual(self.agent("stop", "alpha").returncode, 0)
        self.assertEqual(self.agent("start", "alpha", "--harness", "claude", "--task", "t1").returncode, 0)
        git_log = (self.s / "git.log").read_text().splitlines()
        self.assertEqual(len(git_log), len(REPOS), git_log)          # the four initial clones
        self.assertFalse(any(line.split("\t")[0].startswith(str(clone.parent)) for line in git_log))

    def test_changed_settings_for_a_name_are_refused(self):
        self.assertEqual(self.agent("start", "alpha", "--harness", "claude", "--task", "t1").returncode, 0)
        self.agent("stop", "alpha")
        saved = (self.home / "state/sessions/alpha/session.json").read_text()
        other = self.agent("start", "alpha", "--harness", "codex", "--task", "t1")
        self.assertEqual(other.returncode, 1)
        self.assertIn("different settings", other.stderr)
        self.assertEqual((self.home / "state/sessions/alpha/session.json").read_text(), saved)

    def test_missing_image_and_overlapping_work_root_are_refused(self):
        missing = self.agent("start", "alpha", "--harness", "claude", "--task", "t1",
                             env={**self.env, "FAKE_IMAGE": "absent"})
        self.assertEqual(missing.returncode, 1)
        self.assertIn("agent.py build", missing.stderr)
        for work in (self.home, self.home / "github", self.home / "github/Minerva/sub"):
            with self.subTest(work=work):
                result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1",
                                    env={**self.env, "MINERVA_AGENT_WORK": str(work)})
                self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.runs(), [])

    # ── attach ──
    def test_attach_binds_this_terminal_then_clears(self):
        self.assertEqual(self.agent("start", "alpha", "--harness", "claude", "--task", "t1").returncode, 0)
        no_terminal = {k: v for k, v in self.env.items() if k != "MINERVA_TERMINAL_ID"}
        refused = self.agent("attach", "alpha", env=no_terminal)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("Minerva terminal", refused.stderr)

        first = self.agent("attach", "alpha", "--notify-to", "2222",
                           env={**self.env, "FAKE_ATTACH_SECONDS": "3"}, wait=False)
        deadline = time.monotonic() + 5
        while self.binding().get("terminal_id") != "1111" and time.monotonic() < deadline:
            time.sleep(0.05)
        bound = self.binding()
        self.assertEqual((bound["terminal_id"], bound["notify_targets"]), ("1111", ["2222"]))
        # The gateway reads the binding's exact keys; Minerva's foreground
        # identity sits beside it, tied to the same lease generation.
        self.assertEqual(set(bound), {"terminal_id", "notify_targets", "generation", "expires_at"})
        launcher = self.home / "state/sessions/alpha/launcher.json"
        init_start = int(Path("/proc/1/stat").read_text().rsplit(")", 1)[1].split()[19])
        self.assertEqual(json.loads(launcher.read_text()),
                         {"generation": bound["generation"], "launcher_pgid": os.getpgid(first.pid),
                          "container_pid": 1, "container_start": init_start})
        # A second terminal cannot silently steal a live attach...
        second = self.agent("attach", "alpha", env={**self.env, "MINERVA_TERMINAL_ID": "9999"})
        self.assertEqual(second.returncode, 1)
        self.assertIn("--takeover", second.stderr)
        self.assertEqual(self.binding()["terminal_id"], "1111")
        first.wait(10)
        self.assertEqual(self.binding(), {})                          # detached: nothing to notify
        self.assertEqual(json.loads(launcher.read_text()), {})
        # ...and a new terminal after a Minerva restart rebinds.
        self.assertEqual(self.agent("attach", "alpha", env={**self.env, "MINERVA_TERMINAL_ID": "9999"})
                         .returncode, 0)
        attach = [c["argv"] for c in self.docker_calls() if "attach-session" in c["argv"]][-1]
        self.assertEqual(attach, ["exec", "-it", "minerva-agent-alpha",
                                  "tmux", "attach-session", "-d", "-t", "harness"])

    def test_takeover_and_hangup_clear_only_their_own_binding(self):
        self.assertEqual(self.agent("start", "alpha", "--harness", "claude", "--task", "t1").returncode, 0)
        first = self.agent("attach", "alpha", env={**self.env, "FAKE_ATTACH_SECONDS": "30"}, wait=False)
        deadline = time.monotonic() + 5
        while self.binding().get("terminal_id") != "1111" and time.monotonic() < deadline:
            time.sleep(0.05)
        second = self.agent("attach", "alpha", "--takeover",
                            env={**self.env, "MINERVA_TERMINAL_ID": "9999", "FAKE_ATTACH_SECONDS": "30"},
                            wait=False)
        while self.binding().get("terminal_id") != "9999" and time.monotonic() < deadline + 5:
            time.sleep(0.05)
        first.send_signal(1)   # the first tab's Minerva went away (SIGHUP)
        first.wait(10)
        self.assertEqual(self.binding()["terminal_id"], "9999")      # not cleared by the old client
        second.send_signal(1)
        second.wait(10)
        self.assertEqual(self.binding(), {})

    def test_attach_to_a_stopped_session_is_refused(self):
        result = self.agent("attach", "alpha")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not running", result.stderr)

    # ── lease, lock and takeover (review e56ed054) ──
    def test_a_killed_attach_stops_routing_when_its_lease_lapses(self):
        sys.path.insert(0, str(AGENT / "gateway"))
        import gateway
        env = {**self.env, "MINERVA_AGENT_LEASE_S": "2", "FAKE_ATTACH_SECONDS": "30"}
        self.start_alpha()
        client = self.agent("attach", "alpha", "--notify-to", "2222", env=env, wait=False)
        self.wait_bound("1111")
        path = self.home / "state/sessions/alpha/control/binding.json"
        first = self.binding()["expires_at"]
        time.sleep(1.2)                                     # renewed every lease/3 while alive
        self.assertGreater(self.binding()["expires_at"], first)
        self.assertEqual(gateway.read_binding(path).terminal_id, "1111")
        client.kill()                                       # SIGKILL: no cleanup runs
        client.wait(5)
        self.assertEqual(self.binding()["terminal_id"], "1111")
        time.sleep(2.2)
        self.assertIsNone(gateway.read_binding(path).terminal_id)   # the gateway treats it as gone
        again = self.agent("attach", "alpha", env={**env, "MINERVA_TERMINAL_ID": "9999",
                                                  "FAKE_ATTACH_SECONDS": "0"})
        self.assertEqual(again.returncode, 0, again.stderr)          # no --takeover needed

    def test_simultaneous_attaches_have_exactly_one_winner(self):
        self.start_alpha()
        env = {**self.env, "FAKE_ATTACH_SECONDS": "3"}
        clients = [subprocess.Popen([sys.executable, "-B", str(AGENT / "agent.py"), "attach", "alpha"],
                                    env={**env, "MINERVA_TERMINAL_ID": tid}, cwd=self.s, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True) for tid in ("1111", "9999")]
        results = [(c.wait(10), c.stderr.read()) for c in clients]
        for c in clients:
            c.stderr.close()
        self.assertEqual(sorted(rc for rc, _ in results), [0, 1], results)
        self.assertIn("--takeover", next(err for rc, err in results if rc == 1))

    def test_a_delayed_attach_cannot_detach_its_successor(self):
        self.start_alpha()
        first = self.agent("attach", "alpha", env={**self.env, "FAKE_ATTACH_DELAY": "1.5",
                                                   "FAKE_ATTACH_SECONDS": "30"}, wait=False)
        time.sleep(0.3)                                   # first is still establishing
        second = self.agent("attach", "alpha", "--takeover",
                            env={**self.env, "MINERVA_TERMINAL_ID": "9999", "FAKE_ATTACH_SECONDS": "30"},
                            wait=False)
        self.wait_bound("9999", timeout=10)
        time.sleep(2.0)                                   # past the first attach's delayed registration
        clients = json.loads((self.s / "docker-state.json").read_text())["clients"]
        self.assertEqual([c.split("-")[0] for c in clients], ["9999"])   # the successor holds the session
        for proc in (first, second):
            proc.send_signal(1)
            proc.wait(10)

    def test_hangup_or_timeout_while_establishing_cleans_up(self):
        self.start_alpha()
        # Minerva goes away while the attach is still establishing.
        establishing = self.agent("attach", "alpha", env={**self.env, "FAKE_ATTACH_DELAY": "4",
                                                          "FAKE_ATTACH_SECONDS": "30"}, wait=False)
        self.wait_bound("1111")
        time.sleep(0.5)
        started = time.monotonic()
        establishing.send_signal(1)
        self.assertNotEqual(establishing.wait(10), 0)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(self.binding(), {})
        # tmux stops answering after the client was launched: the query times out.
        timed_out = self.agent("attach", "alpha", env={**self.env, "FAKE_ATTACH_DELAY": "3",
                                                       "FAKE_ATTACH_SECONDS": "30", "FAKE_LIST_SLEEP": "5",
                                                       "MINERVA_AGENT_TMUX_QUERY_TIMEOUT_S": "1"})
        self.assertEqual(timed_out.returncode, 1)
        self.assertIn("did not answer", timed_out.stderr)
        self.assertEqual(self.binding(), {})
        time.sleep(4.5)       # past both delayed registrations: neither client lived to attach
        self.assertEqual(json.loads((self.s / "docker-state.json").read_text()).get("clients", []), [])

    def test_symlinked_clone_ancestors_are_refused_before_anything_happens(self):
        outside = self.s / "outside"
        (outside / "Minerva").mkdir(parents=True)
        work = self.home / "agent-work"
        work.mkdir()
        (self.home / "state/sessions/alpha/control").mkdir(parents=True)
        targets = {"t-out": outside, "t-checkout": self.home / "github",
                   "t-control": self.home / "state/sessions/alpha"}
        for task, target in targets.items():
            (work / task).symlink_to(target)
        (work / "t-leaf").mkdir()
        (work / "t-leaf" / "Minerva").symlink_to(outside / "Minerva")
        before = self.tree()
        for task in list(targets) + ["t-leaf"]:
            for command in ("start", "up"):
                with self.subTest(task=task, command=command):
                    result = self.agent(command, "alpha", "--harness", "claude", "--task", task)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("not a plain directory", result.stderr)
        mutating = [c for c in self.docker_calls() if c["argv"][0] in ("stop", "exec") or "run" in c["argv"]]
        self.assertEqual(mutating, [])
        self.assertEqual(self.tree(), before)
        self.assertFalse((self.s / "git.log").exists())

    def test_unreadable_saved_settings_are_refused_not_replaced(self):
        sdir = self.home / "state/sessions/alpha"
        sdir.mkdir(parents=True)
        for d in (self.home / "state", self.home / "state/sessions", sdir):
            d.chmod(0o700)
        for content in ("", "{not json", "[]", json.dumps({"harness": "claude"})):
            with self.subTest(content=content):
                (sdir / "session.json").write_text(content)
                result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
                self.assertEqual(result.returncode, 1)
                self.assertIn("unreadable or incomplete", result.stderr)
                self.assertEqual((sdir / "session.json").read_text(), content)
        self.assertEqual(self.runs(), [])

    def test_up_refuses_a_running_session_started_differently(self):
        self.start_alpha()
        other = self.agent("up", "alpha", "--harness", "codex", "--task", "t1")
        self.assertEqual(other.returncode, 1)
        self.assertIn("different settings", other.stderr)
        self.assertFalse([c for c in self.docker_calls() if "attach-session" in c["argv"]])
        same = self.agent("up", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(same.returncode, 0, same.stderr)
        self.assertEqual(len(self.runs()), 2)                       # attached, not started again

    def test_modes_and_note_grants(self):
        note_a, note_b = "a" * 64, "b" * 64
        self.start_alpha("--mode", "resume", "--note-read", note_a, "--note-write", note_b)
        self.assertEqual(self.runs()[-1][-2:], ["claude", "resume"])
        notes = self.home / "state/sessions/alpha/control/notes.json"
        self.assertEqual(json.loads(notes.read_text()), {"read": [note_a], "write": [note_b]})
        self.assertEqual(self.agent("notes", "alpha", "--note-read", note_b).returncode, 0)
        self.assertEqual(json.loads(notes.read_text()), {"read": [note_b], "write": []})
        bad = self.agent("notes", "alpha", "--note-write", "not-a-note")
        self.assertEqual(bad.returncode, 1)
        self.assertEqual(json.loads(notes.read_text()), {"read": [note_b], "write": []})

    def test_unsafe_layouts_are_refused_before_anything_happens(self):
        clone_state = self.home / "agent-work/t1/Minerva/.state"
        (self.s / "real-state").mkdir()
        (self.s / "linked-state").symlink_to(self.s / "real-state")
        cases = {
            "state inside a writable clone": {"MINERVA_AGENT_STATE": str(clone_state)},
            "work root inside the state root": {"MINERVA_AGENT_WORK": str(self.home / "state/work")},
            "state inside a host checkout": {"MINERVA_AGENT_STATE": str(self.home / "github/Minerva/.s")},
            "symlinked state root": {"MINERVA_AGENT_STATE": str(self.s / "linked-state/x")},
            "colon in the work root": {"MINERVA_AGENT_WORK": str(self.s / "w:x")},
            "relative state root": {"MINERVA_AGENT_STATE": "state"},
        }
        before = self.tree()
        for label, extra in cases.items():
            for command in (["start", "alpha", "--harness", "claude", "--task", "t1"], ["stop", "alpha"],
                            ["attach", "alpha"], ["notes", "alpha"]):
                with self.subTest(label=label, command=command[0]):
                    result = self.agent(*command, env={**self.env, **extra})
                    self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.docker_calls(), [])
        self.assertEqual(self.tree(), before)

    def test_an_open_control_directory_is_refused(self):
        control = self.home / "state/sessions/alpha/control"
        control.mkdir(parents=True)
        control.chmod(0o777)
        for d in (self.home / "state", self.home / "state/sessions", self.home / "state/sessions/alpha"):
            d.chmod(0o700)
        result = self.agent("start", "alpha", "--harness", "claude", "--task", "t1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no group/other access", result.stderr)
        self.assertEqual(self.runs(), [])
        self.assertFalse((self.home / "state/sessions/alpha/session.json").exists())

    # ── stop ──
    def test_stop_stops_both_containers_and_keeps_every_file(self):
        self.assertEqual(self.agent("start", "alpha", "--harness", "codex", "--task", "t1").returncode, 0)
        (self.home / "state/sessions/alpha/home/auth.json").write_text("{}")
        before = self.tree()
        self.assertEqual(self.agent("stop", "alpha").returncode, 0)
        stops = [c["argv"] for c in self.docker_calls() if c["argv"][0] == "stop"]
        self.assertEqual(stops, [["stop", "minerva-agent-alpha"], ["stop", "minerva-agent-gw-alpha"]])
        after = self.tree()
        self.assertTrue(set(before) <= set(after), set(before) - set(after))


class StaticTest(unittest.TestCase):
    def test_image_pins_match_the_test_image(self):
        def pins(path):
            return dict(re.findall(r"(?m)^ARG ((?:GODOT|NODE)_\w+)=(\S+)$", path.read_text()))
        ours, theirs = pins(AGENT / "Dockerfile"), pins(ROOT / "scripts/container-test/Dockerfile")
        self.assertEqual(set(ours), {"GODOT_VERSION", "GODOT_SHA512", "NODE_VERSION", "NODE_SHA256"})
        self.assertEqual(ours, theirs)

    def test_image_copies_every_file_the_launcher_hashes(self):
        sys.path.insert(0, str(AGENT))
        import agent
        dockerfile = (AGENT / "Dockerfile").read_text()
        for name in agent.IMAGE_FILES[1:]:
            self.assertIn(name, dockerfile)
        self.assertIn("COPY gateway/", dockerfile)

    def test_scripts_parse(self):
        self.assertTrue(os.access(AGENT / "minerva-session", os.X_OK))
        self.assertTrue(os.access(AGENT / "agent-upgrade", os.X_OK))
        for script in ("minerva-session", "agent-env.sh", "agent-bashrc", "agent-upgrade"):
            subprocess.run(["bash", "-n", str(AGENT / script)], check=True)

    def test_session_shell_runs_only_a_fixed_first_command(self):
        scratch = short_scratch()
        stub = scratch / "claude"
        stub.write_text(f"#!/bin/sh\necho \"$*\" >> {scratch}/calls\n")
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{scratch}:{os.environ['PATH']}", "MINERVA_AGENT_DIR": str(AGENT)}
        for first in ("claude --resume", "touch INJECTED", "claude; touch INJECTED"):
            subprocess.run(["bash", "--rcfile", str(AGENT / "agent-bashrc"), "-i", "-c", "true"],
                           env={**env, "MINERVA_AGENT_FIRST": first}, cwd=scratch,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        self.assertEqual((scratch / "calls").read_text().splitlines(),
                         [f"--mcp-config {AGENT}/claude-mcp.json --strict-mcp-config --resume"])
        self.assertFalse((scratch / "INJECTED").exists())

    def test_upgrade_installs_into_the_session_tools_dir(self):
        # A stub npm stands in for the registry; it records its argv and
        # drops a fake harness binary where the real install would.
        scratch = short_scratch()
        tools = scratch / "tools"
        (scratch / "npm").write_text(
            f"#!/bin/sh\necho \"$*\" >> {scratch}/npm-calls\nmkdir -p {tools}/bin\n"
            f"printf '#!/bin/sh\\necho 9.9.9\\n' > {tools}/bin/claude\nchmod +x {tools}/bin/claude\n")
        (scratch / "npm").chmod(0o755)
        env = {**os.environ, "PATH": f"{scratch}:{os.environ['PATH']}", "MINERVA_AGENT_TOOLS": str(tools)}
        def upgrade(*args):
            return subprocess.run([str(AGENT / "agent-upgrade"), *args], env=env,
                                  capture_output=True, text=True, timeout=20)
        done = upgrade("claude", "2.1.280")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "9.9.9")
        for bad in (["bash"], [], ["claude", "1.0; touch INJECTED"], ["claude", "--registry=x"]):
            with self.subTest(bad=bad):
                self.assertEqual(upgrade(*bad).returncode, 2)
        self.assertEqual((scratch / "npm-calls").read_text().splitlines(),
                         [f"install -g --prefix {tools} --no-fund --no-audit --no-update-notifier "
                          "@anthropic-ai/claude-code@2.1.280"])

    @unittest.skipUnless(shutil.which("docker"), "docker CLI not installed")
    def test_compose_services_are_hardened(self):
        # `docker compose config` only parses the file; it starts nothing.
        env = {**os.environ, "MINERVA_AGENT_IMAGE": "minerva-agent:test", "AGENT_UID": "1000", "AGENT_GID": "1000"}
        out = subprocess.run(["docker", "compose", "-f", str(AGENT / "docker-compose.yml"), "--profile", "session",
                              "config", "--format", "json"], env=env, capture_output=True, text=True, check=True)
        services = json.loads(out.stdout)["services"]
        self.assertEqual(set(services), {"gateway", "dev"})
        for name, svc in services.items():
            with self.subTest(name):
                self.assertTrue(svc["read_only"])
                self.assertEqual(svc["cap_drop"], ["ALL"])
                self.assertIn("no-new-privileges:true", svc["security_opt"])
                self.assertEqual(svc["user"], "1000:1000")
                self.assertNotIn("volumes", svc)                 # every mount comes from agent.py
                self.assertFalse(svc.get("privileged", False))
        self.assertEqual(services["gateway"]["network_mode"], "host")
        self.assertEqual(services["dev"]["network_mode"], "none")


class ForwarderTest(unittest.TestCase):
    def test_loopback_port_reaches_the_socket(self):
        scratch = short_scratch()
        path = scratch / "echo.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen()

        def echo():
            conn, _ = server.accept()
            with conn:
                conn.sendall(conn.recv(100).upper())
        threading.Thread(target=echo, daemon=True).start()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        ready = scratch / "ready"
        proc = subprocess.Popen([sys.executable, "-B", str(AGENT / "forwarder.py"), "--ready", str(ready),
                                 str(scratch), f"{port}=echo"])
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    client = socket.create_connection(("127.0.0.1", port), timeout=5)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(0.05)
            with client:
                client.sendall(b"ping")
                self.assertEqual(client.recv(100), b"PING")
            self.assertTrue(ready.exists())
        finally:
            proc.terminate()
            proc.wait(5)
            server.close()

    def test_a_port_it_cannot_bind_fails_startup(self):
        scratch = short_scratch()
        with socket.socket() as taken:
            taken.bind(("127.0.0.1", 0))
            taken.listen()
            port = taken.getsockname()[1]
            result = subprocess.run([sys.executable, "-B", str(AGENT / "forwarder.py"), "--ready",
                                     str(scratch / "ready"), str(scratch), f"{port}=echo"],
                                    capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot listen", result.stderr)
        self.assertFalse((scratch / "ready").exists())


if __name__ == "__main__":
    unittest.main()
