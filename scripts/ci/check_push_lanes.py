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
    r"test[_-]packaged|verify-packaged|verify-pins|probe-python-runtime|build-python-runtime|"
    r"tests/test_[^\s]+\.py|--self-test|hermetic-fab-check|--check-usb|"
    r"\bsmoke\b|smoke[-_]|test_docket_watch|--test-class|"
    r"gh\s+release\s+download|go run[^\n]*\bacquire\b|regen_registry\.py[^\n]*--published",
    re.IGNORECASE,
)
DENIED_PATH = re.compile(
    r"(?:^|[\s\"'])(?:\.?\.?/)?(?:[\w.-]+/)+[^\s\"']*"
    r"(?:test|suite|smoke|probe|functional|verify[-_]packaged)[^\s\"']*"
    r"\.(?:sh|py|ps1|bat|cmd|js|mjs|rb)\b",
    re.IGNORECASE,
)


def dispatch_only(condition: str) -> bool:
    condition = condition.strip().removeprefix("${{").removesuffix("}}").strip()
    gates = (
        "github.event_name == 'workflow_dispatch'",
        "(github.event_name == 'workflow_dispatch' || github.ref_type == 'tag')",
    )
    if condition in gates:
        return True
    if not any(condition.startswith(gate + " && ") for gate in gates):
        return False
    depth = 0
    for index, char in enumerate(condition):
        depth += (char == "(") - (char == ")")
        if depth < 0 or (depth == 0 and condition[index:index + 2] == "||"):
            return False
    return depth == 0


def check_steps(steps: list[dict], label: str, seen: frozenset[Path]) -> list[str]:
    errors: list[str] = []
    for step in steps:
        if dispatch_only(str(step.get("if", ""))):
            continue
        command = "\n".join(
            line for line in str(step.get("run", "")).splitlines()
            if not line.lstrip().startswith("#")
        )
        # B12: filesystem-only host compatibility preflights are a filed follow-on.
        if "--preflight-only" in command:
            command = re.sub(r"[\w./-]*run-gd-tests\.sh", "", command)
        text = str(step.get("name", "")) + "\n" + command
        match = DENIED.search(text) or DENIED_PATH.search(command)
        if match:
            errors.append(f"{label}: push step contains {match.group(0)!r}")
        action = str(step.get("uses", ""))
        if action.startswith("./.github/actions/"):
            directory = Path(action)
            path = next((directory / name for name in ("action.yml", "action.yaml")
                         if (directory / name).is_file()), None)
            if path is None or path in seen:
                errors.append(f"{label}: missing or recursive local action {action}")
                continue
            data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            if data.get("runs", {}).get("using") == "composite":
                errors.extend(check_steps(data["runs"].get("steps", []), str(path), seen | {path}))
    return errors


def check_workflow(path: Path, seen: frozenset[Path], branch: bool = True) -> list[str]:
    if path in seen:
        return [f"{path}: recursive workflow call"]
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    if not isinstance(data, dict):
        return [f"{path}: workflow must be a mapping"]
    errors: list[str] = []
    for job_id, job in data.get("jobs", {}).items():
        label = f"{path.name}:{job_id}"
        if branch and dispatch_only(str(job.get("if", ""))):
            continue
        callee = job.get("uses")
        if callee:
            if not str(callee).startswith("./.github/workflows/"):
                errors.append(f"{label}: external workflow cannot prove its timeout/steps")
            else:
                errors.extend(check_workflow(Path(callee), seen | {path}, branch))
            continue
        timeout = str(job.get("timeout-minutes", ""))
        if not timeout.isdigit() or int(timeout) <= 0:
            errors.append(f"{label}: timeout-minutes must be a literal positive integer")
        if branch:
            errors.extend(check_steps(job.get("steps", []), label, frozenset()))
    return errors


def lane_budget(path: Path, seen: frozenset[Path]) -> int:
    if path in seen:
        return 11
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    jobs = data.get("jobs", {})
    active: set[str] = set()
    costs: dict[str, int] = {}

    def cost(job_id: str) -> int:
        if job_id in costs:
            return costs[job_id]
        if job_id in active or job_id not in jobs:
            return 11
        job = jobs[job_id]
        if dispatch_only(str(job.get("if", ""))):
            return 0
        active.add(job_id)
        callee = str(job.get("uses", ""))
        if callee.startswith("./.github/workflows/"):
            duration = lane_budget(Path(callee), seen | {path})
        else:
            timeout = str(job.get("timeout-minutes", ""))
            duration = int(timeout) if timeout.isdigit() else 11
        needs = job.get("needs", [])
        if isinstance(needs, str):
            needs = [needs]
        costs[job_id] = duration + max((cost(dependency) for dependency in needs), default=0)
        active.remove(job_id)
        return costs[job_id]

    return max((cost(job_id) for job_id in jobs), default=0)


def main() -> int:
    errors: list[str] = []
    checked = 0
    for path in sorted(Path(".github/workflows").glob("*.y*ml")):
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        events = data.get("on", {}) if isinstance(data, dict) else {}
        push = events.get("push") if isinstance(events, dict) else ("push" if "push" in events else None)
        if push is None:
            continue
        tag_only = isinstance(push, dict) and "tags" in push and "branches" not in push and "branches-ignore" not in push
        checked += 1
        errors.extend(check_workflow(path, frozenset(), branch=not tag_only))
        if not tag_only:
            budget = lane_budget(path, frozenset())
            if budget > 10:
                print(f"::warning::{path.name}: declared branch budget {budget} minutes exceeds the 10-minute optimization target")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Push-lane lint: {checked} workflows, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

