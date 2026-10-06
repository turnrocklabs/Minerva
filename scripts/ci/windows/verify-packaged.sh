#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
archive="${1:-packaged/Minerva-Windows.zip}"
extracted="${2:-extracted}"
mkdir -p "$extracted"
unzip -q "$archive" -d "$extracted"
scripts/test-packaged-mcp-helper.sh windows-x86_64 "$extracted/mcp-runtime/windows-x86_64"
python3 scripts/verify-packaged-mcp-app.py "$extracted/Minerva.exe"
python3 scripts/verify-packaged-mcp-app.py "$extracted/Minerva.exe" --bridge
