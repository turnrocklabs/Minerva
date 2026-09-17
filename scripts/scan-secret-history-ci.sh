#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
scanner="${MINERVA_SECRET_SCAN_WRAPPER:-$ROOT/scripts/scan-secret-history.sh}"

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
  exec "$scanner" --all-history
fi
if [[ "${GITHUB_EVENT_NAME:-}" != "push" ]]; then
  echo "Secret scan does not recognize this CI event" >&2
  exit 2
fi

before="${GITHUB_EVENT_BEFORE:-}"
after="${GITHUB_EVENT_AFTER:-}"
sha_pattern='^[0-9a-fA-F]{40}$'
[[ "$before" =~ $sha_pattern && "$after" =~ $sha_pattern ]] \
  || { echo "Secret scan push endpoints are invalid" >&2; exit 2; }
git -C "$ROOT" cat-file -e "$after^{commit}" \
  || { echo "Secret scan cannot resolve the pushed commit" >&2; exit 2; }

if [[ "$before" == "0000000000000000000000000000000000000000" ]]; then
  exec "$scanner" --range "$after"
fi
git -C "$ROOT" cat-file -e "$before^{commit}" \
  || { echo "Secret scan cannot resolve the prior pushed commit" >&2; exit 2; }
exec "$scanner" --range "$before..$after"
