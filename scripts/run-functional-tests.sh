#!/usr/bin/env bash
# Run Minerva's functional regression test suite (RCA 019e46b5).
#
# Default — the hermetic substrate tier (F1-F6): fixture-plugin tests on the
# real MCPServerConnection that need only python3 + Godot. Safe and fast enough
# to run on every CI build.
#
#   scripts/run-functional-tests.sh           # hermetic tier (F1-F6)
#   scripts/run-functional-tests.sh --all     # + per-plugin tier
#
# The per-plugin tier (CAD / presentation / scansort) is heavy and/or networked
# — it needs built plugin binaries, build123d, and a reachable model-chat
# service — so it is NOT part of every hermetic CI run. Those tests SKIP
# cleanly (exit 0) when their environment is unavailable.
#
# Exit code: 0 if every test that RAN passed (a SKIP counts as a pass); 1 if
# any test failed. Relies on the SceneTree tests calling quit(1) on failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

HERMETIC_TESTS=(
	test/test_mcp_stdio_concurrency.gd
	test/test_mcp_stdio_request_budget.gd
)
PLUGIN_TESTS=(
	test/test_cad_evaluate_render.gd
	test/test_presentation_deck_render.gd
	test/test_scansort_filing_e2e.gd
	test/test_scansort_panel_loop_e2e.gd
	test/test_marketplace_install_start_scansort.gd
	test/test_marketplace_install_start_cad_evaluate.gd
	test/test_marketplace_install_start_codetools.gd
	test/test_codetools_panel_gate.gd
)

tests=("${HERMETIC_TESTS[@]}")
if [[ "${1:-}" == "--all" ]]; then
	tests+=("${PLUGIN_TESTS[@]}")
fi

pass=0
fail=0
failed_names=()

for t in "${tests[@]}"; do
	echo ""
	echo "========================================================"
	echo "RUN: $t"
	echo "========================================================"
	"$GODOT" --headless --path "$REPO_ROOT/src" --script "$t"
	rc=$?
	if (( rc == 0 )); then
		echo "  -> PASS ($t)"
		pass=$((pass + 1))
	else
		echo "  -> FAIL (exit $rc) ($t)"
		fail=$((fail + 1))
		failed_names+=("$t")
	fi
done

echo ""
echo "========================================================"
echo "Functional suite: $pass passed, $fail failed"
echo "========================================================"
if (( fail > 0 )); then
	printf 'FAILED: %s\n' "${failed_names[@]}"
	exit 1
fi
exit 0
