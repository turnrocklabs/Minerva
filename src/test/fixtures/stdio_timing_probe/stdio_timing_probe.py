#!/usr/bin/env python3
"""Minimal MCP stdio fixture for connection-layer concurrency testing.

This fixture exercises Minerva's MCP-over-stdio connection layer when several
tool calls are in flight on a single connection at once. Its --profile modes
also exercise modern discovery, legacy fallback, late replies, and startup
budget exhaustion. Tools:

  echo         returns its arguments immediately.
  sleep        waits "ms" milliseconds, then replies with a confirmation.
  never_reply  accepts the call and deliberately never sends a response.
  emit_stray   emits an unsolicited JSON-RPC response with an unmatched id,
               then also replies normally to the actual call.

CONCURRENCY MODEL
-----------------
The reader MUST NOT block while a slow tool (sleep) is pending, otherwise the
fixture cannot accept the additional in-flight requests the tests depend on.

This is implemented with asyncio:

  * A single reader task (`reader_loop`) runs `await loop.run_in_executor(...)`
    on each blocking `stdin.readline()`. The blocking read happens on a thread
    pool worker, so the asyncio event loop itself is never blocked. As soon as
    a full JSON-RPC frame is parsed, the request is dispatched as its OWN
    asyncio task (`asyncio.create_task`) and the reader immediately loops back
    to read the next frame.

  * Each request's handler is an independent coroutine. `sleep` uses
    `await asyncio.sleep(...)` (a NON-blocking yield) so it suspends only that
    one task; the reader task and every other request task keep running. As a
    result responses are produced independently and may be written OUT of
    arrival order (instant echoes reply long before a concurrent sleep).

  * stdout is shared mutable state, so every write goes through `send()` which
    holds an `asyncio.Lock` for the duration of the write+flush. This
    serializes frames so concurrent responders cannot interleave/corrupt JSON.

NO blocking sleep ever sits on the reader path: the reader only awaits the
thread-pooled readline, and `sleep` uses `asyncio.sleep`, never `time.sleep`.
"""
import asyncio
import argparse
import json
import sys

# stdout is shared; serialize all writes so frames never interleave.
_write_lock = asyncio.Lock()
MODE = "legacy"
CANCELLED_IDS = []
INITIALIZE_PARAMS = {}


async def send(msg):
    """Write one JSON-RPC frame to stdout under a lock (newline-delimited)."""
    async with _write_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


async def send_raw(line):
    """Write an intentional raw-number fixture without Python float coercion."""
    async with _write_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


TOOLS = [
    {"name": "echo", "description": "Returns its arguments immediately.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "sleep", "description": "Waits 'ms' milliseconds, then confirms.",
     "inputSchema": {"type": "object", "properties": {
         "ms": {"type": "integer", "description": "Delay in milliseconds."}},
      "required": ["ms"]}},
    {"name": "never_reply",
     "description": "Accepts the call and never sends a response.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "emit_stray",
     "description": "Emits an unmatched-id response, then replies normally.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "cancellations",
     "description": "Returns the modern request IDs cancelled by the client.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "session",
     "description": "Returns legacy initialization state.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "precision_loss",
     "description": "Returns a decimal Godot cannot decode losslessly.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "error_precision_loss",
     "description": "Returns an RPC error with a lossy decimal in error data.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "large_numeric",
     "description": "Returns enough numeric data to keep raw validation observable.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
]


def _text_result(req_id, payload):
    """Build a standard MCP tools/call result envelope."""
    result = {"content": [{"type": "text", "text": json.dumps(payload)}]}
    if MODE == "modern":
        result.update({"resultType": "complete",
                       "structuredContent": {"fixture": "preserved"},
                       "futureField": {"kept": True}})
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


async def handle_tools_call(req_id, name, args):
    """Independent coroutine: produces this request's response after its delay.

    Runs as its own asyncio task, so suspending here (await asyncio.sleep)
    never stalls the reader or any sibling request.
    """
    if name == "echo":
        # Reply immediately with the arguments echoed back.
        await send(_text_result(req_id, {"success": True, "echo": args}))

    elif name == "sleep":
        ms = args.get("ms", 0)
        try:
            ms = int(ms)
        except (TypeError, ValueError):
            ms = 0
        # Clamp to [0, 600000] ms so a typo'd value can't hang the fixture past any test budget.
        ms = min(max(ms, 0), 600000)
        # NON-blocking yield: suspends only this task for `ms` milliseconds.
        await asyncio.sleep(ms / 1000.0)
        await send(_text_result(req_id, {
            "success": True, "slept_ms": ms, "message": "sleep complete"}))

    elif name == "never_reply":
        # Deliberately send nothing. The task simply ends; the request stays
        # pending forever so the host's timeout path can be exercised.
        return

    elif name == "large_numeric":
        await send(_text_result(req_id, {
            "success": True, "values": list(range(100000))}))

    elif name == "emit_stray":
        # First emit an unsolicited response whose id matches no pending
        # request. A well-behaved host must ignore it and not wedge.
        # NOTE: tests must match the stray frame by its id ("stray-unmatched-id"),
        # never by stream position — its ordering versus other concurrent
        # requests' replies is not guaranteed.
        await send({"jsonrpc": "2.0", "id": "stray-unmatched-id",
                    "result": {"content": [{"type": "text",
                                             "text": json.dumps({"stray": True})}]}})
        # Then reply normally to the actual call.
        await send(_text_result(req_id, {
            "success": True, "emitted_stray": True}))

    elif name == "cancellations":
        await asyncio.sleep(0.05)
        await send(_text_result(req_id, {
            "success": True, "cancelled_ids": list(CANCELLED_IDS)}))

    elif name == "session":
        await send(_text_result(req_id, {
            "success": True,
            "working_directory": INITIALIZE_PARAMS.get("workingDirectory", "")}))

    elif name == "precision_loss":
        await send_raw('{"jsonrpc":"2.0","id":%s,"result":'
                       '{"resultType":"complete","content":[],"structuredContent":'
                       '{"n":0.10000000000000001}}}' % json.dumps(req_id))

    elif name == "error_precision_loss":
        await send_raw('{"jsonrpc":"2.0","id":%s,"error":'
                       '{"code":-32000,"message":"fixture error","data":'
                       '{"n":0.10000000000000001}}}' % json.dumps(req_id))

    else:
        await send({"jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32601,
                              "message": "Method not found: %s" % name}})


async def dispatch(msg):
    """Handle one parsed JSON-RPC message. Runs as its own task per request."""
    method = msg.get("method", "")
    req_id = msg.get("id")

    if method == "server/discover":
        if MODE == "modern_error":
            await send({"jsonrpc": "2.0", "id": req_id, "error": {
                "code": -32021, "message": "Required capability is missing"}})
        elif MODE == "invalid_modern":
            await send({"jsonrpc": "2.0", "id": req_id, "result": {
                "resultType": "complete", "ttlMs": 0, "cacheScope": "private",
                "supportedVersions": ["2099-01-01"], "capabilities": {}}})
        elif MODE in ("probe_timeout", "late_probe", "all_timeout"):
            if MODE == "late_probe":
                async def late_reply():
                    await asyncio.sleep(1.5)
                    await send({"jsonrpc": "2.0", "id": req_id, "result": {
                        "resultType": "complete", "ttlMs": 0,
                        "cacheScope": "private",
                        "supportedVersions": ["2026-07-28"],
                        "capabilities": {"tools": {}}}})
                asyncio.create_task(late_reply())
        elif MODE == "modern":
            meta = msg.get("params", {}).get("_meta", {})
            if (meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28"
                    or meta.get("io.modelcontextprotocol/clientCapabilities") != {}
                    or meta.get("io.modelcontextprotocol/clientInfo", {}).get("name") != "Minerva"):
                await send({"jsonrpc": "2.0", "id": req_id, "error": {
                    "code": -32602, "message": "Missing modern metadata"}})
            else:
                await send({"jsonrpc": "2.0", "id": req_id, "result": {
                    "resultType": "complete", "ttlMs": 0,
                    "cacheScope": "private",
                    "supportedVersions": ["2026-07-28"],
                    "capabilities": {"tools": {}},
                    "_meta": {"io.modelcontextprotocol/serverInfo": {
                        "name": "stdio_timing_probe", "version": "0.2.0"}}}})
        else:
            await send({"jsonrpc": "2.0", "id": req_id, "error": {
                "code": -32601, "message": "Unknown method: server/discover"}})
    elif method == "initialize":
        if MODE == "all_timeout":
            return
        global INITIALIZE_PARAMS
        INITIALIZE_PARAMS = msg.get("params", {})
        await send({"jsonrpc": "2.0", "id": req_id, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "stdio_timing_probe", "version": "0.1.0"}
        }})
    elif method == "tools/list":
        await send({"jsonrpc": "2.0", "id": req_id,
                    "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = msg.get("params", {})
        if MODE == "modern":
            meta = params.get("_meta", {})
            if meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28":
                await send({"jsonrpc": "2.0", "id": req_id, "error": {
                    "code": -32602, "message": "Missing per-request metadata"}})
                return
        await handle_tools_call(req_id, params.get("name", ""),
                                params.get("arguments", {}))
    elif method == "notifications/cancelled":
        CANCELLED_IDS.append(msg.get("params", {}).get("requestId"))
    elif method == "notifications/initialized":
        pass  # notification: no response
    else:
        if req_id is not None:
            await send({"jsonrpc": "2.0", "id": req_id,
                        "error": {"code": -32601,
                                  "message": "Unknown method: %s" % method}})


async def reader_loop():
    """Continuously read + dispatch frames; never blocks the event loop.

    The blocking stdin.readline() runs on a thread-pool executor so the event
    loop stays free. Each frame is dispatched as an independent task and the
    reader immediately loops to read the next one, so new requests are accepted
    while earlier slow requests (sleep) are still pending.
    """
    loop = asyncio.get_running_loop()
    pending = set()
    try:
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                break  # stdin closed
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # ignore malformed frames
            task = asyncio.create_task(dispatch(msg))
            pending.add(task)
            task.add_done_callback(pending.discard)
    finally:
        # Let any in-flight non-blocking handlers finish writing cleanly.
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)


def main():
    global MODE
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="legacy")
    MODE = parser.parse_args().profile
    asyncio.run(reader_loop())


if __name__ == "__main__":
    main()
