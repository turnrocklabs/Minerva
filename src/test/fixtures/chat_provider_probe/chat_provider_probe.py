#!/usr/bin/env python3
"""MCP stdio fixture for chat-passthrough W1.

Tools:
  register_self  — calls host.chat_providers.register to advertise an entry,
                   returns the broker result. (registration via capability path)
  unregister_self — calls host.chat_providers.unregister.
  minerva_chatprovider_generate — the generate_tool. Echoes a structured reply
                   keyed by the incoming text:
                     text "pong"  -> {kind:"answer", text:"pong-7"}
                     text "ask"   -> {kind:"question", text:"Pick one",
                                      options:[{label,keystroke}...]}
                     text "boom"  -> {kind:"error", text:"deliberate failure"}
                     otherwise    -> {kind:"answer", text:"echo:<text>"}
                   Also reflects whether a 'messages' arg was present, so the
                   history_mode contract can be asserted from the plugin side.
"""
import json, sys, uuid

ENTRY_ID = "main"
DISPLAY_NAME = "Probe Passthrough"
GENERATE_TOOL = "minerva_chatprovider_generate"

# Records, across the process lifetime, whether the last generate call carried a
# 'messages' arg. The test reads this back via the generate reply.
def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def recv():
    line = sys.stdin.readline()
    return json.loads(line) if line else None


TOOLS = [
    {"name": "register_self", "description": "Register a chat provider entry.",
     "inputSchema": {"type": "object", "properties": {
         "history_mode": {"type": "string"}}, "required": []}},
    {"name": "unregister_self", "description": "Unregister the chat provider entry.",
     "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": GENERATE_TOOL, "description": "Generate a turn.",
     "inputSchema": {"type": "object", "properties": {
         "chat_id": {"type": "string"},
         "text": {"type": "string"},
         "messages": {"type": "array"}}, "required": []}},
]


def call_capability(capability, args):
    cap_id = str(uuid.uuid4())
    send({"jsonrpc": "2.0", "id": cap_id, "method": "minerva/capability",
          "params": {"capability": capability, "args": args}})
    while True:
        msg = recv()
        if msg is None:
            return {"success": False, "error_code": "no_response"}
        if str(msg.get("id")) == cap_id:
            if "error" in msg:
                return {"success": False, "error_code": "rpc_error",
                        "error_message": str(msg["error"])}
            return msg.get("result", {})


def reply(req_id, payload):
    send({"jsonrpc": "2.0", "id": req_id, "result": {
        "content": [{"type": "text", "text": json.dumps(payload)}]
    }})


def handle_generate(args):
    text = str(args.get("text", ""))
    has_messages = "messages" in args
    if text == "pong":
        return {"kind": "answer", "text": "pong-7", "has_messages": has_messages}
    if text == "ask":
        return {"kind": "question", "text": "Pick one", "has_messages": has_messages,
                "options": [
                    {"label": "Yes", "keystroke": "y"},
                    {"label": "No", "keystroke": "n"},
                ]}
    if text == "boom":
        return {"kind": "error", "text": "deliberate failure", "has_messages": has_messages}
    return {"kind": "answer", "text": "echo:" + text, "has_messages": has_messages}


def handle_tools_call(req_id, name, args):
    if name == "register_self":
        history_mode = str(args.get("history_mode", "newest_only"))
        result = call_capability("host.chat_providers.register", {
            "entry_id": ENTRY_ID,
            "display_name": DISPLAY_NAME,
            "generate_tool": GENERATE_TOOL,
            "history_mode": history_mode,
        })
        reply(req_id, {"success": True, "register_result": result})
    elif name == "unregister_self":
        result = call_capability("host.chat_providers.unregister", {"entry_id": ENTRY_ID})
        reply(req_id, {"success": True, "unregister_result": result})
    elif name == GENERATE_TOOL:
        reply(req_id, handle_generate(args))
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
                "serverInfo": {"name": "chat_provider_probe", "version": "0.1.0"}
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
