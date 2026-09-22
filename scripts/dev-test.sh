#!/usr/bin/env bash
# Run focused dev tests in this working clone: how an agent container tests
# its own changes. scripts/container-test.sh stays the isolated, trusted gate.
#
#   scripts/dev-test.sh [--display] TEST...
#
# TEST is a path registered in scripts/run-functional-tests.sh (test/x.gd,
# .cpp or .js). Each step stops the run loudly when it fails:
#   1. container-build/dev-natives.py stages native binaries for this tree
#      (cached when inputs are unedited, else built locally);
#   2. two import passes, as CI and container-test do. They run every time
#      because Godot imports incrementally and uncommitted edits count; the
#      final pass must also log no SCRIPT ERROR;
#   3. run-functional-tests.sh --test per TEST, which also fails on any
#      SCRIPT ERROR in the output.
# --display gives Godot a real window under Xvfb, for GUI input and popup tests.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

display=false
if [[ "${1:-}" == --display ]]; then display=true; shift; fi
if (( $# == 0 )); then
	echo "usage: $0 [--display] test/path.gd..." >&2
	exit 2
fi

python3 -B "$REPO_ROOT/scripts/container-build/dev-natives.py" || exit 3

logs="$(mktemp -d)"
for pass in 1 2; do
	timeout "${MINERVA_IMPORT_TIMEOUT:-600}" "$GODOT" --headless --import --path "$REPO_ROOT/src" \
		> "$logs/import-$pass.log" 2>&1
	rc=$?
	if (( rc != 0 )); then
		echo "import pass $pass failed (exit $rc); log: $logs/import-$pass.log" >&2
		exit 4
	fi
done
# Godot can exit 0 from an import whose scripts failed to compile (a missing
# native class, say); the final pass must be clean or nothing after it counts.
if grep -q 'SCRIPT ERROR:' "$logs/import-2.log"; then
	grep -A2 'SCRIPT ERROR:' "$logs/import-2.log" | head -20 >&2
	echo "import pass 2 logged SCRIPT ERRORs; log: $logs/import-2.log" >&2
	exit 4
fi

rc=0
for t in "$@"; do
	if $display; then
		MINERVA_TEST_DISPLAY=1 xvfb-run -a -s "-screen 0 1920x1080x24" \
			"$REPO_ROOT/scripts/run-functional-tests.sh" --test "$t" || rc=1
	else
		"$REPO_ROOT/scripts/run-functional-tests.sh" --test "$t" || rc=1
	fi
done
exit "$rc"
