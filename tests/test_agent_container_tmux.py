"""The agent container's tmux turns Minerva's wheel into the right history.

A real tmux server runs with scripts/agent-container/tmux.conf on a private
socket; a real client attaches through a pseudo-terminal, standing in for the
Minerva terminal, and receives the xterm SGR wheel bytes Minerva sends while
the outer terminal tracks the mouse (TerminalNew._forward_wheel). Checks:

  - tmux asks the outer terminal for mouse input (so Minerva forwards the wheel);
  - on a shell pane the wheel enters copy-mode and scrolls tmux's history;
  - when the program in the pane tracks the mouse itself (as Claude Code
    does), tmux hands it the wheel and stays out of copy-mode.

    python3 -m unittest tests.test_agent_container_tmux
"""
import fcntl
import os
from pathlib import Path
import pty
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import unittest

CONF = Path(__file__).resolve().parents[1] / "scripts/agent-container/tmux.conf"
WHEEL_UP = b"\x1b[<64;10;5M"


@unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
class ContainerTmuxWheelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tmuxwheel-")
        self.env = {**os.environ, "TMUX_TMPDIR": self.tmp, "TERM": "xterm-256color"}
        self.env.pop("TMUX", None)
        self.clients = []

    def tearDown(self):
        subprocess.run(self.tmux("kill-server"), env=self.env, capture_output=True)
        for pid, fd in self.clients:
            os.close(fd)
            os.waitpid(pid, 0)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tmux(self, *args):
        return ["tmux", "-L", "wheeltest", "-f", str(CONF), *args]

    def query(self, fmt, target):
        return subprocess.run(self.tmux("display-message", "-p", "-t", target, fmt), env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def attach(self, session):
        """Attach a client in a pty; return its master fd and what it has drawn so far."""
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("tmux", self.tmux("attach-session", "-t", session), self.env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.clients.append((pid, fd))
        return fd, self.drain(fd, 1.0)

    @staticmethod
    def drain(fd, seconds):
        out, end = b"", time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                os.set_blocking(fd, False)
                out += os.read(fd, 65536)
            except (BlockingIOError, OSError):
                time.sleep(0.05)
        return out

    def wait_for(self, predicate, seconds=5.0):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if predicate():
                return True
            time.sleep(0.1)
        return False

    def test_wheel_scrolls_shell_history_and_reaches_a_mouse_tracking_program(self):
        subprocess.run(self.tmux("new-session", "-d", "-s", "shell", "-x", "80", "-y", "24",
                                 "bash --norc -c 'seq 1 300; exec sleep 60'"), env=self.env, check=True)
        fd, drawn = self.attach("shell")
        self.assertIn(b"\x1b[?1006h", drawn, "tmux must ask the outer terminal for SGR mouse input")
        # tmux's default binding: the first notch enters copy-mode, later ones scroll.
        for _ in range(3):
            os.write(fd, WHEEL_UP)
            time.sleep(0.2)
        self.assertTrue(self.wait_for(lambda: self.query("#{pane_in_mode}", "shell") == "1"),
                        "the wheel over a shell pane enters copy-mode")
        self.assertTrue(self.wait_for(lambda: int(self.query("#{scroll_position}", "shell") or 0) > 0),
                        "and scrolls into history")

        out = Path(self.tmp) / "received"
        program = ("printf '\\033[?1003h\\033[?1006h'; stty raw -echo; "
                   f"dd bs=1 count={len(WHEEL_UP)} 2>/dev/null > {out}; sleep 60")
        subprocess.run(self.tmux("new-session", "-d", "-s", "app", "-x", "80", "-y", "24",
                                 f"sh -c \"{program}\""), env=self.env, check=True)
        self.assertTrue(self.wait_for(lambda: self.query("#{mouse_any_flag}", "app") == "1"))
        fd, _ = self.attach("app")
        os.write(fd, WHEEL_UP)
        self.assertTrue(self.wait_for(lambda: out.exists() and out.stat().st_size >= len(WHEEL_UP)),
                        "the program tracking the mouse receives the wheel")
        self.assertTrue(out.read_bytes().startswith(b"\x1b[<64;"), out.read_bytes())
        self.assertEqual(self.query("#{pane_in_mode}", "app"), "0", "and tmux stays out of copy-mode")


if __name__ == "__main__":
    unittest.main()
