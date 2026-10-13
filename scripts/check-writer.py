#!/usr/bin/env python3
"""Shared read-only writer inventory driven by a revision-pinned batch card."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import TypedDict


class Card(TypedDict):
    base: str
    allowed_paths: list[str]
    production_prefixes: list[str]
    production_cap: int
    failure_patterns: list[str]
    failure_disposition: str
    persisted_setting_owners: dict[str, str]
    exit_table: str
    exit_tests: dict[str, list[str]]


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--card", required=True)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    root = args.repo.resolve()
    card: Card = json.loads(git(root, "show", f"{args.head}:{args.card}"))
    head = git(root, "rev-parse", args.head).strip()
    rows = [row.split("\t") for row in git(root, "diff", "--name-status", "-M", card["base"], head).splitlines()]
    paths = [row[-1] for row in rows]
    outside = [path for path in paths if not any(path == allowed or (allowed.endswith("/**") and path.startswith(allowed[:-2])) for allowed in card["allowed_paths"])]
    removed = [row for row in rows if row[0][0] in "DR" and any("test" in path for path in row[1:])]
    production = 0
    evidence = 0
    for row in git(root, "diff", "--numstat", card["base"], head).splitlines():
        added, deleted, path = row.split("\t")
        lines = 0 if added == "-" else int(added) + int(deleted)
        if any(path.startswith(prefix) for prefix in card["production_prefixes"]):
            production += lines
        else:
            evidence += lines
    diff = git(root, "diff", "--unified=0", card["base"], head)
    failures = [line[1:] for line in diff.splitlines() if line.startswith("+") and any(re.search(pattern, line) for pattern in card["failure_patterns"])]
    removed_declarations = [line[1:] for line in diff.splitlines() if line.startswith("-") and re.search(r"(?:func|def|fn|void)\s+(?:_?test\w*|check\w*)\s*\(", line)]
    added_declarations = {line[1:] for line in diff.splitlines() if line.startswith("+")}
    removed_declarations = [line for line in removed_declarations if line not in added_declarations]
    table = git(root, "show", f"{head}:{card['exit_table']}")
    missing_cells: list[str] = []
    headings: list[str] = []
    for line in table.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if not headings:
            headings = cells
        elif cells and not cells[0].startswith("-"):
            for heading in headings[1:]:
                cell = cells[0] + "/" + heading
                if not card["exit_tests"].get(cell):
                    missing_cells.append(cell)
    result = {"head": head, "base": card["base"], "touch_set": paths, "out_of_card_paths": outside,
              "deleted_or_renamed_tests": removed, "removed_test_declarations": removed_declarations,
              "logged_failure_candidates": failures, "failure_disposition": card["failure_disposition"],
              "persisted_setting_owners": card["persisted_setting_owners"], "production_lines": production,
              "evidence_lines": evidence, "production_cap": card["production_cap"], "exit_path_table": table,
              "exit_tests": card["exit_tests"], "exit_cells_without_named_tests": missing_cells}
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(bool(outside or removed or removed_declarations or missing_cells or production > card["production_cap"]))


if __name__ == "__main__":
    raise SystemExit(main())
