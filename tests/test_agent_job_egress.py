"""Opaque local socket fixtures only: no Core calls or external network."""
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import ModuleType

GATEWAY = Path(__file__).resolve().parents[1] / "scripts/agent-container/gateway"
sys.path.insert(0, str(GATEWAY))
import job_egress

sys.path.insert(0, str(GATEWAY.parent))
import jobs


class EgressTest(unittest.TestCase):
    def test_hard_killed_container_is_observed_and_its_owned_sidecar_stops(self) -> None:
        if not shutil.which("docker"):
            self.skipTest("Docker CLI unavailable for offline lifecycle fixture")
        image = "minerva-agent:cc53fded52db"
        if subprocess.run(["docker", "image", "inspect", image], capture_output=True, check=False).returncode:
            self.skipTest("existing offline fixture image unavailable")
        directory = Path(tempfile.mkdtemp(prefix="job-hard-kill-"))
        job_id = "j20261024t230000-" + secrets.token_hex(3)
        primary = "minerva-test-" + job_id
        sidecar = primary + "-egress"
        host = ModuleType("offline_job_fixture")
        host.session_lock = lambda *_: nullcontext()
        host.read_json = lambda p: json.loads(p.read_text()) if p.exists() else {}
        host.write_json = lambda p, data: p.write_text(json.dumps(data))
        host.private_dir = lambda p: (p.mkdir(mode=0o700, exist_ok=True), p)[1]
        # Match job_dir's ordinary session layout without changing that owner.
        session = directory / "session"
        job_directory = session / "jobs" / job_id
        (job_directory / "out").mkdir(parents=True)
        # Fixture paths are supplied by the same host contract as the launcher.
        host.session_dir = lambda _: session

        def state(container: str) -> str:
            probe = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                                   capture_output=True, text=True, check=False)
            return "running" if probe.returncode == 0 and probe.stdout.strip() == "true" else "stopped"
        host.docker_state = state
        record = {"id": job_id, "container": primary, "limits": {"seconds": 60},
                  "started_at": time.time(), "network": "core", "env_from": [], "artifacts": [],
                  "revision_requested": "HEAD", "folder": "fixture", "command": "sleep",
                  "egress": {"container": sidecar}}
        host.write_json(job_directory / "job.json", record)
        launched = []
        try:
            for container in (primary, sidecar):
                subprocess.run(["docker", "run", "-d", "--rm", "--network", "none", "--read-only",
                                "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                                "--user", f"{os.getuid()}:{os.getgid()}", "--name", container,
                                "--label", f"{jobs.JOB_LABEL}={job_id}", image, "sleep", "60"],
                               capture_output=True, check=True)
                launched.append(container)
            observer = threading.Thread(target=jobs.wait_private_output, args=(host, "fixture", job_id, {}))
            observer.start()
            subprocess.run(["docker", "kill", "--signal", "KILL", primary], capture_output=True, check=True)
            killed_at = time.monotonic()
            observer.join(5)
            self.assertFalse(observer.is_alive(), "exit observer did not finish within seconds")
            self.assertLess(time.monotonic() - killed_at, 5)
            self.assertEqual(state(sidecar), "stopped")
            self.assertTrue(host.read_json(job_directory / "finalization.json")["scanned"])
            self.assertEqual(host.read_json(job_directory / "result.json")["class"], "unknown")
        finally:
            for container in launched:
                subprocess.run(["docker", "stop", "-t", "0", container], capture_output=True, check=False)

    def test_fixed_routes_relay_opaque_bytes_and_reject_private_dns(self) -> None:
        directory = Path(tempfile.mkdtemp(prefix="job-egress-"))
        fixture = socket.create_server(("127.0.0.1", 0))
        fixture.settimeout(5)
        received = []
        connections = []

        def echo() -> None:
            for _ in range(2):
                client, _ = fixture.accept()
                with client:
                    data = client.recv(100)
                    received.append(data)
                    client.sendall(data)

        def connect(ip: str, port: int) -> socket.socket:
            connections.append((ip, port))
            return socket.create_connection(fixture.getsockname(), timeout=5)

        def resolve(_host: str) -> list[str]:
            return ["8.8.8.8"]

        echo_thread = threading.Thread(target=echo, daemon=True)
        echo_thread.start()
        stop = threading.Event()
        servers = job_egress.build_servers(directory, stop, resolve=resolve, connect=connect)
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            opaque = b"\x16\x03\x01opaque-TLS-payload\x00"
            for route in ["auth", "core"]:
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(5)
                    client.connect(str(directory / (route + ".sock")))
                    client.sendall(opaque)
                    self.assertEqual(client.recv(100), opaque)
            self.assertEqual(connections, [("8.8.8.8", 4040), ("8.8.8.8", 27500)])
            self.assertEqual(received, [opaque, opaque])
            self.assertEqual({p.name for p in directory.iterdir()}, {"auth.sock", "core.sock", "stop.sock"})
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(directory / "stop.sock"))
            self.assertTrue(stop.wait(2))
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            fixture.close()
            echo_thread.join(2)

        denied = Path(tempfile.mkdtemp(prefix="job-egress-deny-"))

        def mixed_dns(_host: str) -> list[str]:
            return ["8.8.8.8", "127.0.0.1"]

        servers = job_egress.build_servers(denied, threading.Event(), resolve=mixed_dns, connect=connect)
        threading.Thread(target=servers[0].serve_forever, daemon=True).start()
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5)
                client.connect(str(denied / "auth.sock"))
                self.assertEqual(client.recv(1), b"")
            self.assertEqual(len(connections), 2)
        finally:
            servers[0].shutdown()
            for server in servers:
                server.server_close()

    def test_sidecar_exits_at_its_own_deadline(self) -> None:
        directory = Path(tempfile.mkdtemp(prefix="job-egress-deadline-"))
        result = subprocess.run([sys.executable, "-B", str(GATEWAY / "job_egress.py"),
                                 "--sockets", str(directory), "--seconds", "1"],
                                check=False, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(directory.glob("*.sock"))), 3)
        refused = Path(tempfile.mkdtemp(prefix="job-egress-target-"))
        result = subprocess.run([sys.executable, "-B", str(GATEWAY / "job_egress.py"),
                                 "--sockets", str(refused), "--seconds", "1",
                                 "--destination", "example.com:443"],
                                check=False, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(refused.iterdir()))


if __name__ == "__main__":
    unittest.main()
