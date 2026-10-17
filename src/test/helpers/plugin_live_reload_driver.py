"""Audit real marketplace startup refusal in a retained integration child log."""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

from plugin_live_swap_driver import diagnostics, normalized, profile_env, run_case


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("godot", "project", "evidence", "seed-user-dir"):
        parser.add_argument("--" + argument, required=True)
    args = parser.parse_args()
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    command = [args.godot, "--headless", "--path", args.project, "--script",
               "res://test/test_plugin_live_reload.gd", "--", "--live-integration-child"]
    baseline_path = evidence / "live-integration-baseline.log"
    child_path = evidence / "live-integration-child.log"
    baseline = run_case(command + ["--live-integration-baseline"],
                        profile_env(evidence, Path(args.seed_user_dir)), baseline_path)
    child = run_case(command, profile_env(evidence, Path(args.seed_user_dir)), child_path)
    remaining = Counter(normalized(*item) for item in diagnostics(baseline_path.read_text()))
    unexpected: list[str] = []
    for header, origin in diagnostics(child_path.read_text()):
        key = normalized(header, origin)
        if remaining[key] > 0:
            remaining[key] -= 1
        else:
            unexpected.append(header.replace("SCRIPT ERROR:", "Child diagnostic:"))
    summary = re.search(r"=== Results: ([1-9][0-9]*) passed, 0 failed ===", child.stdout)
    ok = baseline.returncode == child.returncode == 0 and "BASELINE_DONE" in baseline.stdout
    ok = ok and not unexpected and summary is not None
    report = {"ok": ok, "checks": int(summary.group(1)) if summary else 0,
              "new_engine_error_allowlist": [], "unexpected": unexpected,
              "child_log": str(child_path), "baseline_log": str(baseline_path)}
    (evidence / "live-integration-receipt.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
