#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../src"
mkdir -p .godot
"$GODOT" --headless --import --path .
"$GODOT" --headless --import --path .
