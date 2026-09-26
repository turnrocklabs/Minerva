#!/usr/bin/env bash
# Run Minerva's functional regression test suite (RCA 019e46b5).
#
# Default — hermetic substrate and provider contracts: fixture-plugin tests on the
# real MCPServerConnection that need only python3 + Godot. Safe and fast enough
# to run on every CI build.
#
#   scripts/run-functional-tests.sh           # hermetic tier (F1-F6)
#   scripts/run-functional-tests.sh --turnrock  # provider, bridge and UTF-8 contracts
#   scripts/run-functional-tests.sh --all     # + per-plugin tier
#   scripts/run-functional-tests.sh --pcb-guard  # PCB-migration regression guard only
#   scripts/run-functional-tests.sh --test test/path.gd  # one registered test
#
# The per-plugin tier (CAD / presentation / scansort) is heavy and/or networked
# — it needs built plugin binaries, build123d, and a reachable model-chat
# service — so it is NOT part of every hermetic CI run. Those tests SKIP
# cleanly (exit 0) when their environment is unavailable.
#
# The --pcb-guard tier is a standalone regression guard for the PCB-migration
# work: PCB/CAD plugin smoke tests plus the PluginScenePanelHost/Broker unit
# suites that back host_owned panel plumbing (annotations, save/load hooks,
# IPC broker). Run in isolation (not folded into --all) so migration rounds
# can gate on it directly.
#
# Exit code: 0 if every test that RAN passed (a SKIP counts as a pass); 1 if
# any test failed. Relies on the SceneTree tests calling quit(1) on failure.
#
#   scripts/run-functional-tests.sh --quarantined  # quarantined-flaky tier only
#   scripts/run-functional-tests.sh --platform-gate  # Windows/macOS release gate
#
# The --platform-gate tier is the marketplace install path (archives, locks,
# downloads, queue, browse) plus native SubProcess launching, run on each
# release platform. It is strict: a SKIP or FAIL line, or no summary line
# reporting at least one pass and no failures, fails the test even when it
# exits 0. MINERVA_TEST_LOG_DIR, when set, keeps each test's log there.
#
# The --quarantined tier holds tests that are known-flaky (intermittent native
# crash or timing race, unrelated to the diff under test) and have been pulled
# out of HERMETIC_TESTS so their red cannot attribute to an unrelated PR. They
# still run in CI, in their own step, so a real regression stays visible —
# see the "quarantined-flaky" step in .github/workflows/build.yml.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

# Keep the hermetic tier out of the developer/runner profile. All tests in one
# invocation share this isolated profile.
source "$REPO_ROOT/scripts/lib/test-profile.sh"
MINERVA_FUNCTIONAL_PROFILE_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$MINERVA_FUNCTIONAL_PROFILE_ROOT"' EXIT
seed_test_profile "$MINERVA_FUNCTIONAL_PROFILE_ROOT" || exit 1

TURNROCK_TESTS=(
	test/test_core_model_catalog.gd
	test/test_model_catalog.gd
	test/test_plugin_chat_providers.gd
	test/test_generation_options.gd
	test/test_core_request_lifecycle.gd
	test/test_core_binary_voice_routing.gd
	test/test_voice_contracts.gd
	test/test_bundled_voice_detector_adapter.gd
	test/test_voice_deactivation_prompt.gd
	test/test_voice_gateway_lifecycle.gd
	test/test_plugin_bulk_snapshot.gd
	test/test_plugin_control_reply_limit.gd
	test/test_chatpane_active_model.gd
	test/test_host_capability_core_session.gd
	test/test_utf8_line_bytes.cpp
	test/test_plugin_bridge_limits.js
)
HERMETIC_TESTS=(
	"${TURNROCK_TESTS[@]}"
	test/test_skill_presets.gd
	test/test_plugin_skill_seeding.gd
	test/test_mcp_stdio_concurrency.gd
	test/test_mcp_stdio_request_budget.gd
	test/test_mcp_stdio_profiles.gd
	test/test_mcp_http_transport.gd
	test/test_mcp_catalog_watch.gd
	test/test_mcp_public_subscriptions.gd
	test/test_mcp_definition_preservation.gd
	test/test_mcp_catalog_ownership.gd
	test/test_panel_executed_tools.gd
	test/test_mcp_plugin_result_boundaries.gd
	test/test_mcp_diagnostics.gd
	test/test_preferences_verbose_logging.gd
	test/test_bounded_process.gd
	test/test_mcp_loop_tracker.gd
	test/test_mcp_manager_lifecycle.gd
	test/test_self_scene_resource_lifecycle.gd
	test/test_markdownlabel_tables.gd
	test/test_mcp_schema_coercion.gd
	test/test_mcp_cad_tools.gd
	test/test_plugin_inspect_lean.gd
	test/test_buffer_sync_undo_caret.gd
	test/test_doc_version_guard.gd
	test/test_document_identity.gd
	test/test_host_capability_terminal.gd
	# test_host_capability_terminal_io.gd: quarantined, bug 019fbd21a8717702931647025aae6be7
	# (intermittent CI-only SIGABRT/exit 134, not reproduced in 40 local runs
	# incl. 4x parallel load; 2 CI occurrences, both rerun-green, neither on a
	# diff touching terminal code). Runs standalone via --quarantined below.
	test/test_media_artifact_kind.gd
	test/test_os_open_policy.gd
	test/test_chat_groups.gd
	test/test_chat_outgoing_queue.gd
	test/test_note_entry_log.gd
	test/test_terminal_notify.gd
	test/test_trigger_harness_delivery.gd
	test/test_docket_wakeups.gd
	test/test_session_handover.gd
	test/test_terminal_session.gd
	test/test_agent_container_foreground.gd
	test/test_terminal_selection_copy.gd
	test/test_terminal_input_routing.gd
	test/test_background_terminals.gd
	test/test_worker_parent_chat.gd
	test/test_core_action_catalog.gd
	test/test_chat_groups_integration.gd
	test/test_required_plugins.gd
	test/test_plugin_manager_hot_reload.gd
	test/test_marketplace_install_from_url.gd
	test/test_plugin_downloader.gd
	test/test_marketplace_install_transaction.gd
	test/test_plugin_install_queue.gd
	test/test_marketplace_browse.gd
	test/test_ui_scale_sync.gd
)
QUARANTINED_TESTS=(
	# bug 019fbd21a8717702931647025aae6be7 — see comment above.
	test/test_host_capability_terminal_io.gd
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
	test/test_passthrough_e2e.gd
)
PLATFORM_GATE_TESTS=(
	test/test_marketplace_install_transaction.gd
	test/test_plugin_install_queue.gd
	test/test_marketplace_browse.gd
	test/test_marketplace_install_from_url.gd
	test/test_plugin_downloader.gd
	test/test_subprocess_bounded_io.gd
	test/test_subprocess_env.gd
)
PCB_GUARD_TESTS=(
	test/test_cad_plugin_smoke.gd
	test/test_plugin_scene_panel_broker.gd
	test/test_plugin_panel_authority.gd
	test/test_plugin_scene_panel_broker_host_fs.gd
	test/test_plugin_scene_panel_broker_progress.gd
	test/test_plugin_scene_panel_keying.gd
	test/test_plugin_scene_panel_host.gd
	test/test_plugin_scene_panel_host_hooks.gd
)

tests=("${HERMETIC_TESTS[@]}")
strict=false
if [[ "${1:-}" == "--platform-gate" ]]; then
	tests=("${PLATFORM_GATE_TESTS[@]}")
	strict=true
elif [[ "${1:-}" == "--all" ]]; then
	# --all must still cover the quarantined set (019fbd21a8) — quarantine
	# only shields the CI functional gate, it must not shrink a full run.
	tests+=("${QUARANTINED_TESTS[@]}" "${PLUGIN_TESTS[@]}")
elif [[ "${1:-}" == "--turnrock" ]]; then
	tests=("${TURNROCK_TESTS[@]}")
elif [[ "${1:-}" == "--pcb-guard" ]]; then
	tests=("${PCB_GUARD_TESTS[@]}")
elif [[ "${1:-}" == "--quarantined" ]]; then
	tests=("${QUARANTINED_TESTS[@]}")
elif [[ "${1:-}" == "--test" ]]; then
	requested_test="${2:-}"
	if [[ -z "$requested_test" ]]; then
		echo "usage: $0 --test test/path.gd" >&2
		exit 2
	fi
	registered=false
	for registered_test in "${HERMETIC_TESTS[@]}" "${QUARANTINED_TESTS[@]}" \
			"${PLUGIN_TESTS[@]}" "${PCB_GUARD_TESTS[@]}" "${PLATFORM_GATE_TESTS[@]}"; do
		if [[ "$requested_test" == "$registered_test" ]]; then
			registered=true
			break
		fi
	done
	if [[ "$registered" != true ]]; then
		echo "unregistered functional test: $requested_test" >&2
		exit 2
	fi
	tests=("$requested_test")
elif [[ -n "${1:-}" ]]; then
	echo "unknown functional test option: $1" >&2
	exit 2
fi

# Tests run headless unless the caller supplies a display: dev-test.sh
# --display sets MINERVA_TEST_DISPLAY under Xvfb for real windows and popups.
GODOT_DISPLAY_MODE=(--headless)
[[ -n "${MINERVA_TEST_DISPLAY:-}" ]] && GODOT_DISPLAY_MODE=()

pass=0
fail=0
failed_names=()

for t in "${tests[@]}"; do
	echo ""
	echo "========================================================"
	echo "RUN: $t"
	echo "========================================================"
	if [[ "$t" == *.cpp ]]; then
		native_test=$(mktemp)
		"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror "$REPO_ROOT/src/$t" -o "$native_test" && "$native_test"
		rc=$?
		rm -f "$native_test"
	elif [[ "$t" == *.js ]]; then
		node "$REPO_ROOT/src/$t"
		rc=$?
	else
		log_file=$(mktemp)
		{ "$GODOT" --headless --path "$REPO_ROOT/src" --script "$t" --check-only &&
			"$GODOT" "${GODOT_DISPLAY_MODE[@]}" --path "$REPO_ROOT/src" --script "$t"; } 2>&1 | tee "$log_file"
		rc=${PIPESTATUS[0]}
		if grep -q 'SCRIPT ERROR:' "$log_file"; then rc=1; fi
		if $strict; then
			# Windows output may end lines in CR.
			plain=$(tr -d '\r' < "$log_file")
			if grep -qE '^(SKIP|FAIL)' <<<"$plain"; then rc=1; fi
			grep -qE '^=== (PASS|Results: [1-9][0-9]* passed, 0 failed|[1-9][0-9]* passed, 0 failed) ===$' <<<"$plain" || rc=1
			# A bare PASS verdict counts only with a check behind it.
			if grep -qx '=== PASS ===' <<<"$plain" && ! grep -q '^PASS:' <<<"$plain"; then rc=1; fi
		fi
		if [[ -n "${MINERVA_TEST_LOG_DIR:-}" ]]; then
			mkdir -p "$MINERVA_TEST_LOG_DIR" && cp "$log_file" "$MINERVA_TEST_LOG_DIR/$(basename "$t" .gd).log"
		fi
		rm -f "$log_file"
	fi
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
