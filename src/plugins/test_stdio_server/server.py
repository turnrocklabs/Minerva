#!/usr/bin/env python3
"""
Minimal MCP stdio test server for validating Minerva's stdio transport.

This server implements the MCP JSON-RPC stdio protocol and exposes one tool:
  - echo_text: returns the input text with a prefix

Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
Stderr is used for all diagnostic output (stdout is the transport).

Usage:
    python server.py

To test manually:
    echo '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | python server.py
"""

import sys
import json
import logging

# Stderr is captured separately by Minerva's SubProcess — safe for logging
logging.basicConfig(
    stream=sys.stderr,
    level=logging.DEBUG,
    format="[test_stdio_server] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

TOOL_ECHO = {
    "name": "minerva_test_stdio_server_echo_text",
    "description": "Echoes back the input text with a prefix. Used to validate MCP stdio transport end-to-end.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "The text to echo back",
            }
        },
        "required": ["text"],
    },
}

ALL_TOOLS = [TOOL_ECHO]


# ---------------------------------------------------------------------------
# Handler functions
# ---------------------------------------------------------------------------


def handle_initialize(params: dict, req_id) -> dict:
    """Respond to the MCP initialize handshake."""
    protocol_version = params.get("protocolVersion", "unknown")
    client_info = params.get("clientInfo", {})
    log.info(
        "initialize: protocol=%s client=%s %s",
        protocol_version,
        client_info.get("name", "?"),
        client_info.get("version", "?"),
    )
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "protocolVersion": "2025-06-18",
            "capabilities": {
                "tools": {"listChanged": False},
            },
            "serverInfo": {
                "name": "test_stdio_server",
                "version": "0.1.0",
            },
        },
    }


def handle_tools_list(params: dict, req_id) -> dict:
    """Return the list of available tools."""
    log.info("tools/list called")
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "tools": ALL_TOOLS,
        },
    }


def handle_tools_call(params: dict, req_id) -> dict:
    """Dispatch a tool call."""
    tool_name = params.get("name", "")
    arguments = params.get("arguments", {})
    log.info("tools/call: name=%s args=%s", tool_name, arguments)

    if tool_name == "minerva_test_stdio_server_echo_text":
        text = arguments.get("text", "")
        result_text = f"[echo] {text}"
        log.info("echo_text result: %s", result_text)
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({"result": result_text, "success": True}),
                    }
                ],
                "isError": False,
            },
        }

    # Unknown tool
    log.warning("unknown tool: %s", tool_name)
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {
            "code": -32601,
            "message": f"Tool not found: {tool_name}",
        },
    }


def handle_notification(method: str, params: dict) -> None:
    """Handle notifications (no response sent)."""
    log.info("notification: %s", method)
    # notifications/initialized and similar are no-ops for this server


# ---------------------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------------------


def dispatch(message: dict) -> dict | None:
    """
    Dispatch a JSON-RPC message and return a response dict, or None if no
    response should be sent (i.e., for notifications).
    """
    method = message.get("method", "")
    params = message.get("params", {})
    req_id = message.get("id")  # None means it's a notification

    # Notifications have no id — respond with nothing
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
            "message": f"Method not found: {method}",
        },
    }


# ---------------------------------------------------------------------------
# Main read loop
# ---------------------------------------------------------------------------


def main() -> None:
    log.info("test_stdio_server starting (pid=%d)", __import__("os").getpid())

    # IMPORTANT: stdout must be line-buffered (or unbuffered) so responses are
    # delivered immediately. Python defaults to block-buffering stdout when not
    # a tty, so we reconfigure here.
    #
    # This is a common source of stdio MCP transport hangs: if the server's
    # stdout is block-buffered, the client blocks waiting for data that is
    # sitting in the server's internal buffer.
    sys.stdout.reconfigure(line_buffering=True)  # type: ignore[attr-defined]

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        log.debug("recv: %s", line[:200])

        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            log.error("JSON parse error: %s", exc)
            # Respond with a parse error if we can extract an id
            error_response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {exc}"},
            }
            _send(error_response)
            continue

        response = dispatch(message)
        if response is not None:
            _send(response)

    log.info("stdin closed, exiting")


def _send(obj: dict) -> None:
    """Serialize obj as a single JSON line to stdout."""
    line = json.dumps(obj, separators=(",", ":"))
    log.debug("send: %s", line[:200])
    print(line, flush=True)


if __name__ == "__main__":
    main()
