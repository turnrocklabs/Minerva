#!/usr/bin/env bash
# Copies the agent-session kit into DEST/agent-kit/ for a packaged Minerva:
# the launcher, image recipes and gateway policy (scripts/agent-container)
# and the builder-image recipe it imports (scripts/container-build). Only
# git-tracked files are copied, with their modes, so the kit holds no caches
# and its scripts keep their executable bits. Nothing compiled is shipped:
# images build on the user's machine from these recipes.
#
#   scripts/stage-agent-kit.sh DEST
#
# Minerva looks for DEST/agent-kit/agent-container/agent.py beside its
# executable (Linux) or under Contents/Resources (macOS); see
# AgentSessionStore.gd.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 DEST (an existing directory)" >&2
    exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kit="$1/agent-kit"

git -C "$root" ls-files -z -- scripts/agent-container scripts/container-build |
while IFS= read -r -d '' file; do
    rel="${file#scripts/}"
    mkdir -p "$kit/$(dirname "$rel")"
    cp -p "$root/$file" "$kit/$rel"
done

for required in agent-container/agent.py agent-container/docker-compose.yml \
        agent-container/Dockerfile agent-container/gateway/policy.json \
        container-build/build.py container-build/Dockerfile; do
    [ -f "$kit/$required" ] || { echo "stage-agent-kit: missing $required" >&2; exit 1; }
done
for executable in agent-container/minerva-session agent-container/agent-upgrade; do
    [ -x "$kit/$executable" ] || { echo "stage-agent-kit: $executable lost its executable bit" >&2; exit 1; }
done
echo "agent kit staged in $kit"
