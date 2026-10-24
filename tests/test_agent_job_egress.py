"""Opaque local socket fixtures only: no Core calls or external network."""
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

GATEWAY = Path(__file__).resolve().parents[1] / "scripts/agent-container/gateway"
sys.path.insert(0, str(GATEWAY))
import job_egress


class EgressTest(unittest.TestCase):
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
