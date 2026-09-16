#!/usr/bin/env python3
"""Apply missing WRY patches without resetting a contributor's worktree."""
from pathlib import Path
import subprocess


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    vendor = root / "vendor/godot_wry"
    for patch in sorted((root / "patches").glob("godot_wry-*.patch")):
        command = ["git", "-C", str(vendor), "apply"]
        already_applied = subprocess.run(command + ["--reverse", "--check", str(patch)],
                                         capture_output=True).returncode == 0
        if already_applied:
            print(f"Already applied: {patch.name}")
            continue
        checked = subprocess.run(command + ["--check", str(patch)], capture_output=True, text=True)
        if checked.returncode:
            raise SystemExit(f"Cannot apply {patch.name}; local WRY edits were preserved.\n"
                             f"Resolve the patch conflict and rerun.\n{checked.stderr}")
        subprocess.run(command + [str(patch)], check=True)
        print(f"Applied: {patch.name}")


if __name__ == "__main__":
    main()
