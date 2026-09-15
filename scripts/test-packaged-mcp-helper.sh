#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:?target required}"
ROOT="${2:?packaged helper root required}"
NAME=minerva-json-schema-helper
[[ "$TARGET" != windows-x86_64 ]] || NAME+=.exe
HELPER="$ROOT/$NAME"
[[ -f "$HELPER" ]] || { echo "missing packaged MCP helper: $HELPER" >&2; exit 1; }
[[ "$TARGET" == windows-x86_64 ]] || [[ -x "$HELPER" ]] || {
  echo "packaged MCP helper is not executable: $HELPER" >&2; exit 1;
}
description="$(file "$HELPER")"
case "$TARGET" in
  linux-x86_64) [[ "$description" == *"x86-64"* || "$description" == *"x86_64"* ]] ;;
  windows-x86_64) [[ "$description" == *"x86-64"* || "$description" == *"x86_64"* ]] ;;
  macos-arm64) [[ "$description" == *"arm64"* ]] ;;
  macos-amd64) [[ "$description" == *"x86_64"* ]] ;;
  *) echo "unsupported packaged helper target: $TARGET" >&2; exit 2 ;;
esac
MINERVA_JSON_SCHEMA_HELPER="$HELPER" \
  python3 "$(git rev-parse --show-toplevel)/tests/test_json_schema_helper.py"
