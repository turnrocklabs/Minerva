#!/usr/bin/env bash
# CI scans a commit range, including credentials removed later in that range.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
base="${SECRET_SCAN_BASE:-}"
head="${SECRET_SCAN_HEAD:-HEAD}"
if [[ -n "${GITHUB_EVENT_PATH:-}" ]]; then
  endpoints="$(python3 - "$GITHUB_EVENT_PATH" <<'PY'
import json
import sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
pr = event.get("pull_request", {})
print(pr.get("base", {}).get("sha") or event.get("before") or "")
print(pr.get("head", {}).get("sha") or event.get("after") or "HEAD")
PY
  )"
  event_base="${endpoints%%$'\n'*}"
  event_head="${endpoints#*$'\n'}"
  base="${base:-$event_base}"
  head="${SECRET_SCAN_HEAD:-$event_head}"
fi
if [[ -z "$base" || "$base" == 0000000000000000000000000000000000000000 ]]; then
  if [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]; then
    base=HEAD^
  else
    base="$(git merge-base "origin/${SECRET_SCAN_TARGET:-development}" "$head")"
  fi
fi
git cat-file -e "$base^{commit}"
git cat-file -e "$head^{commit}"
range="$base..$head"
if [[ -x scripts/scan-secret-history.sh ]]; then
  exec scripts/scan-secret-history.sh --range "$range"
fi
exec gitleaks git . -c .gitleaks.toml --log-opts="$range" --redact=100 --no-banner
