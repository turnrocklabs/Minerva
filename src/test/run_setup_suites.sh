#!/usr/bin/env bash
# Run the full plugin-setup-pipeline functional test suite (DCR 019f69428fa0,
# docket C5, contract Docs/design/plugin-setup-pipeline.md §4 — the F1-F13
# fixture matrix). Five suites, all non-mocked functional-floor tests against
# real fixture executables and (where noted in each suite's own header) the
# real PluginManager install path.
#
#   src/test/run_setup_suites.sh
#
# No arguments needed. Works from the repo root or from src/. CI-ready: exits
# 0 iff every suite that ran passed; nonzero on the first suite failure (or
# any suite failure — every suite still runs; the exit code just reflects
# whether ANY failed).
#
# If src/.godot is missing (fresh checkout / fresh worktree), runs one
# headless editor import pass first — Godot's script/resource cache has to
# exist before `--script` runs can resolve class_name types like
# SetupPipeline/ToolchainRegistry/SetupSchema, and a missing cache is the
# single most common "works on my machine, not in CI" gap for this suite.
set -uo pipefail

# ---------------------------------------------------------------------------
# Locate src/ regardless of whether we were invoked from the repo root or
# from inside src/ itself.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../src/test
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                       # .../src

GODOT="${GODOT:-godot}"
IMPORT_TIMEOUT_S="${IMPORT_TIMEOUT_S:-240}"
SUITE_TIMEOUT_S="${SUITE_TIMEOUT_S:-120}"

SUITES=(
	test/test_plugin_setup_schema.gd
	test/test_plugin_setup_executors.gd
	test/test_toolchain_registry.gd
	test/test_plugin_setup_pipeline.gd
	test/test_setup_matrix.gd
	test/test_plugin_build_ui.gd
)

echo "========================================================"
echo "Plugin Setup Pipeline — full suite (F1-F13 matrix)"
echo "========================================================"

if [[ ! -d "$SRC_DIR/.godot" ]]; then
	echo ""
	echo "-- src/.godot missing: running one headless import pass first --"
	if ! (cd "$SRC_DIR" && timeout "$IMPORT_TIMEOUT_S" "$GODOT" --headless --editor --quit-after 3); then
		echo "FATAL: headless import pass failed — cannot proceed" >&2
		exit 1
	fi
fi

pass_total=0
fail_total=0
declare -a suite_names
declare -a suite_counts
declare -a suite_results
overall_rc=0

for suite in "${SUITES[@]}"; do
	echo ""
	echo "========================================================"
	echo "RUN: $suite"
	echo "========================================================"
	output="$( (cd "$SRC_DIR" && timeout "$SUITE_TIMEOUT_S" "$GODOT" --headless --path . --script "$suite") 2>&1)"
	rc=$?
	echo "$output"

	# Every suite in this matrix prints "=== Results: N passed, M failed ==="
	# as its last line before quit(); parse it for the per-suite summary line
	# below (fall back to "unknown" if a suite crashed before printing it —
	# rc will still be nonzero in that case).
	summary_line="$(printf '%s\n' "$output" | grep -E '^=== Results: ' | tail -1)"
	if [[ -n "$summary_line" ]]; then
		counts="$(printf '%s\n' "$summary_line" | sed -E 's/^=== Results: ([0-9]+) passed, ([0-9]+) failed ===$/\1 \2/')"
	else
		counts=""
	fi

	suite_names+=("$suite")
	if [[ $rc -eq 124 ]]; then
		suite_results+=("TIMEOUT")
		suite_counts+=("n/a")
		echo "  -> TIMEOUT (exceeded ${SUITE_TIMEOUT_S}s) ($suite)"
		fail_total=$((fail_total + 1))
		overall_rc=1
	elif [[ $rc -ne 0 ]]; then
		suite_results+=("FAIL")
		if [[ -n "$counts" ]]; then
			p="${counts% *}"
			f="${counts#* }"
			suite_counts+=("$p passed, $f failed")
			pass_total=$((pass_total + p))
			fail_total=$((fail_total + f))
		else
			suite_counts+=("crashed before printing results (exit $rc)")
			fail_total=$((fail_total + 1))
		fi
		echo "  -> FAIL (exit $rc) ($suite)"
		overall_rc=1
	else
		suite_results+=("PASS")
		if [[ -n "$counts" ]]; then
			p="${counts% *}"
			f="${counts#* }"
			suite_counts+=("$p passed, $f failed")
			pass_total=$((pass_total + p))
			fail_total=$((fail_total + f))
		else
			suite_counts+=("passed (no parsable count)")
		fi
		echo "  -> PASS ($suite)"
	fi
done

echo ""
echo "========================================================"
echo "Per-suite summary"
echo "========================================================"
for i in "${!suite_names[@]}"; do
	printf '  %-6s %-45s %s\n' "${suite_results[$i]}" "${suite_names[$i]}" "${suite_counts[$i]}"
done

echo ""
echo "========================================================"
if [[ $overall_rc -eq 0 ]]; then
	echo "PASS: setup-pipeline matrix — $pass_total checks passed, 0 failed, across ${#SUITES[@]} suites"
else
	echo "FAIL: setup-pipeline matrix — $pass_total passed, $fail_total failed, across ${#SUITES[@]} suites"
fi
echo "========================================================"

exit $overall_rc
