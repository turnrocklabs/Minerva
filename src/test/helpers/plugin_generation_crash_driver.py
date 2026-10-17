"""Pin fresh-profile production recovery and an external random in-flight SIGKILL."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import signal
import subprocess
import time
from collections import Counter
from pathlib import Path

from plugin_live_swap_driver import diagnostics, normalized, profile_env


def run(command: list[str], env: dict[str, str], log: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, env=env, capture_output=True, text=True,
                            timeout=60, check=False)
    log.write_text(result.stdout + "\n" + result.stderr, encoding="utf-8")
    return result


def receipt(raw: str) -> dict[str, object]:
    """Godot returns dynamic JSON; main checks the required oracle fields."""
    for line in raw.splitlines():
        if line.startswith("CRASH_RECEIPT:"):
            value: dict[str, object] = json.loads(line.removeprefix("CRASH_RECEIPT:"))
            return value
    raise ValueError("missing crash receipt")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--seed-user-dir", required=True)
    parser.add_argument("--require-release", action="store_true")
    args = parser.parse_args()
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    nonce = secrets.token_hex(40)
    command = [args.godot, "--headless", "--path", args.project, "--script",
               "res://test/test_plugin_generation_crash.gd", "--", "--nonce", nonce]
    seed = Path(args.seed_user_dir)
    baseline = run(command + ["--crash-mode", "baseline"],
                   profile_env(evidence, seed), evidence / "baseline.log")
    env = profile_env(evidence, seed)
    initial = run(command + ["--crash-mode", "seed"], env, evidence / "seed.log")
    initial_receipt = receipt(initial.stdout)
    data_path = Path(env["XDG_DATA_HOME"]) / "godot/app_userdata/Minerva/production-crash-data.bin"
    expected_bytes = bytes.fromhex(nonce)
    initial_bytes_ok = data_path.read_bytes() == expected_bytes
    delay = secrets.SystemRandom().uniform(0.005, 0.08)
    loop_log = evidence / "killed.log"
    observed = False
    killed_in_flight = False
    with loop_log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command + ["--crash-mode", "loop"], env=env,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            end = time.monotonic() + 45
            while process.poll() is None and time.monotonic() < end:
                raw = loop_log.read_text(encoding="utf-8", errors="replace")
                if "CRASH_READY:" + nonce in raw:
                    observed = True
                    time.sleep(delay)
                    before_kill = loop_log.read_text(encoding="utf-8", errors="replace")
                    killed_in_flight = "CRASH_SWAP_DONE:" + nonce not in before_kill
                    os.killpg(process.pid, signal.SIGKILL)
                    break
                time.sleep(0.005)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
    after_kill_bytes_ok = data_path.read_bytes() == expected_bytes
    boot = run(command + ["--crash-mode", "boot"], env, evidence / "boot.log")
    recovered = receipt(boot.stdout)
    baseline_counts = Counter(normalized(*item) for item in diagnostics(baseline.stdout + baseline.stderr))
    unexpected: list[str] = []
    for label, raw in (("seed", initial.stdout + initial.stderr),
                       ("kill", loop_log.read_text()), ("boot", boot.stdout + boot.stderr)):
        remaining = baseline_counts.copy()
        for header, origin in diagnostics(raw):
            key = normalized(header, origin)
            if remaining[key] > 0:
                remaining[key] -= 1
            else:
                unexpected.append(label + ": " + header)
    release_ok = recovered.get("release") is True and recovered.get("editor") is False
    ok = baseline.returncode == initial.returncode == boot.returncode == 0
    ok = ok and initial_receipt.get("ok") is True and recovered.get("ok") is True
    ok = ok and recovered.get("nonce") == nonce and recovered.get("data_hex") == nonce
    ok = ok and initial_bytes_ok and after_kill_bytes_ok and data_path.read_bytes() == expected_bytes
    ok = ok and observed and killed_in_flight and process.returncode == -signal.SIGKILL
    ok = ok and not unexpected and (release_ok or not args.require_release)
    report = {"ok": ok, "nonce": nonce, "delay_seconds": delay, "candidate_ready_observed": observed,
              "killed_before_first_publication": killed_in_flight, "signal_returncode": process.returncode,
              "initial": initial_receipt, "recovered": recovered, "unexpected": unexpected,
              "user_data_sha256": hashlib.sha256(data_path.read_bytes()).hexdigest(),
              "driver_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (evidence / "crash-receipt.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
