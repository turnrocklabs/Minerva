#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VERSION=8.30.1
CACHE="${MINERVA_DEPENDENCY_CACHE:-$ROOT/.dependency-cache}/gitleaks-$VERSION"

case "${1:-}" in
  --all-history)
    [[ $# -eq 1 ]] || { echo "Usage: $0 --all-history | --range REVISION_RANGE" >&2; exit 2; }
    log_opts="--all"
    ;;
  --range)
    [[ $# -eq 2 && -n "$2" && "$2" != -* ]] \
      || { echo "Usage: $0 --all-history | --range REVISION_RANGE" >&2; exit 2; }
    git -C "$ROOT" rev-list "$2" >/dev/null \
      || { echo "Secret scan revision range is invalid" >&2; exit 2; }
    log_opts="$2"
    ;;
  *)
    echo "Usage: $0 --all-history | --range REVISION_RANGE" >&2
    exit 2
    ;;
esac

platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Linux-x86_64)
    asset="gitleaks_${VERSION}_linux_x64.tar.gz"
    expected="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="gitleaks_${VERSION}_linux_arm64.tar.gz"
    expected="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
    ;;
  Darwin-x86_64)
    asset="gitleaks_${VERSION}_darwin_x64.tar.gz"
    expected="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
    ;;
  Darwin-arm64)
    asset="gitleaks_${VERSION}_darwin_arm64.tar.gz"
    expected="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
    ;;
  *)
    echo "Secret scan is unsupported on $platform" >&2
    exit 2
    ;;
esac

scanner="${GITLEAKS_BIN:-$CACHE/gitleaks}"
if [[ -z "${GITLEAKS_BIN:-}" && ! -x "$scanner" ]]; then
  mkdir -p "$CACHE"
  archive="$CACHE/$asset"
  curl --fail --location --output "$archive.tmp" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$VERSION/$asset"
  actual="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$archive.tmp")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$archive.tmp"
    echo "Secret scanner archive checksum mismatch" >&2
    exit 2
  fi
  mv "$archive.tmp" "$archive"
  extract="$CACHE/extract.$$"
  mkdir "$extract"
  tar -xzf "$archive" -C "$extract" gitleaks
  install -m 0755 "$extract/gitleaks" "$scanner.tmp"
  mv "$scanner.tmp" "$scanner"
  rm -rf "$extract"
fi

if [[ ! -x "$scanner" ]]; then
  echo "Secret scanner is missing or not executable" >&2
  exit 2
fi

report="$(mktemp "${TMPDIR:-/tmp}/minerva-gitleaks.XXXXXX")"
output="$(mktemp "${TMPDIR:-/tmp}/minerva-gitleaks.XXXXXX.log")"
trap 'rm -f "$report" "$output"' EXIT
set +e
"$scanner" git "$ROOT" --config "$ROOT/.gitleaks.toml" --log-opts="$log_opts" \
  --redact=100 --no-banner --exit-code=10 --report-format=json \
  --report-path="$report" >"$output" 2>&1
status=$?
set -e
case "$status" in
  0)
    echo "Secret history scan passed"
    ;;
  10)
    python3 - "$report" <<'PY'
import json
import re
import sys

try:
    findings = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    findings = []
if not isinstance(findings, list):
    findings = []

def safe(value, limit=200):
    return "".join(ch if ch.isprintable() and ch not in "\r\n" else "?"
                   for ch in str(value))[:limit]

print("Secret history scan found prohibited credentials:", file=sys.stderr)
for finding in findings[:50]:
    if not isinstance(finding, dict):
        continue
    commit = safe(finding.get("Commit", ""), 40)
    if not re.fullmatch(r"[0-9a-fA-F]{0,40}", commit):
        commit = ""
    line = finding.get("StartLine", 0)
    line = line if isinstance(line, int) and line >= 0 else 0
    print("- rule=%s file=%s line=%d commit=%s" % (
        safe(finding.get("RuleID", "unknown"), 100),
        safe(finding.get("File", "unknown")), line, commit), file=sys.stderr)
if len(findings) > 50:
    print("- additional findings omitted: %d" % (len(findings) - 50), file=sys.stderr)
PY
    exit 1
    ;;
  *)
    echo "Secret history scanner failed (exit $status); scanner output was withheld" >&2
    exit 2
    ;;
esac
