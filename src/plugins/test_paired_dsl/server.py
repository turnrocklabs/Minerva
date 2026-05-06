#!/usr/bin/env python3
"""test_paired_dsl — minimal stub plugin for DCR 019dfa66 §T5.

Exercises the paired_dsl substrate. The render panel reads from the buffer
directly via the broker's attach_buffer / text_changed push channels — the
plugin process has no role in the echo itself. We keep the server thin:
just enough to satisfy the MCP handshake and the cancel_eval channel that
the manifest declares.
"""

import json
import logging
import sys

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[test_paired_dsl] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "test_paired_dsl"
SERVER_VERSION = "0.1.0"


def _ok(req_id, payload):
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "content": [{"type": "text", "text": json.dumps(payload)}],
            "isError": False,
        },
    }


def handle_initialize(_params, req_id):
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        },
    }


def handle_tools_list(_params, req_id):
    return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": []}}


def handle_tools_call(params, req_id):
    name = params.get("name", "")
    args = params.get("arguments", {})
    if name == "test_paired_dsl.cancel_eval":
        # No real evaluator yet — the channel exists so panels can prove the
        # broker round-trip works (panel emits request, broker validates,
        # plugin acknowledges).
        request_id = args.get("request_id", "")
        log.info("cancel_eval ack: request_id=%s", request_id)
        return _ok(req_id, {"ok": True, "request_id": request_id})

    log.warning("unknown tool: %s", name)
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": "Tool not found: %s" % name},
    }


def dispatch(message):
    method = message.get("method", "")
    params = message.get("params", {})
    req_id = message.get("id")
    if req_id is None:
        log.info("notification: %s", method)
        return None
    if method == "initialize":
        return handle_initialize(params, req_id)
    if method == "tools/list":
        return handle_tools_list(params, req_id)
    if method == "tools/call":
        return handle_tools_call(params, req_id)
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": "Method not found: %s" % method},
    }


def _send(obj):
    print(json.dumps(obj, separators=(",", ":")), flush=True)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    log.info("test_paired_dsl server starting")
    for raw in iter(sys.stdin.readline, ""):
        line = raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            log.warning("parse error: %s", exc)
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "Parse error"},
                }
            )
            continue
        response = dispatch(message)
        if response is not None:
            _send(response)
    log.info("test_paired_dsl server shutting down")


if __name__ == "__main__":
    main()
