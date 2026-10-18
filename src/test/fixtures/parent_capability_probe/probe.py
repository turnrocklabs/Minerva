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
    for line in sys.stdin:
        message = json.loads(line)
        request_id = message.get("id")
        method = message.get("method", "")
        if not method and request_id in pending:
            result(pending.pop(request_id), message.get("result", {}))
        elif method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                "serverInfo": {"name": "parent-probe", "version": "1"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [
                {"name": name, "inputSchema": {"type": "object", "properties": {}}}
                for name in ("parent", "hold", "counts")]}})
        elif method == "tools/call":
            params = message["params"]
            name = params["name"]
            arguments = params.get("arguments", {})
            if name == "parent":
                sequence += 1
                capability_id = f"cap-{sequence}"
                capability: dict[str, Any] = {"capability": "host.echo", "args": arguments}
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
                result(request_id, {"success": True, "cancelled_ids": cancelled})
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
