#!/usr/bin/env python3
"""
Notes Helper MCP stdio server for Minerva plugin system.

This plugin exposes one tool:
  - minerva_notes_helper_create_summary: Summarize text and return the summary.
    Minerva's CapabilityBroker handles the actual note creation via the
    notes.create host capability.

Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.

Stderr is captured separately by Minerva's SubProcess and available via
has_stderr() / read_stderr_line(). Use stderr freely for diagnostics.

Usage:
    python3 server.py

Manual test:
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' | python3 server.py
"""

import sys
import json
import logging

# Stderr is separate from stdout — safe for logging
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[notes_helper] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Protocol constants
# ---------------------------------------------------------------------------

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "notes_helper"
SERVER_VERSION = "0.1.0"

TOOL_CREATE_SUMMARY = {
    "name": "minerva_notes_helper_create_summary",
    "description": (
        "Summarize text and create a note with the summary. "
        "Generates a concise summary of the provided text."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "Text to summarize",
            },
            "max_length": {
                "type": "integer",
                "description": "Max summary length in words (default: 50)",
                "default": 50,
            },
        },
        "required": ["text"],
    },
}

TOOL_DIAGNOSTICS = {
    "name": "minerva_notes_helper_diagnostics",
    "description": "Test tool that writes to stderr at various log levels. Used to verify stderr routing.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "level": {
                "type": "string",
                "description": "Log level to emit: info, warning, or error",
                "enum": ["info", "warning", "error"],
            },
            "message": {
                "type": "string",
                "description": "Message to log",
            },
        },
        "required": ["level", "message"],
    },
}

ALL_TOOLS = [TOOL_CREATE_SUMMARY, TOOL_DIAGNOSTICS]


# ---------------------------------------------------------------------------
# Summarization logic
# ---------------------------------------------------------------------------


def summarize_text(text: str, max_length: int = 50) -> str:
    """
    Generate a simple extractive summary by taking the first N words.

    This is intentionally naive -- the point of this plugin is to prove the
    end-to-end architecture (manifest -> install -> start -> tool call ->
    capability broker -> note creation), not to implement sophisticated NLP.
    """
    if not text or not text.strip():
        return "(empty input)"

    words = text.split()
    if len(words) <= max_length:
        return text.strip()

    truncated = " ".join(words[:max_length])
    return truncated + "..."


# ---------------------------------------------------------------------------
# JSON-RPC handlers
# ---------------------------------------------------------------------------


def handle_initialize(params: dict, req_id) -> dict:
    """Respond to the MCP initialize handshake."""
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
    """Return the list of available tools."""
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "tools": ALL_TOOLS,
        },
    }


def handle_tools_call(params: dict, req_id) -> dict:
    """Dispatch a tool call and return the result."""
    tool_name = params.get("name", "")
    arguments = params.get("arguments", {})

    log.info("tools/call: %s (args: %d keys)", tool_name, len(arguments))

    if tool_name == "minerva_notes_helper_create_summary":
        text = arguments.get("text", "")
        max_length = int(arguments.get("max_length", 50))
        log.info("Summarizing %d words (max_length=%d)", len(text.split()), max_length)
        summary = summarize_text(text, max_length)
        log.info("Summary: %d words, truncated=%s", len(summary.split()), len(text.split()) > max_length)

        result_payload = {
            "summary": summary,
            "original_length_words": len(text.split()) if text.strip() else 0,
            "summary_length_words": len(summary.split()) if summary.strip() else 0,
            "truncated": len(text.split()) > max_length if text.strip() else False,
            # Request Minerva to create a note with the summary.
            # Minerva's CapabilityBroker will check policy (notes.create must be
            # granted) and dispatch to the host note creation code.
            "capability_requests": [
                {
                    "capability": "notes.create",
                    "args": {
                        "title": "Summary",
                        "content": summary,
                    },
                }
            ],
        }

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(result_payload),
                    }
                ],
                "isError": False,
            },
        }

    if tool_name == "minerva_notes_helper_diagnostics":
        level = arguments.get("level", "info")
        message = arguments.get("message", "test")

        if level == "error":
            log.error(message)
        elif level == "warning":
            log.warning(message)
        else:
            log.info(message)

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({"logged": True, "level": level, "message": message}),
                    }
                ],
                "isError": False,
            },
        }

    # Unknown tool
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
    # notifications/initialized and similar are no-ops
    pass


# ---------------------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------------------


def dispatch(message: dict) -> dict | None:
    """
    Dispatch a JSON-RPC message. Returns a response dict, or None for
    notifications (which have no id).
    """
    method = message.get("method", "")
    params = message.get("params", {})
    req_id = message.get("id")

    # Notifications have no id
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
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {
            "code": -32601,
            "message": f"Method not found: {method}",
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

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            error_response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error"},
            }
            _send(error_response)
            continue

        response = dispatch(message)
        if response is not None:
            _send(response)


if __name__ == "__main__":
    main()
