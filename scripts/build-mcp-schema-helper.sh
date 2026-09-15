#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TARGET="${1:?usage: build-mcp-schema-helper.sh <linux-x86_64|windows-x86_64|macos-arm64|macos-amd64>}"
case "$TARGET" in
  linux-x86_64) PLATFORM=linux ;;
  windows-x86_64) PLATFORM=windows ;;
  macos-arm64|macos-amd64) PLATFORM=macos ;;
  *) echo "unsupported helper target: $TARGET" >&2; exit 2 ;;
esac

python3 "$ROOT/scripts/build-json-schema-helper.py" --platform "$PLATFORM"
NAME=minerva-json-schema-helper
[[ "$PLATFORM" != windows ]] || NAME+=.exe
SOURCE="$ROOT/src/native/vendor/jsoncons"
DIST="$ROOT/src/native/json_schema_helper/dist/$TARGET"
rm -rf "$DIST"
mkdir -p "$DIST"
install -m 0755 "$ROOT/src/bin/$NAME" "$DIST/$NAME"
cp "$ROOT/src/native/json_schema_helper/THIRD_PARTY.md" "$DIST/"
cp "$ROOT/src/native/json_schema_helper/dependency-lock.json" "$DIST/"
cp "$SOURCE/MINERVA_SOURCE_PROVENANCE" "$DIST/SOURCE_PROVENANCE"
cp "$SOURCE/LICENSE" "$DIST/jsoncons-LICENSE"

ARTIFACTS="$ROOT/src/native/json_schema_helper/artifacts"
mkdir -p "$ARTIFACTS"
ARCHIVE="$ARTIFACTS/minerva-json-schema-helper-$TARGET.tar.gz"
(cd "$ARTIFACTS" && tar -czf "$(basename "$ARCHIVE")" -C "$DIST" .)
python3 -c 'import hashlib,sys; sys.stdout.buffer.write(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest().encode("ascii") + b"\n")' \
  "$ARCHIVE" > "$ARCHIVE.sha256"
