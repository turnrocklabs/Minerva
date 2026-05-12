#!/usr/bin/env python3
"""MCP stdio fixture for host.providers.chat capability testing.

probe_chat_text: invokes host.providers.chat with text-only messages.
probe_chat_vision: invokes host.providers.chat with a base64 image in messages.
"""
import json, sys, uuid


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def recv():
    line = sys.stdin.readline()
    return json.loads(line) if line else None


TOOLS = [
    {
        "name": "probe_chat_text",
        "description": "Calls host.providers.chat with text-only messages.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "model": {"type": "string"},
                "provider": {"type": "string"},
                "messages": {
                    "type": "array",
                    "items": {"type": "object"}
                },
            },
            "required": ["model"],
        },
    },
    {
        "name": "probe_chat_vision",
        "description": "Calls host.providers.chat with an image in messages.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "model": {"type": "string"},
                "provider": {"type": "string"},
                "messages": {
                    "type": "array",
                    "items": {"type": "object"}
                },
            },
            "required": ["model"],
        },
    },
]


def call_capability(capability, args):
    """Send minerva/capability mid-tool-call and await the host response."""
    cap_id = str(uuid.uuid4())
    send({
        "jsonrpc": "2.0", "id": cap_id, "method": "minerva/capability",
        "params": {"capability": capability, "args": args},
    })
    while True:
        msg = recv()
        if msg is None:
            return {"success": False, "error_code": "no_response",
                    "error_message": "stdin closed"}
        if str(msg.get("id")) == cap_id:
            if "error" in msg:
                return {"success": False, "error_code": "rpc_error",
                        "error_message": str(msg["error"])}
            return msg.get("result", {})


def build_chat_args(args):
    """Build the host.providers.chat capability args from tool arguments."""
    chat_args = {}
    if "model" in args:
        chat_args["model"] = args["model"]
    if "provider" in args:
        chat_args["provider"] = args["provider"]
    if "messages" in args:
        chat_args["messages"] = args["messages"]
    return chat_args


def handle_tools_call(req_id, name, args):
    if name in ("probe_chat_text", "probe_chat_vision"):
        chat_args = build_chat_args(args)
        result = call_capability("host.providers.chat", chat_args)
        inner = result.get("result", {}) if isinstance(result, dict) else {}
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "content": [{"type": "text", "text": json.dumps({
                "success": result.get("success", False),
                "capability_result": result,
                "was_denied": not result.get("success", False),
                "error_code": result.get("error_code"),
                "error_message": result.get("error_message"),
                "which_budget": result.get("which_budget"),
                "candidates": result.get("candidates"),
                "model": inner.get("model"),
                "provider": inner.get("provider"),
                "content": inner.get("content"),
                "usage": inner.get("usage"),
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
                "serverInfo": {"name": "provider_probe", "version": "0.1.0"},
            }})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = msg.get("params", {})
            handle_tools_call(req_id, params.get("name", ""), params.get("arguments", {}))
        elif method == "notifications/initialized":
            pass
        else:
            if req_id is not None:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32601, "message": "Unknown method: %s" % method}})


if __name__ == "__main__":
    main()
