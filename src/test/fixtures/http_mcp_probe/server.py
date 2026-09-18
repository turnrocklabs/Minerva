"""Loopback-only HTTP peer with observable requests and controlled wire failures."""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
REQUESTS = []

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.reply({"healthy": True})

    def reply(self, value, status=200, extra=()):
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, content in extra:
            self.send_header(name, content)
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with LOCK:
                REQUESTS.append({"path": self.path, "request": request, "headers": dict(self.headers)})
            self.handle_request(request)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_request(self, request):
        request_id = request.get("id")
        method = request["method"]
        def result(value):
            return {"jsonrpc": "2.0", "id": request_id, "result": value}
        if method == "server/discover":
            if self.path == "/legacy":
                self.reply({"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32601, "message": "legacy"}}, 400)
            elif self.path in ("/legacy-session-2025", "/legacy-session-2024",
                               "/legacy-session-notification-unsupported",
                               "/legacy-notification-no-session",
                               "/legacy-session-notification-wrong-id",
                               "/legacy-session-notification-string-code",
                               "/legacy-session-notification-fractional-code",
                               "/legacy-session-invalid-version"):
                self.reply({"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32600,
                                      "message": "session required\nsecret must not surface"}})
            elif self.path == "/modern-error":
                self.reply({"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32022, "message": "version", "data": {"supported": ["future"]}}}, 400)
            elif self.path == "/auth":
                self.reply({"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32001, "message": "denied"}}, 401)
            elif self.path == "/invalid-modern":
                self.reply(result({"resultType": "complete", "supportedVersions": [],
                                   "capabilities": {"tools": {}}, "ttlMs": 0,
                                   "cacheScope": "private"}))
            elif self.path == "/invalid-init":
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.reply(result({"resultType": "complete", "supportedVersions": ["2026-07-28"],
                                   "capabilities": {"tools": {}}, "ttlMs": 0, "cacheScope": "private"}))
            return
        if method == "initialize":
            if self.path == "/invalid-init":
                self.send_response(200)
                self.send_header("Mcp-Session-Id", "invalid")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            version = "2025-06-18"
            if self.path == "/legacy-session-2024":
                version = "2024-11-05"
            elif self.path == "/legacy-session-invalid-version":
                version = "1900-01-01"
            extra = [] if self.path == "/legacy-notification-no-session" else [
                ("Mcp-Session-Id", "legacy-session")]
            self.reply(result({"protocolVersion": version, "capabilities": {"tools": {}},
                               "serverInfo": {"name": "probe", "version": "1"}}),
                       extra=extra)
            return
        if method == "notifications/initialized":
            if self.path in ("/legacy-session-notification-unsupported",
                             "/legacy-notification-no-session",
                             "/legacy-session-notification-wrong-id",
                             "/legacy-session-notification-string-code",
                             "/legacy-session-notification-fractional-code"):
                response_id = "wrong-id" if self.path.endswith("wrong-id") else None
                code = -32601
                if self.path.endswith("string-code"):
                    code = "-32601"
                elif self.path.endswith("fractional-code"):
                    code = -32601.5
                self.reply({"jsonrpc": "2.0", "id": response_id, "error": {
                    "code": code, "message": "notification dispatch unsupported"}})
                return
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "tools/list":
            self.reply(result({"resultType": "complete", "ttlMs": 0,
                               "cacheScope": "private", "tools": [
                {"name": "echo", "inputSchema": {"type": "object", "properties": {
                    "nested": {"type": "object", "properties": {
                        "value": {"type": "string", "x-mcp-header": "Value"}}},
                    "count": {"type": "integer", "x-mcp-header": "Count"},
                    "flag": {"type": "boolean", "x-mcp-header": "Flag"}}}},
                {"name": "invalid", "inputSchema": {"type": "object", "allOf": [
                    {"properties": {"bad": {"type": "string", "x-mcp-header": "Bad"}}}]}}
            ]}))
            return
        name = request.get("params", {}).get("name", "")
        args = request.get("params", {}).get("arguments", {})
        if name == "records":
            with LOCK:
                snapshot = list(REQUESTS)
            self.reply(result({"records": snapshot}))
        elif name == "sleep":
            time.sleep(args.get("ms", 100) / 1000)
            self.reply(result({"slept": True}))
        elif name == "lost":
            self.close_connection = True
            self.connection.shutdown(2)
        elif name == "truncated":
            body = json.dumps(result({"must_not_accept": True})).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body) + 50))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
        elif name in ("eof-framed", "truncated-chunked"):
            body = json.dumps(result({"eof_result": True})).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Connection", "close")
            if name == "truncated-chunked":
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if name == "truncated-chunked":
                self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")
            else:
                self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
        elif name == "unsafe":
            self.reply(result({"unsafe": 9007199254740993}))
        elif name == "wrong-id":
            self.reply({"jsonrpc": "2.0", "id": "different", "result": {}})
        elif name in ("sse", "sse-progress"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            raw = json.dumps(result({"resultType": "complete", "content": [],
                                     "structuredContent": {"text": "hello 世界"}, "future": True}), ensure_ascii=False)
            # Split a JSON object across data lines, then UTF-8 across HTTP chunks.
            raw = raw.replace(', "result"', ',\ndata: "result"', 1)
            prefix = "\ufeff: heartbeat\r\n\r\n"
            if name == "sse-progress":
                progress = {"jsonrpc": "2.0", "method": "notifications/progress",
                            "params": {"progressToken": request["params"]["_meta"]["progressToken"], "progress": 1}}
                prefix += "data: " + json.dumps(progress) + "\r\n\r\n"
            body = (prefix + "data: " + raw + "\r\n\r\n").encode()
            for start in range(0, len(body), 3):
                chunk = body[start:start + 3]
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.002)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        else:
            self.reply(result({"echo": args, "headers": dict(self.headers)}))

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(json.dumps({"port": server.server_port}), flush=True)
server.serve_forever()
