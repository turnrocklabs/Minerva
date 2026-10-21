#!/usr/bin/env python3
"""Fetch CI's explicit required-plugin repositories into one keyed snapshot."""
import argparse
import json
import re
import subprocess
from collections.abc import Sequence
from pathlib import Path
from typing import Any


def fetch_releases(repositories: Sequence[str]) -> dict[str, list[list[Any]]]:
    """GitHub release bodies are dynamic JSON; repository/page structure is fixed."""
    snapshot: dict[str, list[list[Any]]] = {}
    for repo in repositories:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError(f"Invalid repository: {repo}")
        command = ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"]
        fetched = subprocess.run(command, check=False, capture_output=True, text=True, encoding="utf-8")
        if fetched.returncode != 0:
            raise RuntimeError(f"{' '.join(command)} failed with exit code {fetched.returncode}: "
                               f"{fetched.stderr.strip()}")
        pages = json.loads(fetched.stdout)
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError(f"Release listing for {repo} is not an array of pages")
        snapshot[repo] = pages
    return snapshot


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    snapshot = fetch_releases(args.repo)
    args.output.write_text(json.dumps(snapshot, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
