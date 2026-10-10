"""Linux agent-container oracle: registered source-built Docket -> Minerva.

Seed MINERVA_TEST_PROFILE_ROOT with scripts/lib/test-profile.sh first. Run:
python3 src/test/fixtures/docket_attach_real.py --scratch "$MINERVA_TEST_PROFILE_ROOT" \
    --minerva-project /isolated/minerva/src --docket-project /isolated/docket
Raw logs remain in the isolated scratch; stdout contains fixed receipts only.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def run(minerva: Path, docket: Path, scratch: Path, godot: str) -> int:
    if not scratch.is_absolute() or os.environ.get("MINERVA_TEST_PROFILE_ROOT") != str(scratch):
        raise RuntimeError("isolated seeded profile required")
    if not Path("/proc").is_dir():
        raise RuntimeError("Linux agent container required")
    environment = os.environ.copy()
    for key in ("DOCKET_SESSION_DIR", "DOCKET_PANEL_SECRET"):
        environment.pop(key, None)
    profile = scratch / "Docket"
    profile.mkdir(exist_ok=False)
    environment["DOCKET_ATTACH_PROFILE"] = str(profile)
    logs = scratch / "logs"
    logs.mkdir(exist_ok=False)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    if port == 3010:
        raise RuntimeError("live service port refused")
    with (logs / "docket.log").open("wb") as log:
        process = subprocess.Popen([godot, "--headless", "--path", str(docket), "--", "--serve",
            "--state-dir", str(profile), "--file", str(scratch / "attach-fixture.dct"), "--port", str(port)],
            env=environment, stdout=log, stderr=log)
        try:
            registration = profile / "instance.json"
            deadline = time.monotonic() + 10
            while not registration.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("registration unavailable")
                time.sleep(0.05)
            if json.loads(registration.read_text())["pid"] != process.pid:
                raise RuntimeError("registration PID mismatch")
            with (logs / "minerva.log").open("wb") as result_log:
                result = subprocess.run([godot, "--headless", "--path", str(minerva), "--script",
                    "res://test/helpers/docket_attach_real.gd"], env=environment,
                    stdout=result_log, stderr=result_log, timeout=90)
            text = (logs / "minerva.log").read_text()
            processes = 0
            for command in Path("/proc").glob("[0-9]*/cmdline"):
                try:
                    args = command.read_bytes().split(b"\0")
                except OSError:
                    continue
                if str(profile).encode() in args and b"--state-dir" in args and b"--serve" in args:
                    processes += 1
            receipt = {"exit": result.returncode, "script_errors": text.count("SCRIPT ERROR:"),
                "passed": sum(line.startswith("PASS:") for line in text.splitlines()),
                "failed": sum(line.startswith("FAIL:") for line in text.splitlines()),
                "docket_alive": process.poll() is None, "docket_process_count": processes}
            (logs / "receipt.json").write_text(json.dumps(receipt) + "\n")
            print(json.dumps(receipt))
            return 0 if result.returncode == 0 and receipt["script_errors"] == 0 and receipt["failed"] == 0 \
                and receipt["docket_alive"] and processes == 1 else 1
        finally:
            # Only the private child this oracle launched is terminated.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minerva-project", type=Path, required=True)
    parser.add_argument("--docket-project", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--godot", default="godot")
    args = parser.parse_args()
    raise SystemExit(run(args.minerva_project.resolve(), args.docket_project.resolve(), args.scratch, args.godot))
