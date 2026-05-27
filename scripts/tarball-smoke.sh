#!/usr/bin/env bash
# Tarball end-to-end smoke (Layer B for DCR3 marketplace install→start gate).
#
# Drives the *released* Minerva Linux tarball through the production marketplace
# flow:
#   1. Spawn Minerva under xvfb-run with --headless suppressed (CEF init needs
#      a real display surface even when no panel opens).
#   2. Wait for Minerva's MCP HTTP server to come up on :9315.
#   3. POST /mcp tools/call minerva_plugin_marketplace_install with the live
#      scansort tarball URL.
#   4. POST /mcp tools/call minerva_plugin_start id=scansort.
#   5. POST /mcp tools/call minerva_plugin_state id=scansort, assert RUNNING.
#   6. POST /mcp tools/call minerva_plugin_stop, then quit Minerva.
#
# Usage:
#   scripts/tarball-smoke.sh <minerva-extract-dir>
# Env overrides:
#   SCANSORT_TARBALL_URL  — defaults to the live imrans-lab/minerva-plugins release.
#   MCP_PORT              — defaults to 9315 (must match Minerva's default).
#   STARTUP_TIMEOUT_S     — seconds to wait for MCP HTTP to come up (default 60).
#
# Exit codes: 0 = smoke passed; non-zero = failure with a one-line reason printed.
set -uo pipefail

MINERVA_DIR="${1:?need extract dir}"
SCANSORT_TARBALL_URL="${SCANSORT_TARBALL_URL:-https://github.com/imrans-lab/minerva-plugins/releases/download/scansort-v0.0.0-pre/scansort-0.0.1-linux-x86_64.tar.gz}"
MCP_PORT="${MCP_PORT:-9315}"
MCP_URL="http://127.0.0.1:${MCP_PORT}/mcp"
STARTUP_TIMEOUT_S="${STARTUP_TIMEOUT_S:-60}"
LOG_DIR="$(mktemp -d /tmp/minerva-smoke.XXXXXX)"
MINERVA_LOG="${LOG_DIR}/minerva.log"
MINERVA_PID=""
XVFB_PID=""

cleanup() {
    local rc=$?
    echo "::group::Smoke cleanup"
    if [[ -n "${MINERVA_PID}" ]]; then
        kill -TERM "${MINERVA_PID}" 2>/dev/null || true
        sleep 1
        kill -KILL "${MINERVA_PID}" 2>/dev/null || true
    fi
    if [[ -n "${XVFB_PID}" ]]; then
        kill -TERM "${XVFB_PID}" 2>/dev/null || true
    fi
    echo "Minerva log (tail):"
    tail -80 "${MINERVA_LOG}" 2>/dev/null || true
    echo "::endgroup::"
    exit "$rc"
}
trap cleanup EXIT INT TERM

fail() {
    echo "::error::tarball-smoke: $*"
    exit 1
}

# JSON-RPC 2.0 / MCP helpers --------------------------------------------------
# Send a tools/call request; print response body. Globals:
#   _mcp_session_id — must be set after initialize.
_mcp_id=0
mcp_initialize() {
    _mcp_id=$((_mcp_id + 1))
    local resp
    resp=$(curl -sS --max-time 15 -i -X POST "${MCP_URL}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "MCP-Protocol-Version: 2025-06-18" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"${_mcp_id}\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"tarball-smoke\",\"version\":\"1.0\"}}}")
    # Extract MCP session id from response headers (case-insensitive).
    _mcp_session_id=$(echo "$resp" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {print $2; exit}')
    if [[ -z "${_mcp_session_id:-}" ]]; then
        echo "Initialize response (no session id):"
        echo "$resp"
        fail "MCP initialize did not return a session id"
    fi
    echo "MCP session id: ${_mcp_session_id}"
}

mcp_call() {
    local tool="$1"
    local args_json="$2"
    _mcp_id=$((_mcp_id + 1))
    local body
    body=$(printf '{"jsonrpc":"2.0","id":"%d","method":"tools/call","params":{"name":"%s","arguments":%s}}' \
        "$_mcp_id" "$tool" "$args_json")
    curl -sS --max-time 60 -X POST "${MCP_URL}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "MCP-Session-Id: ${_mcp_session_id}" \
        -H "MCP-Protocol-Version: 2025-06-18" \
        -d "$body"
}

# Boot Minerva ---------------------------------------------------------------
boot_minerva() {
    [[ -x "${MINERVA_DIR}/Minerva.x86_64" ]] || fail "Minerva.x86_64 not executable in ${MINERVA_DIR}"

    if ! command -v xvfb-run >/dev/null 2>&1; then
        fail "xvfb-run not installed — apt install xvfb"
    fi

    echo "Starting Minerva under xvfb-run (log: ${MINERVA_LOG})"
    # Use a tiny display surface; we never render anything.  --auto-servernum
    # picks a free :N to avoid clashes across parallel jobs.
    xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" \
        "${MINERVA_DIR}/Minerva.x86_64" \
        >"${MINERVA_LOG}" 2>&1 &
    MINERVA_PID=$!
    echo "Minerva PID: ${MINERVA_PID}"

    local deadline=$(( $(date +%s) + STARTUP_TIMEOUT_S ))
    while (( $(date +%s) < deadline )); do
        if ! kill -0 "${MINERVA_PID}" 2>/dev/null; then
            fail "Minerva exited during startup — see log"
        fi
        if curl -fsS --max-time 2 -o /dev/null \
                -X POST "${MCP_URL}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","id":"ping","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ping","version":"0"}}}'; then
            echo "MCP HTTP up at ${MCP_URL}"
            return 0
        fi
        sleep 1
    done
    fail "Minerva MCP HTTP did not come up within ${STARTUP_TIMEOUT_S}s"
}

# Result parsing --------------------------------------------------------------
# MCP tools/call returns:
#   {"jsonrpc":"2.0","id":"N","result":{"content":[{"type":"text","text":"<JSON>"}]}}
# We need the inner JSON.
mcp_unwrap() {
    python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("error"):
    print(json.dumps({"_jsonrpc_error": data["error"]}))
    sys.exit(0)
result = data.get("result", {})
content = result.get("content")
if isinstance(content, list) and content and isinstance(content[0], dict) and "text" in content[0]:
    try:
        inner = json.loads(content[0]["text"])
        print(json.dumps(inner))
    except Exception as e:
        print(json.dumps({"_unwrap_error": str(e), "raw": content[0]["text"]}))
else:
    # Fallback: print result as-is
    print(json.dumps(result))
'
}

# Test flow ------------------------------------------------------------------
boot_minerva
mcp_initialize

echo "::group::Step 1: marketplace install (scansort)"
raw=$(mcp_call "minerva_plugin_marketplace_install" "{\"url\":\"${SCANSORT_TARBALL_URL}\"}")
echo "raw: $raw"
result=$(echo "$raw" | mcp_unwrap)
echo "unwrapped: $result"
ok=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))")
if [[ "$ok" != "True" ]]; then
    fail "marketplace install failed: $result"
fi
echo "::endgroup::"

echo "::group::Step 2: start scansort"
raw=$(mcp_call "minerva_plugin_start" '{"id":"scansort"}')
echo "raw: $raw"
result=$(echo "$raw" | mcp_unwrap)
echo "unwrapped: $result"
ok=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok', False))")
if [[ "$ok" != "True" ]]; then
    fail "start_plugin failed: $result"
fi
echo "::endgroup::"

echo "::group::Step 3: assert RUNNING"
# minerva_plugin_state returns the plugin-PUBLISHED state dict (empty until the
# plugin publishes anything); use minerva_plugin_list which exposes the
# lifecycle state from PluginManager.get_plugin_status (state_name +
# running flag, both authoritative).
raw=$(mcp_call "minerva_plugin_list" '{}')
echo "raw: $raw"
result=$(echo "$raw" | mcp_unwrap)
echo "unwrapped: $result"
state_name=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
plugins = d.get('plugins', d if isinstance(d, list) else [])
if isinstance(d, list):
    plugins = d
for p in plugins:
    if p.get('id') == 'scansort':
        print(p.get('state_name', '?'))
        sys.exit(0)
print('not_found')
")
if [[ "$state_name" != "RUNNING" ]]; then
    fail "scansort not RUNNING — state_name=$state_name"
fi
echo "::endgroup::"

echo "::group::Step 4: clean stop"
raw=$(mcp_call "minerva_plugin_stop" '{"id":"scansort"}')
echo "stop result: $raw"
echo "::endgroup::"

echo "::notice::tarball-smoke PASS — released Minerva tarball installs + starts scansort end-to-end"
exit 0
