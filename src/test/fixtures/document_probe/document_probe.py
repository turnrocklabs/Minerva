#!/usr/bin/env python3
"""MCP stdio fixture for host.documents.* capability testing.

probe_list: calls host.documents.list_open and returns the response.
probe_state: calls host.documents.get_state with the supplied editor_name.
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
        "name": "probe_list",
        "description": "Calls host.documents.list_open.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "probe_state",
        "description": "Calls host.documents.get_state on a given editor.",
        "inputSchema": {
            "type": "object",
            "properties": {"editor_name": {"type": "string"}},
            "required": ["editor_name"],
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


def handle_tools_call(req_id, name, args):
    if name == "probe_list":
        result = call_capability("host.documents.list_open", {})
        inner = result.get("result", {}) if isinstance(result, dict) else {}
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "content": [{"type": "text", "text": json.dumps({
                "success": True,
                "capability_result": result,
                "documents": inner.get("documents", []),
                "was_denied": not result.get("success", False),
                "error_code": result.get("error_code"),
            })}]
        }})
    elif name == "probe_state":
        editor_name = args.get("editor_name", "")
        result = call_capability("host.documents.get_state",
                                 {"editor_name": editor_name})
        inner = result.get("result", {}) if isinstance(result, dict) else {}
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "content": [{"type": "text", "text": json.dumps({
                "success": True,
                "capability_result": result,
                "buffer_text": inner.get("buffer_text"),
                "buffer_canonical": inner.get("buffer_canonical"),
                "kind": inner.get("kind"),
                "plugin_id": inner.get("plugin_id"),
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
                "serverInfo": {"name": "document_probe", "version": "0.1.0"},
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
