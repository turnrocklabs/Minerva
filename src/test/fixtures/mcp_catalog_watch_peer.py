#!/usr/bin/env python3
"""Deterministic local MCP peer for HTTP/STDIO catalog-watch integration."""
import argparse
import asyncio
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS = 0
LOCK = threading.Lock()
LIST_CONDITION = threading.Condition(LOCK)
LAST_PAGE_COUNT = 0
SUBSCRIPTION_COUNT = 0


def discovery(req_id):
    return {"jsonrpc": "2.0", "id": req_id, "result": {
        "resultType": "complete", "supportedVersions": ["2026-07-28"],
        "capabilities": {"tools": {"listChanged": True}},
        "ttlMs": 0, "cacheScope": "private"}}


def tool_page(req_id, cursor=""):
    global LAST_PAGE_COUNT
    with LOCK:
        generation = TOOLS
    definitions = [{"name": "watch_%d_%d" % (generation, index),
                    "inputSchema": {"type": "object", "properties": {}}}
                   for index in range(3)]
    definitions.append({"name": "large_numeric",
                        "inputSchema": {"type": "object", "properties": {
                            "generation": {"type": "integer",
                                           "enum": [generation]}}}})
    start = int(cursor or 0)
    result = {"resultType": "complete", "ttlMs": 0,
              "cacheScope": "private", "tools": definitions[start:start + 2]}
    if start + 2 < len(definitions):
        result["nextCursor"] = str(start + 2)
    else:
        with LIST_CONDITION:
            LAST_PAGE_COUNT += 1
            LIST_CONDITION.notify_all()
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def subscription_messages(req_id):
    meta = {"io.modelcontextprotocol/subscriptionId": req_id}
    return [
        {"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
         "params": {"_meta": meta}},  # pre-ack: must be ignored
        {"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
         "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": "wrong"},
                    "notifications": {"toolsListChanged": True}}},
        {"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
         "params": {"_meta": meta,
                    "notifications": {"toolsListChanged": True}}},
    ]


def large_result(req_id):
    payload = {"precise": 0.12345678901234566, "padding": list(range(20000))}
    return {"jsonrpc": "2.0", "id": req_id, "result": {
        "resultType": "complete",
        "content": [{"type": "text", "text": json.dumps(payload)}],
        "structuredContent": payload}}


def current_tool_result(req_id, name):
    with LOCK:
        generation = TOOLS
    if name != "watch_%d_0" % generation:
        return {"jsonrpc": "2.0", "id": req_id, "error": {
            "code": -32602, "message": "Tool is not in the current catalog"}}
    payload = {"generation": generation, "tool": name}
    return {"jsonrpc": "2.0", "id": req_id, "result": {
        "resultType": "complete",
        "content": [{"type": "text", "text": json.dumps(payload)}],
        "structuredContent": payload}}


def bump():
    global TOOLS
    with LOCK:
        TOOLS += 1


def wait_for_last_page(count, timeout=5.0):
    deadline = time.monotonic() + timeout
    with LIST_CONDITION:
        while LAST_PAGE_COUNT < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            LIST_CONDITION.wait(remaining)
    return True


def next_subscription():
    global SUBSCRIPTION_COUNT
    with LOCK:
        SUBSCRIPTION_COUNT += 1
        return SUBSCRIPTION_COUNT


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def json_reply(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def sse(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method = req.get("method")
        if method == "server/discover":
            self.json_reply(discovery(req.get("id")))
        elif method == "tools/list":
            self.json_reply(tool_page(req.get("id"), req.get("params", {}).get("cursor", "")))
        elif method == "subscriptions/listen":
            subscription = next_subscription()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            with LOCK:
                listed_before_subscription = LAST_PAGE_COUNT
            messages = subscription_messages(req.get("id"))
            self.sse(messages[0])
            bump()  # changed after the owner's initial list but before valid ack
            self.sse(messages[1])
            self.sse(messages[2])
            if not wait_for_last_page(listed_before_subscription + 1):
                return
            bump()
            event = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                     "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": req.get("id")}}}
            for _ in range(8):
                self.sse(event)
            wait_for_last_page(listed_before_subscription + 2)
            if subscription > 1:
                # Keep the retry attempt active while the client exercises an
                # unrelated call and cancellation; fixture shutdown owns the
                # eventual bounded retirement.
                time.sleep(30.0)
        elif method == "tools/call" and req.get("params", {}).get("name") == "large_numeric":
            self.json_reply(large_result(req.get("id")))
        elif method == "tools/call":
            self.json_reply(current_tool_result(
                req.get("id"), req.get("params", {}).get("name")))
        else:
            self.json_reply({"jsonrpc": "2.0", "id": req.get("id"),
                             "result": {"resultType": "complete", "content": []}})


async def stdio_send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


async def stdio_subscription(req_id):
    subscription = next_subscription()
    with LOCK:
        listed_before_subscription = LAST_PAGE_COUNT
    messages = subscription_messages(req_id)
    await stdio_send(messages[0])
    bump()
    await stdio_send(messages[1])
    await stdio_send(messages[2])
    if not await wait_for_last_page_async(listed_before_subscription + 1):
        return
    bump()
    event = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
             "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": req_id}}}
    for _ in range(8):
        await stdio_send(event)
    if not await wait_for_last_page_async(listed_before_subscription + 2):
        return
    if subscription == 1:
        await stdio_send({"jsonrpc": "2.0", "id": req_id, "result": {
            "resultType": "complete",
            "_meta": {"io.modelcontextprotocol/subscriptionId": req_id}}})


async def wait_for_last_page_async(count, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with LOCK:
            if LAST_PAGE_COUNT >= count:
                return True
        await asyncio.sleep(0.01)
    return False


async def run_stdio():
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            return
        req = json.loads(line)
        method = req.get("method")
        if method == "server/discover":
            await stdio_send(discovery(req.get("id")))
        elif method == "tools/list":
            await stdio_send(tool_page(req.get("id"), req.get("params", {}).get("cursor", "")))
        elif method == "subscriptions/listen":
            asyncio.create_task(stdio_subscription(req.get("id")))
        elif method == "tools/call" and req.get("params", {}).get("name") == "large_numeric":
            await stdio_send(large_result(req.get("id")))
        elif method == "tools/call":
            await stdio_send(current_tool_result(
                req.get("id"), req.get("params", {}).get("name")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=("http", "stdio"), required=True)
    args = parser.parse_args()
    if args.transport == "stdio":
        asyncio.run(run_stdio())
        return
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(json.dumps({"port": server.server_port}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
