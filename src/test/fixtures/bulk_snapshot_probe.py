#!/usr/bin/env python3
"""Small stdio backend for the real panel bulk-transport regression."""
import json
import sys
import time


def send(message):
    frame = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
    # Force a read boundary inside a multibyte character, independent of pipe size.
    split = frame.find("界".encode("utf-8"))
    if split >= 0:
        sys.stdout.buffer.write(frame[: split + 1])
        sys.stdout.buffer.flush()
        time.sleep(0.04)
        frame = frame[split + 1 :]
    sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()


for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "bulk_snapshot_probe", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": []}
    elif method == "tools/call":
        params = request["params"]
        args = params.get("arguments", {})
        if params["name"] == "expand":
            body = {"success": True, "snapshot": "x" * (8 * 1024 * 1024)}
        else:
            if params["name"] == "wait":
                time.sleep(0.1)
            body = {"success": True, "snapshot": args.get("snapshot", {})}
        result = {"content": [{"type": "text", "text": json.dumps(body, ensure_ascii=False)}]}
    else:
        send({"jsonrpc": "2.0", "id": request["id"],
              "error": {"code": -32601, "message": "Unknown method"}})
        continue
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})
