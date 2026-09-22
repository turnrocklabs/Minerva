#!/usr/bin/env bash
# Entry point inside the test container; scripts/container-test.sh starts it.
#
# Mounts:  /snapshot  read-only `git archive` of the tested revision
#          /natives   read-only native overlay (tree/ + paths.txt)
#          /out       this run's results directory (the only host-writable mount)
# Args:    the suites to run — a path registered in run-functional-tests.sh
#          (test/x.gd, .cpp, .js) or "app-smoke".
# Env:     MINERVA_CT_IMPORT_TIMEOUT  seconds per import pass (default 600)
#
# The working tree is copied to $WORK on the container's own layer, so the
# import cache and anything a test writes vanish with the container. Setup
# stages record "<stage> <exit code>" in logs/stages.txt; if one fails, no
# suite runs and accounting.py reports the job not green.
set -uo pipefail
export WORK=/work/tree

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=/out/logs
IMPORT_TIMEOUT="${MINERVA_CT_IMPORT_TIMEOUT:-600}"
mkdir -p "$LOGS"
printf '%s\n' "$@" > /out/tests.txt

step() { echo "[container-test $(date -u +%H:%M:%S)] $*"; }
# record STAGE RC: log a setup stage's exit code; returns RC.
record() { echo "$1 $2" >> "$LOGS/stages.txt"; step "  stage $1 exit $2"; return "$2"; }

setup() {
	step "copying snapshot into $WORK"
	cp -a /snapshot "$WORK" && chmod -R u+w "$WORK"
	record snapshot-copy $? || return 1
	# Native overlay: gitignored runtime binaries, symlinked so they stay read-only.
	local path
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		rm -rf "${WORK:?}/$path"
		mkdir -p "$(dirname "$WORK/$path")"
		ln -s "/natives/tree/$path" "$WORK/$path" || { record native-overlay 1; return 1; }
	done < /natives/paths.txt

	# Two passes, as CI does: the first registers extensions and global classes,
	# the second imports what those made loadable. Either failing (or timing
	# out, exit 124) fails the job.
	cd "$WORK/src" || { record import-cd 1; return 1; }
	local pass
	for pass in 1 2; do
		step "importing project (pass $pass, timeout ${IMPORT_TIMEOUT}s)"
		timeout "$IMPORT_TIMEOUT" godot --headless --import --path . > "$LOGS/import-$pass.log" 2>&1
		local rc=$?
		step "  .godot/imported holds $(ls .godot/imported 2>/dev/null | wc -l) files"
		record "import-pass-$pass" "$rc" || return 1
	done
	[[ -n "$(ls .godot/imported 2>/dev/null)" ]]
	record import-produced-resources $?
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

if setup; then
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
else
	step "setup failed — no suite runs; see logs/stages.txt and logs/import-*.log"
fi

python3 "$TOOLS/accounting.py" "$LOGS" /out/tests.txt /out/results.json
rc=$?
echo "$rc" > /out/exit_code
exit "$rc"
