#!/usr/bin/env python3
"""Check branch-push jobs; YAML payloads are dynamic, and calls are followed locally."""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

DENIED = re.compile(
    r"\bgo test\b|\bcargo test\b|\bzig build test\b|\bpytest\b|-m unittest|"
    r"run[-_]functional[-_]tests|run_tests\.sh|run-panel-tests|run-contract-guards|"
    r"test[_-]packaged|verify-packaged|verify-pins|probe-python-runtime|"
    r"\bsmoke\b|smoke[-_]|test_docket_watch|--test-class|"
    r"gh\s+release\s+download|go run[^\n]*\bacquire\b|regen_registry\.py[^\n]*--published",
    re.IGNORECASE,
)


def dispatch_only(condition: str) -> bool:
    condition = condition.strip().removeprefix("${{").removesuffix("}}").strip()
    return condition.startswith("github.event_name == 'workflow_dispatch'") and "||" not in condition


def check_workflow(path: Path, seen: frozenset[Path]) -> list[str]:
    if path in seen:
        return [f"{path}: recursive workflow call"]
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    if not isinstance(data, dict):
        return [f"{path}: workflow must be a mapping"]
    errors: list[str] = []
    for job_id, job in data.get("jobs", {}).items():
        label = f"{path.name}:{job_id}"
        if dispatch_only(str(job.get("if", ""))):
            continue
        callee = job.get("uses")
        if callee:
            if not str(callee).startswith("./.github/workflows/"):
                errors.append(f"{label}: external workflow cannot prove its timeout/steps")
            else:
                errors.extend(check_workflow(Path(callee), seen | {path}))
            continue
        timeout = str(job.get("timeout-minutes", ""))
        if not timeout.isdigit() or not 0 < int(timeout) <= 10:
            errors.append(f"{label}: timeout-minutes must be a literal 1..10")
        for step in job.get("steps", []):
            if dispatch_only(str(step.get("if", ""))):
                continue
            command = "\n".join(
                line for line in str(step.get("run", "")).splitlines()
                if not line.lstrip().startswith("#")
            )
            text = str(step.get("name", "")) + "\n" + command
            match = DENIED.search(text)
            if match:
                errors.append(f"{label}: push step contains {match.group(0)!r}")
    return errors


def main() -> int:
    errors: list[str] = []
    checked = 0
    for path in sorted(Path(".github/workflows").glob("*.y*ml")):
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        events = data.get("on", {}) if isinstance(data, dict) else {}
        push = events.get("push") if isinstance(events, dict) else ("push" if "push" in events else None)
        if push is None:
            continue
        # The app's tag release lane retains its pre-tag suite; branch lanes are capped.
        if path.name == "release.yml" and isinstance(push, dict) and "tags" in push and "branches" not in push:
            continue
        checked += 1
        errors.extend(check_workflow(path, frozenset()))
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Push-lane lint: {checked} workflows, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

