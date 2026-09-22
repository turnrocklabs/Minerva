#!/usr/bin/env bash
# Source-tree app smoke, run by in-container.sh as the "app-smoke" suite.
#
# Boots the checked-out Minerva (not a test script) on a private Xvfb display
# with a throwaway profile, waits for its MCP HTTP server on the default port
# 9315 inside this container's own network namespace, then checks initialize,
# tools/list and one real tool call before shutting it down. Prints PASS/FAIL
# lines and a "<N> passed, <M> failed" summary for accounting.py.
#
# Only safe inside the container: on a host it would collide with a running
# Minerva's port and profile.
set -uo pipefail

# Refuse before touching any profile or process unless this is the runner's
# container: Docker's marker file, the read-only snapshot mount and the work
# tree in-container.sh made.
if [[ ! -f /.dockerenv || ! -d /snapshot || "${WORK:-}" != /work/tree || ! -d "$WORK/src" ]]; then
	echo "app-smoke: refusing to run outside the container-test container (use scripts/container-test.sh run app-smoke)" >&2
	exit 2
fi

PORT=9315
URL="http://127.0.0.1:$PORT/mcp"
STARTUP_TIMEOUT_S="${STARTUP_TIMEOUT_S:-120}"
LOG=/out/logs/app-smoke-minerva.log
pass=0
fail=0
check() { if [[ "$2" == ok ]]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1 — $2"; fail=$((fail + 1)); fi; }
finish() {
	if [[ -n "${pid:-}" ]]; then
		# Minerva runs in its own session (setsid): signal the whole group so
		# Xvfb, godot and CEF helpers go together.
		kill -TERM -- "-$pid" 2>/dev/null
		for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
		kill -KILL -- "-$pid" 2>/dev/null
	fi
	echo "=== Results: $pass passed, $fail failed ==="
	(( fail == 0 && pass > 0 ))
	exit $?
}

# mcp <method> <params-json>: POST one JSON-RPC request, print the result
# object as JSON, exit non-zero on transport or JSON-RPC error.
mcp() {
	python3 - "$URL" "$1" "$2" <<'EOF'
import json, sys, urllib.request
url, method, params = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
req = urllib.request.Request(url, body, {"Content-Type": "application/json",
    "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"})
try:
    reply = json.load(urllib.request.urlopen(req, timeout=30))
except Exception as e:
    print(f"transport error: {e}"); sys.exit(1)
if "error" in reply:
    print(json.dumps(reply["error"])); sys.exit(1)
print(json.dumps(reply.get("result", {})))
EOF
}

# The profile helper lives in the tested revision; older revisions predate it
# and fall back to the container's private (empty) HOME profile.
if [[ -f "$WORK/scripts/lib/test-profile.sh" ]]; then
	source "$WORK/scripts/lib/test-profile.sh"
	seed_test_profile "$(mktemp -d)" || { check "seed profile" "failed"; finish; }
fi

# --headless keeps Godot from opening a window; Xvfb is still needed because
# godot-cef's helper processes want an X display (see scripts/tarball-smoke.sh).
setsid xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" \
	stdbuf -oL -eL godot --headless --path "$WORK/src" > "$LOG" 2>&1 &
pid=$!
trap finish TERM INT

init=""
deadline=$(( $(date +%s) + STARTUP_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
	kill -0 "$pid" 2>/dev/null || break
	if init=$(mcp initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"container-app-smoke","version":"1"}}' 2>/dev/null); then
		break
	fi
	init=""
	sleep 1
done
if [[ -z "$init" ]]; then
	check "MCP HTTP on :$PORT within ${STARTUP_TIMEOUT_S}s" "not reachable (Minerva $(kill -0 "$pid" 2>/dev/null && echo running || echo exited)); tail: $(tail -5 "$LOG" | tr '\n' ' ')"
	finish
fi
check "MCP HTTP answered initialize on :$PORT" ok

# Prove the listener is this container's own: /proc/net/tcp is per network
# namespace, so the host's Minerva on the same port never appears here.
listening=$(awk -v p="$(printf ':%04X' "$PORT")" '$2 ~ p"$" && $4 == "0A"' /proc/net/tcp /proc/net/tcp6 | wc -l)
check "port $PORT listening in this network namespace" "$( (( listening > 0 )) && echo ok || echo "no LISTEN socket")"

tools=$(mcp tools/list '{}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tools", [])))' 2>/dev/null)
check "tools/list returned tools ($tools)" "$( [[ "${tools:-0}" -gt 0 ]] && echo ok || echo "got ${tools:-none}")"

clock=$(mcp tools/call '{"name":"minerva_clock","arguments":{}}')
clock_ok=$(printf '%s' "$clock" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("ok" if r.get("content") and not r.get("isError") else "error result")' 2>/dev/null)
check "tools/call minerva_clock" "${clock_ok:-unparseable reply: $clock}"

finish
