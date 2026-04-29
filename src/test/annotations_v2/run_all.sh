#!/usr/bin/env bash
# run_all.sh — Runner for annotations_v2 contract tests (Round 1: RED tests)
#
# IMPORTANT: Round 1 inversion convention
# ════════════════════════════════════════
# RED is success in Round 1. Every test file is expected to:
#   - Run to completion (no parse errors, no setup crashes)
#   - Report FAIL counts > 0 (tests fail because the API doesn't exist yet)
#
# Exit codes:
#   0 = All files ran and produced FAIL > 0 (expected RED)
#   1 = One or more files CRASHED (parse error / setup explosion) — fix needed
#
# Usage:
#   cd /path/to/Minerva/src
#   bash test/annotations_v2/run_all.sh
#
# Optional: set GODOT env var to the godot binary path
#   GODOT=/usr/local/bin/godot bash test/annotations_v2/run_all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Find godot binary
GODOT="${GODOT:-godot}"
if ! command -v "$GODOT" &>/dev/null; then
    # Common macOS install locations
    for candidate in \
        "/Applications/Godot.app/Contents/MacOS/Godot" \
        "/Applications/Godot_v4.4.app/Contents/MacOS/Godot" \
        "$HOME/Applications/Godot.app/Contents/MacOS/Godot"; do
        if [ -x "$candidate" ]; then
            GODOT="$candidate"
            break
        fi
    done
fi

if ! command -v "$GODOT" &>/dev/null && [ ! -x "$GODOT" ]; then
    echo "ERROR: godot binary not found. Set GODOT=/path/to/godot or install Godot 4.4."
    exit 1
fi

echo "=== annotations_v2 run_all ==="
echo "Godot: $GODOT"
echo "Source: $SRC_DIR"
echo ""

TEST_FILES=(
    "test/annotations_v2/test_annotation_v2_envelope.gd"
    "test/annotations_v2/test_annotation_anchor_registry.gd"
    "test/annotations_v2/test_core_anchors.gd"
    "test/annotations_v2/test_annotation_host_resolve.gd"
    "test/annotations_v2/test_broken_anchor_render.gd"
    "test/annotations_v2/test_broken_anchor_sidebar.gd"
    "test/annotations_v2/test_broken_anchor_mcp.gd"
    "test/annotations_v2/test_broken_anchor_chat.gd"
    "test/annotations_v2/test_annotation_resolve_cache.gd"
    "test/annotations_v2/test_annotation_resolve_cache_perf.gd"
    "test/annotations_v2/test_kind_anchor_compat.gd"
    "test/annotations_v2/test_annotation_chat_context_default.gd"
    "test/annotations_v2/test_annotation_chat_context_stale.gd"
    "test/annotations_v2/test_annotation_chat_context_custom.gd"
    "test/annotations_v2/test_mcp_annotations_query.gd"
    "test/annotations_v2/test_mcp_annotations_update_status.gd"
    "test/annotations_v2/test_mcp_annotations_apply_hook.gd"
    "test/annotations_v2/test_annotation_v1_migration.gd"
    "test/annotations_v2/test_annotation_v1_drop.gd"
    "test/annotations_v2/test_annotation_v1_refuse.gd"
    "test/annotations_v2/test_plugin_trust_render.gd"
    "test/annotations_v2/test_plugin_trust_resolver.gd"
    "test/annotations_v2/test_plugin_trust_apply_tool.gd"
    "test/annotations_v2/test_plugin_trust_rate_limit.gd"
    "test/annotations_v2/test_text_editor_annotation_smoke.gd"
)

total_pass=0
total_fail=0
crashed_files=()
results=()

for test_file in "${TEST_FILES[@]}"; do
    basename="$(basename "$test_file")"
    printf "Running %-60s ... " "$basename"

    # Run the test, capturing output and exit code
    output=""
    exit_code=0
    output=$("$GODOT" --headless --path "$SRC_DIR" --script "$test_file" 2>&1) || exit_code=$?

    # Extract pass/fail counts from the output
    pass_count=0
    fail_count=0
    if echo "$output" | grep -q "Results:"; then
        pass_count=$(echo "$output" | grep "Results:" | grep -o "[0-9]* passed" | grep -o "[0-9]*" | head -1 || echo "0")
        fail_count=$(echo "$output" | grep "Results:" | grep -o "[0-9]* failed" | grep -o "[0-9]*" | head -1 || echo "0")
    fi

    # Detect crashes: exit code != 0 or 1 is expected (1 = FAILs which is normal RED)
    # A crash is when the script exits without printing "Results:" (parse error etc.)
    if ! echo "$output" | grep -q "Results:" && [ "$exit_code" -ne 0 ]; then
        echo "CRASHED (exit=$exit_code)"
        crashed_files+=("$basename")
        results+=("$basename: CRASHED (no Results line)")
    else
        echo "${pass_count} passed, ${fail_count} failed"
        results+=("$basename: ${pass_count} passed, ${fail_count} failed")
        total_pass=$((total_pass + pass_count))
        total_fail=$((total_fail + fail_count))
    fi
done

echo ""
echo "=== annotations_v2 run_all SUMMARY ==="
for r in "${results[@]}"; do
    echo "  $r"
done

echo ""
echo "=== TOTAL: ${total_pass} passed, ${total_fail} failed ==="

if [ ${#crashed_files[@]} -gt 0 ]; then
    echo ""
    echo "CRASHED FILES (fix required):"
    for f in "${crashed_files[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "EXIT: FAILURE (crashes detected)"
    exit 1
fi

echo ""
if [ "$total_pass" -eq 0 ] && [ "$total_fail" -gt 0 ]; then
    echo "EXIT: SUCCESS (Round 1 RED as expected — 0 passed, ${total_fail} failed)"
    exit 0
elif [ "$total_fail" -eq 0 ]; then
    echo "EXIT: UNEXPECTED (all tests passed — are you running on a completed implementation?)"
    exit 0
else
    echo "EXIT: PARTIAL (some tests passing early — verify these are intentional)"
    exit 0
fi
