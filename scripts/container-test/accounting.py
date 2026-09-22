#!/usr/bin/env python3
"""Strict verdicts for a container test run.

run-functional-tests.sh counts a suite green on exit 0, which a SKIP or a
suite that asserted nothing also produces. This reads each suite's log and
exit code and only calls it "pass" when it exited 0, reported at least one
passed check, no failed check, no SKIP and no SCRIPT ERROR.

    accounting.py <logs_dir> <tests_file> <results.json>

<tests_file> lists one suite per line; <logs_dir>/<slug>.log and .rc hold its
output and exit code (slug: see slug()). Exit status: 0 when every suite
passed, 1 otherwise, 2 on bad input.
"""
import json
import re
import sys
from pathlib import Path

# Suites print their totals as "<N> passed, <M> failed" in several wrappings
# ("=== Results: ...", "Core model catalog: ..."); the last one wins.
# run-functional-tests.sh closes with its own "Functional suite: <N> passed"
# count of suites, not checks, so that line is excluded.
SUMMARY = re.compile(r"^(?!Functional suite:).*?(\d+) passed, (\d+) failed", re.MULTILINE)
PASS_LINE = re.compile(r"^\s*PASS\b", re.MULTILINE)
FAIL_LINE = re.compile(r"^\s*FAIL\b", re.MULTILINE)
SKIP_LINE = re.compile(r"^\s*SKIP\b.*$", re.MULTILINE)


def slug(test: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", test)


def judge(log: str, rc: int | None) -> dict:
    summaries = SUMMARY.findall(log)
    if summaries:
        passed, failed = (int(n) for n in summaries[-1])
        source = "summary"
    else:
        passed, failed = len(PASS_LINE.findall(log)), len(FAIL_LINE.findall(log))
        source = "pass_lines"
    skips = [line.strip() for line in SKIP_LINE.findall(log)]
    script_errors = log.count("SCRIPT ERROR:")

    if rc is None:
        verdict = "not_run"
    elif rc != 0 or failed > 0 or script_errors:
        verdict = "fail"
    elif skips:
        verdict = "skipped" if passed == 0 else "partial_skip"
    elif passed == 0:
        verdict = "no_assertions"
    else:
        verdict = "pass"
    return {"verdict": verdict, "exit_code": rc, "passed": passed, "failed": failed,
            "count_source": source, "skips": skips, "script_errors": script_errors}


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    logs_dir, tests_file, results_path = Path(argv[1]), Path(argv[2]), Path(argv[3])
    tests = [t.strip() for t in tests_file.read_text().splitlines() if t.strip()]
    if not tests:
        print("accounting: no suites were requested", file=sys.stderr)
        return 2

    suites = []
    for test in tests:
        log_path, rc_path = logs_dir / f"{slug(test)}.log", logs_dir / f"{slug(test)}.rc"
        log = log_path.read_text(errors="replace") if log_path.exists() else ""
        rc = int(rc_path.read_text().strip()) if rc_path.exists() else None
        suites.append({"test": test, "log": log_path.name, **judge(log, rc)})

    green = all(s["verdict"] == "pass" for s in suites)
    results = {"green": green,
               "passed_checks": sum(s["passed"] for s in suites),
               "failed_checks": sum(s["failed"] for s in suites),
               "suites": suites}
    results_path.write_text(json.dumps(results, indent=2) + "\n")

    for s in suites:
        print(f"  {s['verdict']:<14} {s['passed']:>5} passed {s['failed']:>3} failed  {s['test']}")
    print(f"RESULT: {'GREEN' if green else 'NOT GREEN'} — "
          f"{sum(s['verdict'] == 'pass' for s in suites)}/{len(suites)} suites passed")
    return 0 if green else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
