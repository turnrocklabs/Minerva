#!/usr/bin/env python3
"""MCP stdio fixture that records minerva/host_event notifications.

probe_events: every notification received so far, in order, as
{message, integer_keys}: the whole JSON-RPC message, and the payload keys
that decoded as JSON integers (GD-1: integers must not arrive as 1.0).
probe_clear: forgets them.
probe_exit: answers, then exits with status 3 (an unexpected plugin exit).

The host_event_probe* manifests and chat_target_probe run this one script
under different plugin ids.
"""
import json
import sys
from typing import Any, TypedDict


class ReceivedEvent(TypedDict):
    message: dict[str, Any]
    integer_keys: list[str]

TOOLS = [
    {"name": "probe_capability", "description": "Request a host capability over this real STDIO process.",
     "inputSchema": {"type": "object", "properties": {"capability": {"type": "string"}, "args": {"type": "object"}}, "required": ["capability", "args"]}},
    {"name": "probe_audio_mode", "description": "Select EOS acknowledgement success for the speaker fixture.",
     "inputSchema": {"type": "object", "properties": {"success": {"type": "boolean"}}, "required": ["success"]}},
    {"name": "probe_events", "description": "Host events received so far.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "probe_clear", "description": "Forget received host events.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "probe_exit", "description": "Answer, then exit with status 3.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
]

received: list[ReceivedEvent] = []


def send(msg: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply_text(req_id: int | str | None, value: object) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "result": {
        "content": [{"type": "text", "text": json.dumps(value)}]}})


def main() -> None:
    pending: dict[str, int | str | None] = {}
    sequence = 0
    audio_success = True
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        msg = json.loads(line)
        method = msg.get("method", "")
        req_id = msg.get("id")
        if not method and ("result" in msg or "error" in msg):
            if str(req_id) in pending:
                reply_text(pending.pop(str(req_id)), msg.get("result", msg.get("error")))
            continue
        if method == "minerva/host_event":
            payload = msg.get("params", {}).get("payload", {})
            received.append({"message": msg, "integer_keys": sorted(
                k for k, v in payload.items()
                if isinstance(v, int) and not isinstance(v, bool))})
            if msg.get("params", {}).get("event") == "voice.audio" and payload.get("op") == "end":
                sequence += 1
                send({"jsonrpc": "2.0", "id": f"audio-{sequence}", "method": "minerva/capability",
                      "params": {"capability": "host.audio", "args": {"op": "output_complete",
                      "device_id": payload["device_id"], "stream_id": payload["stream_id"],
                      "success": audio_success, "error_message": "Fixture speaker rejected EOS"}}})
        elif method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "host_event_probe", "version": "0.1.0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            name = msg.get("params", {}).get("name", "")
            if name == "probe_capability":
                sequence += 1
                cap_id = f"cap-{sequence}"
                pending[cap_id] = req_id
                send({"jsonrpc": "2.0", "id": cap_id, "method": "minerva/capability",
                      "params": msg.get("params", {}).get("arguments", {})})
            elif name == "probe_audio_mode":
                audio_success = msg.get("params", {}).get("arguments", {}).get("success", True)
                reply_text(req_id, {"success": True})
            elif name == "probe_events":
                reply_text(req_id, {"success": True, "events": received})
            elif name == "probe_clear":
                received.clear()
                reply_text(req_id, {"success": True})
            elif name == "probe_exit":
                reply_text(req_id, {"success": True})
                sys.exit(3)
            else:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32601, "message": f"Unknown tool: {name}"}})
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": f"Unknown method: {method}"}})


if __name__ == "__main__":
    main()
