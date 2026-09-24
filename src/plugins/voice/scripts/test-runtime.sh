#!/usr/bin/env bash
# Run source contract tests through the built target's interpreter.
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "usage: $0 <target-triple>" >&2; exit 64; fi
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$1"
ARCHIVE="$PLUGIN_DIR/dist/minerva-voice-$TARGET.tar.gz"
[ -f "$ARCHIVE" ] || { echo "missing built archive: $ARCHIVE" >&2; exit 65; }
# GNU tar reads an archive name with a drive colon (D:/...) as host:path;
# --force-local keeps it a local file. bsdtar has neither the reading nor
# the option.
tar_local() {
  if tar --version 2>/dev/null | grep -q "GNU tar"; then tar --force-local "$@"; else tar "$@"; fi
}
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
tar_local -xzf "$ARCHIVE" -C "$EXTRACT_DIR"
ROOT="$EXTRACT_DIR"
"$PLUGIN_DIR/scripts/test-runtime-root.sh" "$TARGET" "$ROOT"
