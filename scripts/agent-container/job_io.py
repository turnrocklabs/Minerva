"""Private job output: filter pipes and finalize retained output after exit.

Only the variable names are persisted by the launcher. Values arrive through
the process environment, never a command argument or a runner-owned file.
This is accidental-disclosure protection, not containment of malicious jobs:
the test still owns sanitizing selected evidence and newly minted auth data.
"""
import base64
import json
import os
import re
import secrets
import select
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import TypedDict
from urllib.parse import quote, quote_plus


def redaction_values(strings: list[str]) -> list[bytes]:
    values = set()
    for value in strings:
        values.add(value.encode())
        values.update(encoded.encode() for encoded in (quote(value), quote(value, safe=""), quote_plus(value)))
        for ascii_only in [False, True]:
            values.add(json.dumps(value, ensure_ascii=ascii_only)[1:-1].encode())
    # Names need not be supplied in username/password order. Mask each pairing.
    values.update(base64.b64encode(f"{user}:{password}".encode())
                  for user in strings for password in strings)
    return sorted(filter(None, values), key=len, reverse=True)


def private_values() -> list[bytes]:
    names = os.environ.get("MINERVA_JOB_ENV_FROM", "").split(",")
    return redaction_values([os.environ[name] for name in filter(None, names)])


class Redactor:
    """Retain enough overlap to mask values split across pipe reads."""

    def __init__(self, values: list[bytes]) -> None:
        self.pattern = re.compile(b"|".join(re.escape(v) for v in values)) if values else None
        self.width = max(map(len, values), default=1)
        self.pending = b""
        self.found = False

    def feed(self, data: bytes, final: bool = False) -> bytes:
        self.pending += data
        limit = len(self.pending) if final else max(0, len(self.pending) - self.width + 1)
        offset = 0
        output = bytearray()
        while offset < limit:
            match = self.pattern.search(self.pending, offset) if self.pattern else None
            if match is None or match.start() >= limit:
                output.extend(self.pending[offset:limit])
                offset = limit
            else:
                output.extend(self.pending[offset:match.start()])
                output.extend(b"[REDACTED]")
                self.found = True
                offset = match.end()
        self.pending = self.pending[offset:]
        return bytes(output)


def check_artifact(path: Path, values: list[bytes]) -> None:
    """Check a stopped job's retained file; never validate a live copy source."""
    if path.absolute() != path.resolve():
        raise ValueError("linked artifact refused")
    for candidate in [path, *(path.rglob("*") if path.is_dir() else [])]:
        name = Redactor(values)
        name.feed(str(candidate.relative_to(path.parent)).encode(), final=True)
        if name.found:
            raise ValueError("inherited environment content in artifact name")
        mode = candidate.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError("non-regular artifact refused")
        redactor = Redactor(values)
        with candidate.open("rb") as stream:
            while chunk := stream.read(65536):
                redactor.feed(chunk)
                if redactor.found:
                    raise ValueError("inherited environment content in artifact; sanitize it first")
        redactor.feed(b"", final=True)
        if redactor.found:
            raise ValueError("inherited environment content in artifact; sanitize it first")


class Finalization(TypedDict):
    scanned: bool
    refused: int


def finalize_output(out: Path, values: list[bytes], quarantine: Path) -> Finalization:
    """Called only after the container exits, when it has no surviving writers.

    Quarantine is private and outside the evidence tree. Its random names do
    not repeat potentially sensitive original filenames in metadata.
    """
    quarantine.mkdir(mode=0o700, exist_ok=True)
    refused = 0

    def visit(directory: Path) -> None:
        nonlocal refused
        for candidate in directory.iterdir():
            name = Redactor(values)
            name.feed(candidate.name.encode(), final=True)
            mode = candidate.lstat().st_mode
            if name.found or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                candidate.rename(quarantine / secrets.token_hex(16))
                refused += 1
            elif stat.S_ISDIR(mode):
                visit(candidate)
            elif candidate == out / "job.log":
                redactor = Redactor(values)
                sanitized = quarantine.parent / "sanitized-log"
                with candidate.open("rb") as source, sanitized.open("wb") as target:
                    while chunk := source.read(65536):
                        target.write(redactor.feed(chunk))
                    target.write(redactor.feed(b"", final=True))
                sanitized.replace(candidate)
            else:
                try:
                    check_artifact(candidate, values)
                except ValueError:
                    candidate.rename(quarantine / secrets.token_hex(16))
                    refused += 1

    visit(out)
    return {"scanned": True, "refused": refused}


def stop_egress() -> None:
    if os.environ.get("MINERVA_JOB_NETWORK") != "core":
        return
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(1)
            client.connect("/run/minerva-agent/core/stop.sock")
    except OSError:
        pass  # Sidecar's deadline and host reconciliation are the fallbacks.


def run(out: Path = Path("/out"), script: Path = Path("/job/run.sh")) -> int:
    started = time.monotonic()
    forwarder = None
    process = None
    redactor = Redactor(private_values())
    rc = 98
    with (out / "job.log").open("ab", buffering=0) as log:
        try:
            if os.environ.get("MINERVA_JOB_NETWORK") == "core":
                ready = Path("/tmp/core-forwarder.ready")
                environment = {k: v for k, v in os.environ.items()
                               if k not in os.environ.get("MINERVA_JOB_ENV_FROM", "").split(",")}
                forwarder = subprocess.Popen(
                    [sys.executable, "-B", "/opt/minerva-agent/forwarder.py", "--ready", str(ready),
                     "/run/minerva-agent/core", "4040=auth", "27500=core"],
                    env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deadline = time.monotonic() + 5
                while not ready.exists():
                    if forwarder.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Core loopback forwarder did not become ready")
                    time.sleep(0.05)
            process = subprocess.Popen(
                ["timeout", "-k", "10", os.environ["MINERVA_JOB_DEADLINE"], "bash", str(script)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            signal.signal(signal.SIGTERM, lambda sig, _frame: process.send_signal(sig))
            assert process.stdout is not None
            deadline = started + int(os.environ["MINERVA_JOB_DEADLINE"]) + 10
            timed_out = False
            while time.monotonic() < deadline:
                if select.select([process.stdout], [], [], max(0, min(1, deadline - time.monotonic())))[0]:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        try:
                            rc = process.wait(timeout=max(0.01, deadline - time.monotonic()))
                        except subprocess.TimeoutExpired:
                            timed_out = True
                        break
                    log.write(redactor.feed(chunk))
            else:
                timed_out = True
            if timed_out:
                # A detached child can retain stdout after its parent exits.
                # Only this launched process group is retired; no PID discovery.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
                rc = 124
                (out / "ended").write_text(f"command 124 {int(time.monotonic() - started)}\n")
        except (OSError, RuntimeError) as error:
            log.write(redactor.feed((str(error) + "\n").encode()))
            (out / "ended").write_text(f"setup 98 {int(time.monotonic() - started)}\n")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            if forwarder is not None:
                forwarder.terminate()
                try:
                    forwarder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    forwarder.kill()
                    forwarder.wait(timeout=5)
            stop_egress()
            log.write(redactor.feed(b"", final=True))
            (out / "exit").write_text(f"{rc} {int(time.monotonic() - started)}\n")
    return rc


def main() -> int:
    if sys.argv[1:] == ["run"]:
        return run()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
