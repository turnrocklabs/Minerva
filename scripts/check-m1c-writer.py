#!/usr/bin/env python3
"""Read-only, revision-pinned M1c writer inventory; runtime checks are isolated."""
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
    production_cap: int
    failure_disposition: str
    persisted_setting_owners: dict[str, str]
    exit_table: str


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    card: Card = json.loads(git(root, "show", f"{args.head}:scripts/m1c-writer-card.json"))
    head = git(root, "rev-parse", args.head).strip()
    rows = [row.split("\t") for row in git(root, "diff", "--name-status", "-M", card["base"], head).splitlines()]
    paths = [row[-1] for row in rows]
    outside = [path for path in paths if path not in card["allowed_paths"]]
    removed_tests = [row for row in rows if row[0][0] in "DR" and any("test" in path for path in row[1:])]
    production = 0
    evidence = 0
    for row in git(root, "diff", "--numstat", card["base"], head).splitlines():
        added, deleted, path = row.split("\t")
        lines = int(added) + int(deleted)
        if path.startswith("src/Scripts/") or path.startswith("src/Scenes/"):
            production += lines
        else:
            evidence += lines
    diff = git(root, "diff", "--unified=0", card["base"], head)
    candidates = [line[1:] for line in diff.splitlines() if line.startswith("+") and re.search(r"push_(error|warning)|_notify\.call|errors\.append", line)]
    table = git(root, "show", f"{head}:{card['exit_table']}")
    result = {"head": head, "base": card["base"], "touch_set": paths, "out_of_card_paths": outside,
              "deleted_or_renamed_tests": removed_tests, "logged_failure_candidates": candidates,
              "failure_disposition": card["failure_disposition"], "persisted_setting_owners": card["persisted_setting_owners"],
              "production_lines": production, "evidence_lines": evidence, "production_cap": card["production_cap"],
              "exit_path_table": table}
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(bool(outside or removed_tests or production > card["production_cap"]))


if __name__ == "__main__":
    raise SystemExit(main())
