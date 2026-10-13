#!/usr/bin/env python3
"""M1c entry point for the canonical shared writer inventory."""
from __future__ import annotations

import runpy
import sys
from pathlib import Path

if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    sys.argv[1:1] = ["--repo", str(root), "--card", "scripts/m1c-writer-card.json"]
    runpy.run_path(str(root / "scripts/check-writer.py"), run_name="__main__")
