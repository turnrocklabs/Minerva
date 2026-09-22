#!/usr/bin/env bash
# Entry point inside the test container; scripts/container-test.sh starts it.
#
# Mounts:  /snapshot  read-only `git archive` of the tested revision
#          /natives   read-only native overlay (tree/ + paths.txt)
#          /out       this run's results directory (the only host-writable mount)
# Args:    the suites to run — a path registered in run-functional-tests.sh
#          (test/x.gd, .cpp, .js) or "app-smoke".
#
# The working tree is copied to $WORK on the container's own layer, so the
# import cache and anything a test writes vanish with the container.
set -uo pipefail
export WORK=/work/tree

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=/out/logs
mkdir -p "$LOGS"
printf '%s\n' "$@" > /out/tests.txt

step() { echo "[container-test $(date -u +%H:%M:%S)] $*"; }

step "copying snapshot into $WORK"
cp -a /snapshot "$WORK" && chmod -R u+w "$WORK" || exit 1
# Native overlay: gitignored runtime binaries, symlinked so they stay read-only.
while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	rm -rf "${WORK:?}/$path"
	mkdir -p "$(dirname "$WORK/$path")"
	ln -s "/natives/tree/$path" "$WORK/$path"
done < /natives/paths.txt

# Two passes, as CI does: the first registers extensions and global classes,
# the second imports what those made loadable.
step "importing project"
cd "$WORK/src" || exit 1
for pass in 1 2; do
	timeout 600s godot --headless --import --path . > "$LOGS/import-$pass.log" 2>&1
	echo "import pass $pass exit $?" >> "$LOGS/import.txt"
done
if [[ -z "$(ls .godot/imported 2>/dev/null)" ]]; then
	step "import produced no resources — see logs/import-*.log"
	echo 1 > /out/exit_code
	exit 1
fi

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

for t in "$@"; do
	s="$(slug "$t")"
	step "RUN $t"
	if [[ "$t" == app-smoke ]]; then
		"$TOOLS/app-smoke.sh" > "$LOGS/$s.log" 2>&1
	else
		"$WORK/scripts/run-functional-tests.sh" --test "$t" > "$LOGS/$s.log" 2>&1
	fi
	echo $? > "$LOGS/$s.rc"
	step "  exit $(cat "$LOGS/$s.rc")"
done

python3 "$TOOLS/accounting.py" "$LOGS" /out/tests.txt /out/results.json
rc=$?
echo "$rc" > /out/exit_code
exit "$rc"
