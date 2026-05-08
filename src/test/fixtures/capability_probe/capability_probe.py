#!/usr/bin/env python3
"""Minimal MCP stdio fixture for host capability channel testing.

probe_echo: calls host.echo and returns the echoed payload.
probe_denied: requests host.nonexistent to exercise the deny path.
"""
import json, sys, uuid

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def recv():
    line = sys.stdin.readline()
    return json.loads(line) if line else None

TOOLS = [
    {"name": "probe_echo", "description": "Calls host.echo.",
     "inputSchema": {"type": "object", "properties": {
         "payload": {"type": "object"}}, "required": []}},
    {"name": "probe_denied", "description": "Requests undeclared capability.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
]

def call_capability(capability, args):
    """Send minerva/capability mid-tool-call and await the host response."""
    cap_id = str(uuid.uuid4())
    send({"jsonrpc": "2.0", "id": cap_id, "method": "minerva/capability",
          "params": {"capability": capability, "args": args}})
    while True:
        msg = recv()
        if msg is None:
            return {"success": False, "error_code": "no_response", "error_message": "stdin closed"}
        if str(msg.get("id")) == cap_id:
            if "error" in msg:
                return {"success": False, "error_code": "rpc_error",
                        "error_message": str(msg["error"])}
            return msg.get("result", {})

def handle_tools_call(req_id, name, args):
    if name == "probe_echo":
        payload = args.get("payload", {})
        result = call_capability("host.echo", payload)
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "content": [{"type": "text", "text": json.dumps({
                "success": True,
                "capability_result": result,
                "echo": result.get("result", {}).get("echo"),
            })}]
        }})
    elif name == "probe_denied":
        result = call_capability("host.nonexistent", {})
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "content": [{"type": "text", "text": json.dumps({
                "success": True,
                "capability_result": result,
                "was_denied": not result.get("success", False),
                "error_code": result.get("error_code"),
            })}]
        }})
    else:
        send({"jsonrpc": "2.0", "id": req_id,
              "error": {"code": -32601, "message": "Method not found: %s" % name}})

def main():
    while True:
        msg = recv()
        if msg is None:
            break
        method = msg.get("method", "")
        req_id = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "capability_probe", "version": "0.1.0"}
            }})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = msg.get("params", {})
            handle_tools_call(req_id, params.get("name", ""), params.get("arguments", {}))
        elif method == "notifications/initialized":
            pass  # no response needed
        else:
            if req_id is not None:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32601, "message": "Unknown method: %s" % method}})

if __name__ == "__main__":
    main()
