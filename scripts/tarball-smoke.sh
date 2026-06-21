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
# CAD evaluate assertion added per DCR 019e6a4bcb0c W3. Defaults to the final
# cad-v0.1.1 release; override with CAD_TARBALL_URL for prerelease URLs (e.g.
# the per-branch prerelease published by minerva-plugins cad.yml on push).
# Empty string disables the cad-evaluate step.
CAD_TARBALL_URL="${CAD_TARBALL_URL:-https://github.com/imrans-lab/minerva-plugins/releases/download/cad-v0.1.1/cad-0.1.1-linux-x86_64.tar.gz}"
CAD_EVALUATE_TIMEOUT_S="${CAD_EVALUATE_TIMEOUT_S:-90}"
MCP_PORT="${MCP_PORT:-9315}"
MCP_URL="http://127.0.0.1:${MCP_PORT}/mcp"
STARTUP_TIMEOUT_S="${STARTUP_TIMEOUT_S:-60}"
LOG_DIR="$(mktemp -d /tmp/minerva-smoke.XXXXXX)"
MINERVA_LOG="${LOG_DIR}/minerva.log"
MINERVA_PID=""

cleanup() {
    local rc=$?
    echo "::group::Smoke cleanup"
    if [[ -n "${MINERVA_PID}" ]]; then
        kill -TERM "${MINERVA_PID}" 2>/dev/null || true
        sleep 1
        kill -KILL "${MINERVA_PID}" 2>/dev/null || true
    fi
    # Copy log to a stable path so the workflow's artifact-upload step finds it.
    if [[ -f "${MINERVA_LOG}" ]]; then
        cp "${MINERVA_LOG}" /tmp/minerva-smoke-final.log 2>/dev/null || true
        # Inline-dump always (so the GH UI rendered log shows it even when no
        # artifact is enabled).  Full content; smoke logs are short.
        echo "::group::Minerva log (full)"
        cat "${MINERVA_LOG}" 2>/dev/null || true
        echo "::endgroup::"
    fi
    echo "::endgroup::"
    exit "$rc"
}
trap cleanup EXIT INT TERM

fail() {
    echo "::error::tarball-smoke: $*"
    exit 1
}

# JSON-RPC 2.0 / MCP helpers --------------------------------------------------
# Minerva's MCP HTTP server is session-less — it advertises Mcp-Session-Id in
# CORS headers but doesn't emit one in responses, and accepts tools/call
# without one (verified locally 2026-05-26 via headless probe). So we just
# initialize once for handshake protocol-compliance, then call tools directly.
_mcp_id=0
mcp_initialize() {
    _mcp_id=$((_mcp_id + 1))
    local resp
    resp=$(curl -sS --max-time 15 -X POST "${MCP_URL}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "MCP-Protocol-Version: 2025-06-18" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"${_mcp_id}\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"tarball-smoke\",\"version\":\"1.0\"}}}")
    # Sanity-check the handshake returned a valid initialize result; abort
    # otherwise so we don't paper over a broken server with bogus tool calls.
    if ! echo "$resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('result', {})
ok = bool(r.get('serverInfo')) and bool(r.get('protocolVersion'))
sys.exit(0 if ok else 1)" 2>/dev/null; then
        echo "Initialize raw response: $resp"
        fail "MCP initialize handshake malformed"
    fi
    echo "MCP initialize ok ($(echo "$resp" | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(r['serverInfo']['name'], 'protocol', r['protocolVersion'])"))"
}

mcp_call() {
    local tool="$1"
    local args_json="$2"
    _mcp_id=$((_mcp_id + 1))
    local body
    body=$(printf '{"jsonrpc":"2.0","id":"%d","method":"tools/call","params":{"name":"%s","arguments":%s}}' \
        "$_mcp_id" "$tool" "$args_json")
    curl -sS --max-time 120 -X POST "${MCP_URL}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "MCP-Protocol-Version: 2025-06-18" \
        -d "$body"
}

# Boot Minerva ---------------------------------------------------------------
# Strategy (iter-4 — both --headless AND xvfb-run):
#   --headless tells Godot's DisplayServer not to create a window. That alone
#   would seem to suffice, but Minerva ships the godot-cef GDExtension which
#   spawns gdcef_helper CEF subprocesses at startup. Those CHILDREN require a
#   real X display to init ANGLE/EGL — without one they hang ~15s waiting on
#   handshakes that never complete, which blocks SingletonObject's _ready
#   chain *before* it reaches start_http_server(9315). (Confirmed by iter-3
#   minerva.log artifact: "ANGLE Display::initialize error 12289: Could not
#   open the default X display" → "Terminating after 15 seconds with no
#   connection" → log dies before MCP HTTP comes up.)
# xvfb-run supplies a virtual X server so CEF children's handshakes succeed.
# Iter-2 had xvfb but no --headless (window creation hung); iter-3 had
# --headless but no xvfb (CEF stalled). Iter-4 ships both.
boot_minerva() {
    [[ -x "${MINERVA_DIR}/Minerva.x86_64" ]] || fail "Minerva.x86_64 not executable in ${MINERVA_DIR}"

    if ! command -v xvfb-run >/dev/null 2>&1; then
        fail "xvfb-run not installed — apt install xvfb"
    fi

    echo "Starting Minerva under xvfb-run + --headless (log: ${MINERVA_LOG})"
    # stdbuf -oL -eL forces line-buffered stdout/stderr. Without it, Godot's
    # C runtime fully buffers when stdout isn't a terminal, which means
    # diagnostic prints don't reach the log file until process exit — making
    # CI failures unreadable. iter-2/3/4 logs were truncated at 771-3837
    # bytes for exactly this reason; locally where stdout is a tty we see
    # megabytes of output.
    xvfb-run --auto-servernum --server-args="-screen 0 1024x768x24" \
        stdbuf -oL -eL "${MINERVA_DIR}/Minerva.x86_64" --headless --verbose \
        >"${MINERVA_LOG}" 2>&1 &
    MINERVA_PID=$!
    echo "Minerva PID: ${MINERVA_PID}"

    local deadline=$(( $(date +%s) + STARTUP_TIMEOUT_S ))
    local last_log_size=0
    local last_tail_dump=0
    while (( $(date +%s) < deadline )); do
        if ! kill -0 "${MINERVA_PID}" 2>/dev/null; then
            echo "::error::Minerva exited during startup. Full log:"
            cat "${MINERVA_LOG}" 2>/dev/null || true
            fail "Minerva exited during startup — see full log above"
        fi
        if curl -fsS --max-time 2 -o /dev/null \
                -X POST "${MCP_URL}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","id":"ping","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ping","version":"0"}}}'; then
            echo "MCP HTTP up at ${MCP_URL}"
            return 0
        fi
        # Progress reporting: announce log size growth, and every 15s dump
        # the latest 30 lines of the log so a hung startup leaves a trail in
        # the GH UI rather than just one terminal failure at the end.
        local sz now
        sz=$(stat -c%s "${MINERVA_LOG}" 2>/dev/null || echo 0)
        now=$(date +%s)
        if (( sz != last_log_size )); then
            echo "  (waiting for :${MCP_PORT}; minerva.log size=${sz}B)"
            last_log_size=$sz
        fi
        if (( now - last_tail_dump >= 15 )); then
            echo "::group::Live minerva.log tail (last 30 lines @ +$(( now - (deadline - STARTUP_TIMEOUT_S) ))s)"
            tail -30 "${MINERVA_LOG}" 2>/dev/null || true
            echo "::endgroup::"
            last_tail_dump=$now
        fi
        sleep 1
    done
    echo "::error::Minerva MCP HTTP did not come up within ${STARTUP_TIMEOUT_S}s. Full log:"
    cat "${MINERVA_LOG}" 2>/dev/null || true
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
# auto_confirm_skills=true: this is a headless, programmatic caller — there is no
# user to dismiss the skill-seed confirmation dialog, and awaiting it would hang
# the install. (scansort has no skills today, but pass it for consistency.)
raw=$(mcp_call "minerva_plugin_marketplace_install" "{\"url\":\"${SCANSORT_TARBALL_URL}\",\"auto_confirm_skills\":true}")
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

# ----------------------------------------------------------------------------
# Step 5–8: CAD evaluate gate (DCR 019e6a4bcb0c W3)
# ----------------------------------------------------------------------------
# Reproduces the marketplace install→start→evaluate flow for the cad plugin.
# Asserts a non-error mcad_validate response — proving the embedded PBS python
# runtime works end-to-end in a production Minerva tarball context. Empty
# CAD_TARBALL_URL skips this section so older Minerva branches that didn't
# need it don't break.

if [[ -z "$CAD_TARBALL_URL" ]]; then
    echo "::notice::tarball-smoke PASS (cad step skipped — CAD_TARBALL_URL empty)"
    exit 0
fi

echo "::group::Step 5: marketplace install (cad)"
echo "cad tarball: $CAD_TARBALL_URL"
# cad DOES declare skills — without auto_confirm_skills the install succeeds then
# blocks on the interactive seed dialog (the bug this gate was catching).
raw=$(mcp_call "minerva_plugin_marketplace_install" "{\"url\":\"${CAD_TARBALL_URL}\",\"auto_confirm_skills\":true}")
echo "raw: $raw"
result=$(echo "$raw" | mcp_unwrap)
echo "unwrapped: $result"
ok=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))")
if [[ "$ok" != "True" ]]; then
    fail "cad marketplace install failed: $result"
fi
echo "::endgroup::"

echo "::group::Step 6: start cad"
raw=$(mcp_call "minerva_plugin_start" '{"id":"cad"}')
echo "raw: $raw"
result=$(echo "$raw" | mcp_unwrap)
echo "unwrapped: $result"
ok=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))")
if [[ "$ok" != "True" ]]; then
    fail "cad start_plugin failed: $result"
fi
echo "::endgroup::"

echo "::group::Step 7: mcad_validate (DCR 019e6a4bcb0c acceptance)"
# Invoke the plugin's mcad_validate tool via the Minerva MCP proxy. The
# expected success envelope is {ok: true, result: {ok: true, errors: []}}.
# Cold-start budget includes bundle extract + OCCT init.
raw=$(curl -sS --max-time "$CAD_EVALUATE_TIMEOUT_S" -X POST "${MCP_URL}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"cad-eval\",\"method\":\"tools/call\",\"params\":{\"name\":\"mcad_validate\",\"arguments\":{\"source\":\"result = sphere(5)\"}}}")
echo "raw: $raw"
# The cad plugin's main.go wraps its tool result in {ok, result|error}; the
# MCP envelope wraps that further. Drill through both.
verdict=$(echo "$raw" | python3 - <<'PY' "$raw"
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
try:
    env = json.loads(raw)
except Exception as e:
    print(f"FAIL: invalid JSON ({e})")
    sys.exit(1)
if env.get("error"):
    print(f"FAIL: jsonrpc error: {json.dumps(env['error'])}")
    sys.exit(1)
result = env.get("result", {})
if result.get("isError"):
    print(f"FAIL: tool isError envelope: {json.dumps(result)}")
    sys.exit(1)
content = result.get("content", [])
if not content:
    print(f"FAIL: empty content array: {json.dumps(result)}")
    sys.exit(1)
text = content[0].get("text", "")
try:
    inner = json.loads(text)
except Exception:
    print(f"FAIL: content[0].text not JSON: {text!r}")
    sys.exit(1)
if not inner.get("ok", False):
    err = inner.get("error", {})
    print(f"FAIL: cad mcad_validate returned ok=false: {json.dumps(err)}")
    sys.exit(1)
inner_result = inner.get("result", {})
if not inner_result.get("ok", False):
    print(f"FAIL: inner result.ok != true: {json.dumps(inner_result)}")
    sys.exit(1)
print("PASS")
sys.exit(0)
PY
)
echo "$verdict"
if [[ "$verdict" != PASS* ]]; then
    fail "cad mcad_validate did not return ok=true: $verdict"
fi
echo "::endgroup::"

echo "::group::Step 8: clean stop (cad)"
raw=$(mcp_call "minerva_plugin_stop" '{"id":"cad"}')
echo "stop result: $raw"
echo "::endgroup::"

echo "::notice::tarball-smoke PASS — Minerva tarball installs+starts scansort, then cad install+start+mcad_validate(sphere(5)) end-to-end"
exit 0
