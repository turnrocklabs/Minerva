#!/usr/bin/env python3
"""Print the digest of source inputs that make a Voice runtime current."""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys


def input_paths(plugin_dir: Path) -> list[Path]:
    paths = [
        plugin_dir / "scripts" / "build-runtime.sh",
        plugin_dir / "scripts" / "requirements-runtime.lock",
        plugin_dir / "scripts" / "runtime-bundle.lock",
        plugin_dir / "scripts" / "voice_runtime_inputs.py",
    ]
    paths.extend(sorted((plugin_dir / "worker" / "minerva_voice_worker").rglob("*.py")))
    return paths


def source_digest(plugin_dir: Path) -> str:
    plugin_dir = plugin_dir.resolve()
    digest = hashlib.sha256()
    for path in input_paths(plugin_dir):
        relative = path.relative_to(plugin_dir).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


if __name__ == "__main__":
    directory = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[1]
    print(source_digest(directory))
