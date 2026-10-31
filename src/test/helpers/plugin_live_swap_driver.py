"""Retain fault logs and reject diagnostics beyond the baseline and exact faults."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import TypedDict


class DriverReport(TypedDict):
    ok: bool
    checks: int
    expected_faults: dict[str, int]
    observed_faults: dict[str, int]
    unexpected: list[str]
    raw_log: str
    baseline_log: str


def profile_env(evidence: Path, seed: Path) -> dict[str, str]:
    profile = Path(tempfile.mkdtemp(prefix="live-swap-child-", dir=evidence))
    env = dict(os.environ)
    if sys.platform == "darwin":
        for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            env.pop(key, None)
        env["HOME"] = str(profile / "home")
        user = profile / "home/Library/Application Support/Godot/app_userdata/Minerva"
    elif os.name == "nt":
        env["APPDATA"] = str(profile / "appdata")
        user = profile / "appdata/Godot/app_userdata/Minerva"
    else:
        for key, leaf in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_CACHE_HOME", "cache")):
            env[key] = str(profile / leaf)
        user = profile / "data/godot/app_userdata/Minerva"
    user.mkdir(parents=True)
    for name in ("config_file.cfg", "mcp_config.json"):
        shutil.copyfile(seed / name, user / name)
    return env


def diagnostics(raw: str) -> list[tuple[str, str]]:
    """Keep engine headers and origin blocks; CEF's separate stderr stays raw."""
    lines = raw.splitlines()
    result: list[tuple[str, str]] = []
    for index, line in enumerate(lines):
        if line.startswith(("SCRIPT ERROR:", "ERROR:")) or (
                line.startswith("WARNING:") and "leak" in line.lower()):
            block: list[str] = []
            for following in lines[index + 1:]:
                if following and not following[0].isspace():
                    break
                block.append(following)
            result.append((line, "\n".join(block)))
    return result


def fault_kind(header: str, origin: str) -> str:
    if header == "SCRIPT ERROR: Parse Error: Expected parameter name." and re.search(
            r"GDScript::reload \([^\n]*/fixture/[AB]/Panel\.gd:[0-9]+\)", origin):
        return "compile"
    if re.fullmatch(r"ERROR: .*/fixture/[AB]/Panel\.tscn:1 - Parse Error: Expected '\['\.", header):
        return "scene_parse" if "resource_format_text.cpp" in origin else ""
    if re.fullmatch(r"ERROR: Failed loading resource: .*/fixture/[AB]/Panel\.tscn\.", header):
        return "scene_load" if "resource_loader.cpp" in origin else ""
    if re.fullmatch(r"ERROR: Error loading resource: '.*/fixture/[AB]/Panel\.tscn'\.", header):
        return "scene_bind" if "core_bind.cpp" in origin else ""
    if header.startswith('ERROR: Node not found: "Marker" (relative to ') and re.search(
            r"@implicit_ready \([^\n]*/fixture/[AB]/Panel\.gd:[0-9]+\)", origin):
        return "missing_node"
    return ""


def normalized(header: str, origin: str) -> str:
    # Compare pre-existing diagnostics by file/function and message, not line
    # numbers or anonymous node instance ids. Keep resource counts verbatim.
    first = origin.splitlines()[0].strip() if origin.splitlines() else ""
    return re.sub(r":[0-9]+\)", ")", re.sub(r"@[0-9]+", "@N", header + "|" + first))


def run_case(command: list[str], env: dict[str, str], log: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90, check=False)
    log.write_text(result.stdout + "\n" + result.stderr, encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--seed-user-dir", required=True)
    args = parser.parse_args()
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    command = [args.godot, "--headless", "--path", args.project, "--script",
               "res://test/test_plugin_live_swap.gd", "--", "--live-swap-child"]
    baseline_log = evidence / "live-swap-baseline.log"
    raw_log = evidence / "live-swap-child.log"
    try:
        baseline = run_case(command + ["--live-swap-baseline"],
                            profile_env(evidence, Path(args.seed_user_dir)), baseline_log)
        result = run_case(command, profile_env(evidence, Path(args.seed_user_dir)), raw_log)
    except subprocess.TimeoutExpired as error:
        (evidence / "timeout.txt").write_text(str(error), encoding="utf-8")
        partial = error.stdout or b""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        stderr = error.stderr or b""
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        partial += "\n" + stderr
        (evidence / "timeout-output.log").write_text(partial, encoding="utf-8")
        print(json.dumps({"ok": False, "error": "child timed out; see timeout.txt"}))
        return 1
    baseline_counts = Counter(normalized(*item) for item in diagnostics(baseline_log.read_text()))
    remaining = baseline_counts.copy()
    faults: Counter[str] = Counter()
    unexpected: list[str] = []
    raw = raw_log.read_text()
    for header, origin in diagnostics(raw):
        kind = fault_kind(header, origin)
        if kind:
            faults[kind] += 1
        else:
            key = normalized(header, origin)
            if remaining[key] > 0:
                remaining[key] -= 1
            else:
                unexpected.append(header.replace("SCRIPT ERROR:", "Child diagnostic:"))
    # missing_node: the first panel's self-check refuses, so the second panel is
    # never instantiated (one engine "Node not found" line per cycle).
    expected = {"compile": 3, "scene_parse": 3, "scene_load": 3, "scene_bind": 3, "missing_node": 3}
    summary = re.search(r"Plugin live swap: ([1-9][0-9]*) checks, 0 failures", raw)
    ok = baseline.returncode == 0 and "BASELINE_DONE" in baseline.stdout
    ok = ok and result.returncode == 0 and faults == Counter(expected) and not unexpected and summary is not None
    ok = ok and re.search(r"^FAIL:", raw, re.MULTILINE) is None
    report: DriverReport = {"ok": ok, "checks": int(summary.group(1)) if summary else 0,
                           "expected_faults": expected, "observed_faults": dict(faults),
                           "unexpected": unexpected, "raw_log": str(raw_log), "baseline_log": str(baseline_log)}
    (evidence / "live-swap-driver.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (evidence / "baseline-diagnostics.json").write_text(json.dumps(baseline_counts, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
