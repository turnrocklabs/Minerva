"""Retain negative-case engine diagnostics without weakening the suite guard."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    # Keep this profile and raw logs for the enclosing disposable job's receipt.
    profile = Path(tempfile.mkdtemp(prefix="live-swap-child-", dir=evidence))
    child_env = dict(os.environ)
    for key, leaf in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_CACHE_HOME", "cache")):
        child_env[key] = str(profile / leaf)
    command = [args.godot, "--headless", "--path", args.project, "--script",
               "res://test/test_plugin_live_swap.gd", "--", "--live-swap-child"]
    try:
        result = subprocess.run(command, env=child_env, capture_output=True,
                                text=True, timeout=90, check=False)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "live-swap child timed out"}))
        return 1
    raw = result.stdout + "\n" + result.stderr
    (evidence / "live-swap-child.log").write_text(raw, encoding="utf-8")
    errors = [line for line in raw.splitlines() if "SCRIPT ERROR:" in line]
    # The single deliberately malformed Panel.gd is the only permitted script
    # error. Any additional parse/runtime/cascade error fails this driver.
    expected = ["SCRIPT ERROR: Parse Error: Expected parameter name."]
    summary = re.search(r"Plugin live swap: ([1-9][0-9]*) checks, 0 failures", raw)
    ok = result.returncode == 0 and errors == expected and summary is not None
    ok = ok and re.search(r"^FAIL:", raw, re.MULTILINE) is None
    report = {"ok": ok, "exit_code": result.returncode,
              "checks": int(summary.group(1)) if summary else 0,
              "expected_script_errors": len(expected), "observed_script_errors": len(errors),
              "raw_log": str(evidence / "live-swap-child.log")}
    (evidence / "live-swap-driver.json").write_text(json.dumps(report, indent=2) + "\n",
                                                       encoding="utf-8")
    print(json.dumps(report))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
