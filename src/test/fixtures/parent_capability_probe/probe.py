"""Real legacy JSON-RPC peer for parent provenance and notification opt-in."""
import json
import sys
from typing import Any


def send(message: dict[str, Any]) -> None:
    """JSON is intentionally dynamic at this protocol boundary."""
    print(json.dumps(message), flush=True)


def result(request_id: str | float | None, payload: dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": request_id, "result": {
        "content": [{"type": "text", "text": json.dumps(payload)}]}})


def main() -> None:
    pending: dict[str, Any] = {}
    cancelled: list[Any] = []
    previous: Any = None
    sequence = 0
    active_parent: str | float | None = None
    completed_caps = 0
    for line in sys.stdin:
        message = json.loads(line)
        request_id = message.get("id")
        method = message.get("method", "")
        if not method and request_id in pending:
            completed_caps += 1
            result(pending.pop(request_id), message.get("result", {}))
        elif method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                "serverInfo": {"name": "parent-probe", "version": "1"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [
                {"name": name, "inputSchema": {"type": "object", "properties": {}},
                 **({"outputSchema": {"type": "object", "properties": {
                     "ok": {"type": "boolean"}}, "required": ["ok"]}}
                    if name == "parent" else {})}
                for name in ("parent", "hold", "counts", "release_parent")]}})
        elif method in ("tools/call", "private/write"):
            params = (message["params"] if method == "tools/call" else {
                "name": "parent", "arguments": message["params"]})
            name = params["name"]
            arguments = params.get("arguments", {})
            if name == "parent":
                sequence += 1
                capability_id = f"cap-{sequence}"
                active_parent = request_id
                capability: dict[str, Any] = {
                    "capability": arguments.get("capability", "host.echo"),
                    "args": arguments.get("payload", arguments)}
                mode = arguments.get("mode", "live")
                if mode != "absent":
                    capability["parent_request_id"] = (
                        request_id if mode == "live" else previous if mode == "stale"
                        else arguments.get("parent"))
                previous = request_id
                pending[capability_id] = request_id
                send({"jsonrpc": "2.0", "id": capability_id,
                      "method": "minerva/capability", "params": capability})
            elif name == "counts":
                result(request_id, {"success": True, "cancelled_ids": cancelled,
                                    "completed_caps": completed_caps})
            elif name == "release_parent":
                kind = arguments["kind"]
                if kind == "raw":
                    sys.stdout.write('{"jsonrpc":"2.0","id":' + json.dumps(active_parent)
                                     + ',"result":{"content":[],"structuredContent":'
                                     '{"n":9007199254740993}}}\n')
                    sys.stdout.flush()
                elif kind == "rpc_error":
                    send({"jsonrpc": "2.0", "id": active_parent, "error": {
                        "code": -32017, "message": "Deliberate peer failure",
                        "data": {"kept": True}}})
                else:
                    body: dict[str, Any] = {"content": [{"type": "text", "text": (
                        '{"n":9007199254740993}' if kind == "nested"
                        else '{"success":true}')}], "structuredContent": {"ok": "wrong"}}
                    send({"jsonrpc": "2.0", "id": active_parent, "result": body})
                result(request_id, {"success": True})
            # hold deliberately leaves the real request outstanding.
        elif method == "notifications/cancelled":
            cancelled.append(message["params"]["requestId"])
            # Model the legacy Rust readers: unknown no-id methods get a reply.
            send({"jsonrpc": "2.0", "id": None,
                  "error": {"code": -32601, "message": "Unknown notification"}})
        elif method != "notifications/initialized":
            send({"jsonrpc": "2.0", "id": request_id,
                  "error": {"code": -32601, "message": "Unknown method"}})


if __name__ == "__main__":
    main()
