#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
COMMIT=2997f33bf6e4aab3db48d755fc877c8feab32c71
DEST="${MINERVA_DEPENDENCY_CACHE:-$ROOT/.dependency-cache}/mcp-$COMMIT"
mkdir -p "$DEST"
fetch() {
  local path="$1" expected="$2"
  local output="$DEST/$(basename "$path")"
  [[ -f "$output" ]] || curl --fail --location --output "$output" \
    "https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/$COMMIT/$path"
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "MCP artifact hash mismatch: $path" >&2; exit 1; }
}
fetch schema/2026-07-28/schema.ts 742750af0bb8c716e7030c4977c992b55d1adc4407e9e66997db5846baedc2cd
fetch schema/2026-07-28/schema.json ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203
fetch LICENSE 0382b0057770ca05e9c350a50aa3b1c1fea84da0bc81d723bf00b9aa841be58a
printf 'MCP schema source %s\n' "$COMMIT" > "$DEST/MINERVA_SOURCE_PROVENANCE"
