#!/usr/bin/env bash
# Run source contract tests through the built target's interpreter.
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "usage: $0 <target-triple>" >&2; exit 64; fi
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$1"
ARCHIVE="$PLUGIN_DIR/dist/minerva-voice-$TARGET.tar.gz"
[ -f "$ARCHIVE" ] || { echo "missing built archive: $ARCHIVE" >&2; exit 65; }
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"
ROOT="$EXTRACT_DIR"
"$PLUGIN_DIR/scripts/test-runtime-root.sh" "$TARGET" "$ROOT"
