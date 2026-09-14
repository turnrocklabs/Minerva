#!/usr/bin/env bash
# Validate an already-extracted runtime using only its bundled interpreter.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <target-triple> <runtime-root>" >&2
  exit 64
fi

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$1"
ROOT="$(cd "$2" && pwd)"
case "$TARGET" in windows-x86_64) PYTHON="$ROOT/python.exe" ;; *) PYTHON="$ROOT/bin/python3" ;; esac
[ -x "$PYTHON" ] || { echo "target runtime is not executable on this host" >&2; exit 65; }

export MINERVA_VOICE_BUNDLE_ROOT="$ROOT"
export MINERVA_VOICE_TARGET="$TARGET"
export PYTHONNOUSERSITE=1

run_checked() {
  local test_file="$1"
  local output
  output="$(mktemp)"
  if ! "$PYTHON" -B -I "$test_file" >"$output" 2>&1; then
    cat "$output"
    rm -f "$output"
    return 1
  fi
  cat "$output"
  if grep -Eiq 'Traceback \(most recent call last\)|Task exception was never retrieved|connection handler failed' "$output"; then
    echo "unexpected asynchronous runtime error in $(basename "$test_file")" >&2
    rm -f "$output"
    return 1
  fi
  rm -f "$output"
}

run_checked "$PLUGIN_DIR/tests/test_worker_contract.py"
run_checked "$PLUGIN_DIR/tests/test_bundle_artifact.py"
