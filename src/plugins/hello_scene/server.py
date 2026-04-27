#!/usr/bin/env python3
"""
Hello Scene MCP stdio server for Minerva plugin system.

This is the Phase 1B integration-validation plugin (§2.6 MVP scope).
It exercises every platform surface:
  - MCP initialize handshake
  - tools/list (empty — no externally-callable MCP tools in this MVP)
  - tools/call dispatch for IPC channels:
      hello.greet            — greet the user
      hello.content_changed  — ACK content-change notification from scene
      hello.serialize        — serialize panel state for .minproj
      hello.deserialize      — restore panel state from .minproj
      hello.collect_export   — collect sidecar files for .minpackage
      hello.apply_export     — apply unpacked paths after .minpackage unpack

Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
Stdout is JSON-RPC frames only. Stderr is free for diagnostics.

Usage:
    python3 server.py

Manual test:
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' | python3 server.py
"""

import sys
import json
import logging
from datetime import datetime, timezone

# Stderr is separate from stdout — safe for logging.
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[hello_scene] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Protocol constants
# ---------------------------------------------------------------------------

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "hello_scene"
SERVER_VERSION = "0.1.0"


# ---------------------------------------------------------------------------
# Server-side state (per-document cache)
# ---------------------------------------------------------------------------
#
# The plugin server is the source of truth for any state that lives outside
# the panel UI.  Round-tripping demonstrates the full serialize/deserialize
# contract end-to-end:
#   - hello.content_changed updates _states[file_path]
#   - hello.greet increments greet_count
#   - hello.serialize returns the cached state in tab_state
#   - hello.deserialize restores the state when a project reopens
#
# Keyed by file_path so multiple .hello tabs don't clobber each other.

_states: dict = {}


def _state_for(file_path: str) -> dict:
    """Get or initialise the state slot for a given file path."""
    s = _states.get(file_path)
    if s is None:
        s = {"cached_text": "", "greet_count": 0}
        _states[file_path] = s
    return s


# ---------------------------------------------------------------------------
# JSON-RPC handlers
# ---------------------------------------------------------------------------


def handle_initialize(params: dict, req_id) -> dict:
    """Respond to the MCP initialize handshake."""
    log.info("initialize: protocolVersion=%s", params.get("protocolVersion", "?"))
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {
                "tools": {"listChanged": False},
            },
            "serverInfo": {
                "name": SERVER_NAME,
                "version": SERVER_VERSION,
            },
        },
    }


def handle_tools_list(params: dict, req_id) -> dict:
    """Return the list of available tools.

    This MVP exposes no externally-callable MCP tools — the IPC channels
    (hello.greet, etc.) are dispatched directly by the broker as tools/call
    with the channel name as the tool name, but they are not listed here for
    agent consumption.  An empty list is correct.
    """
    log.info("tools/list: returning empty list (no agent-facing tools in this MVP)")
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "tools": [],
        },
    }


def handle_tools_call(params: dict, req_id) -> dict:
    """Dispatch a tool call (IPC channel) and return the result."""
    tool_name = params.get("name", "")
    arguments = params.get("arguments", {})

    log.info("tools/call: %s", tool_name)

    if tool_name == "hello.greet":
        return _handle_greet(arguments, req_id)

    if tool_name == "hello.content_changed":
        return _handle_content_changed(arguments, req_id)

    if tool_name == "hello.serialize":
        return _handle_serialize(arguments, req_id)

    if tool_name == "hello.deserialize":
        return _handle_deserialize(arguments, req_id)

    if tool_name == "hello.collect_export":
        return _handle_collect_export(arguments, req_id)

    if tool_name == "hello.apply_export":
        return _handle_apply_export(arguments, req_id)

    # Unknown tool
    log.warning("tools/call: unknown tool '%s'", tool_name)
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {
            "code": -32601,
            "message": "Tool not found: %s" % tool_name,
        },
    }


# ---------------------------------------------------------------------------
# IPC channel handlers
# ---------------------------------------------------------------------------


def _handle_greet(arguments: dict, req_id) -> dict:
    """hello.greet — returns a greeting that includes the user's text.

    Also increments the per-file greet_count so the server has demonstrable
    state to round-trip through serialize/deserialize.
    """
    message = arguments.get("message", "")
    file_path = arguments.get("file_path", "")
    log.info("hello.greet: message='%s' file='%s'", message[:80], file_path)
    state = _state_for(file_path)
    state["greet_count"] += 1
    greeting = "hello from server, you said: %s" % message
    return _ok(req_id, {"text": greeting, "greet_count": state["greet_count"]})


def _handle_content_changed(arguments: dict, req_id) -> dict:
    """hello.content_changed — cache the latest text so serialize can return it.

    Receives: {text, file_path?}
    Returns:  {ok: true}
    """
    text = arguments.get("text", "")
    file_path = arguments.get("file_path", "")
    state = _state_for(file_path)
    state["cached_text"] = text
    log.info("hello.content_changed: file='%s' len=%d", file_path, len(text))
    return _ok(req_id, {"ok": True})


def _handle_serialize(arguments: dict, req_id) -> dict:
    """hello.serialize — called by Minerva when saving a .minproj entry.

    Receives: {file_path, panel_name, editor_id}
    Returns:  {tab_state, sidecar_paths}

    tab_state is server-side state ONLY (cached_text, greet_count, saved_at).
    The platform separately captures panel UI state via _on_panel_save_request
    and stashes it under tab_state.__panel_state — that path is owned by the
    Editor wrapper, not by us.  We must NOT overwrite tab_state.__panel_state
    here.  By returning a fresh dict that does not include that key, the
    platform's merge step preserves the panel-side capture intact.
    """
    file_path = arguments.get("file_path", "")
    panel_name = arguments.get("panel_name", "")
    editor_id = arguments.get("editor_id", "")
    state = _state_for(file_path)
    log.info("hello.serialize: file='%s' panel='%s' editor='%s' greet_count=%d",
             file_path, panel_name, editor_id, state["greet_count"])
    tab_state = {
        "version": 1,
        "cached_text": state["cached_text"],
        "greet_count": state["greet_count"],
        "saved_at": datetime.now(timezone.utc).isoformat(),
    }
    return _ok(req_id, {
        "tab_state": tab_state,
        "sidecar_paths": [],
    })


def _handle_deserialize(arguments: dict, req_id) -> dict:
    """hello.deserialize — called by Minerva when restoring a tab from .minproj.

    Receives: {tab_state, stored_version, file_path?}
    Restores server-side state from tab_state into _states.
    Returns:  {ok: true}
    """
    tab_state = arguments.get("tab_state", {})
    stored_version = arguments.get("stored_version", "")
    file_path = arguments.get("file_path", "") or tab_state.get("file_path", "")
    state = _state_for(file_path)
    state["cached_text"] = tab_state.get("cached_text", "")
    state["greet_count"] = int(tab_state.get("greet_count", 0))
    log.info("hello.deserialize: file='%s' stored_version='%s' restored greet_count=%d",
             file_path, stored_version, state["greet_count"])
    return _ok(req_id, {"ok": True})


def _handle_collect_export(arguments: dict, req_id) -> dict:
    """hello.collect_export — called by Minerva during .minpackage export.

    This MVP has no extra files to pack; the channel is exercised but trivially.
    Returns: {files: [], paths_to_rewrite: {}}
    """
    log.info("hello.collect_export: no sidecar files to collect (trivial MVP)")
    return _ok(req_id, {
        "files": [],
        "paths_to_rewrite": {},
    })


def _handle_apply_export(arguments: dict, req_id) -> dict:
    """hello.apply_export — called by Minerva after .minpackage unpack.

    Receives: {unpack_dir}
    Returns:  {ok: true}
    """
    unpack_dir = arguments.get("unpack_dir", "")
    log.info("hello.apply_export: unpack_dir='%s'", unpack_dir)
    return _ok(req_id, {"ok": True})


# ---------------------------------------------------------------------------
# Notification handler
# ---------------------------------------------------------------------------


def handle_notification(method: str, params: dict) -> None:
    """Handle notifications (no response sent)."""
    log.info("notification: %s", method)
    # After the MCP handshake completes (notifications/initialized), emit a
    # host.notify smoke-test so the end-to-end channel can be verified.
    if method == "notifications/initialized":
        _send_host_notify("info", "hello_scene plugin started — host.notify channel OK")


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------


def _send_host_notify(level: str, message: str, details=None) -> None:
    """Emit a host.notify JSON-RPC 2.0 notification to Minerva (no id, no response expected).

    Wire format:
        {"jsonrpc":"2.0","method":"host.notify",
         "params":{"level":"info|warning|error","message":"...","details":<optional>}}
    """
    params: dict = {"level": level, "message": message}
    if details is not None:
        params["details"] = details
    _send({"jsonrpc": "2.0", "method": "host.notify", "params": params})
    log.info("host.notify sent: level=%s message=%s", level, message[:80])


def _ok(req_id, payload: dict) -> dict:
    """Build a successful JSON-RPC tools/call response."""
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(payload),
                }
            ],
            "isError": False,
        },
    }


# ---------------------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------------------


def dispatch(message: dict) -> dict | None:
    """Dispatch a JSON-RPC message. Returns a response, or None for notifications."""
    method = message.get("method", "")
    params = message.get("params", {})
    req_id = message.get("id")

    # Notifications have no id.
    if req_id is None:
        handle_notification(method, params)
        return None

    if method == "initialize":
        return handle_initialize(params, req_id)

    if method == "tools/list":
        return handle_tools_list(params, req_id)

    if method == "tools/call":
        return handle_tools_call(params, req_id)

    # Unknown method
    log.warning("unknown method: %s", method)
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {
            "code": -32601,
            "message": "Method not found: %s" % method,
        },
    }


# ---------------------------------------------------------------------------
# Transport: line-delimited JSON over stdin/stdout
# ---------------------------------------------------------------------------


def _send(obj: dict) -> None:
    """Serialize obj as a single JSON line to stdout."""
    line = json.dumps(obj, separators=(",", ":"))
    print(line, flush=True)


def main() -> None:
    # CRITICAL: stdout must be line-buffered for stdio MCP transport.
    # Python defaults to block-buffering when stdout is not a tty.
    sys.stdout.reconfigure(line_buffering=True)

    log.info("hello_scene server starting (pid=%d)", __import__("os").getpid())

    for raw_line in iter(sys.stdin.readline, ""):
        line = raw_line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            log.warning("JSON parse error: %s", exc)
            _send({
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error"},
            })
            continue

        response = dispatch(message)
        if response is not None:
            _send(response)

    log.info("hello_scene server shutting down (stdin EOF)")


if __name__ == "__main__":
    main()
