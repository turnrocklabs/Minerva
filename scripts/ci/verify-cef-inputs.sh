#!/usr/bin/env bash
# Refuse stale engines; this successful producer is the build-time dependency.
set -euo pipefail
producer=38196002368
source_sha=6da588fd617c8e52a64a8fc444fa295c327426bf
git fetch --no-tags origin "$source_sha"
for path in vendor/godot_cef patches/godot_cef scripts/build-godot-cef.sh src/addons/godot_cef; do
  expected="$(git rev-parse "$source_sha:$path")"
  actual="$(git rev-parse "HEAD:$path")"
  [[ "$actual" == "$expected" ]] || {
    echo "::error::CEF input changed: $path. Dispatch godot-cef.yml and update the pinned producer before pushing."
    exit 1
  }
done
gh api "repos/$GITHUB_REPOSITORY/actions/runs/$producer" > "$RUNNER_TEMP/cef-producer.json"
python3 - "$RUNNER_TEMP/cef-producer.json" "$source_sha" "$GITHUB_REPOSITORY" <<'PY'
import json
import sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
assert run["head_sha"] == sys.argv[2], "CEF producer source mismatch"
assert run["conclusion"] == "success", "CEF producer did not pass"
assert run["repository"]["full_name"] == sys.argv[3], "CEF producer repository mismatch"
assert run["head_repository"]["full_name"] == sys.argv[3], "CEF producer came from another repository"
print("Pinned CEF source and successful producer verified")
PY
