#!/usr/bin/env python3
"""MCP stdio fixture that records minerva/host_event notifications.

probe_events: every notification received so far, in order, as
{message, integer_keys}: the whole JSON-RPC message, and the payload keys
that decoded as JSON integers (GD-1: integers must not arrive as 1.0).
probe_clear: forgets them.

The host_event_probe* manifests and chat_target_probe run this one script
under different plugin ids.
"""
import json, sys

TOOLS = [
    {"name": "probe_events", "description": "Host events received so far.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "probe_clear", "description": "Forget received host events.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
]

received = []


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply_text(req_id, value):
    send({"jsonrpc": "2.0", "id": req_id, "result": {
        "content": [{"type": "text", "text": json.dumps(value)}]}})


def main():
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        msg = json.loads(line)
        method = msg.get("method", "")
        req_id = msg.get("id")
        if method == "minerva/host_event":
            payload = msg.get("params", {}).get("payload", {})
            received.append({"message": msg, "integer_keys": sorted(
                k for k, v in payload.items()
                if isinstance(v, int) and not isinstance(v, bool))})
        elif method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "host_event_probe", "version": "0.1.0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            name = msg.get("params", {}).get("name", "")
            if name == "probe_events":
                reply_text(req_id, {"success": True, "events": received})
            elif name == "probe_clear":
                received.clear()
                reply_text(req_id, {"success": True})
            else:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32601, "message": "Unknown tool: %s" % name}})
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "Unknown method: %s" % method}})


if __name__ == "__main__":
    main()
