"""Manual Codex 2025-06-18 discovery probe; launches a billed model run.

Run directly, with optional --prepublished for the startup control.
No Minerva calls or persistent Codex configuration changes. See README.md.
"""
import json
import queue
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(tempfile.mkdtemp(prefix="minerva-mcp-live-probe-"))
EVENTS = []
LOCK = threading.RLock()
STOP = threading.Event()
STREAMS = []
PUBLISHED = "--prepublished" in sys.argv
PROOF = secrets.token_hex(12)
SESSION = secrets.token_hex(16)


def record(event, **fields):
    with LOCK:
        row = {"at": time.monotonic(), "event": event, **fields}
        EVENTS.append(row)
        with (ROOT / "wire.jsonl").open("a") as f:
            f.write(json.dumps(row) + "\n")


def catalog():
    items = [{"name": "publish_tool", "description": "Add a new tool and emit tools/list_changed. Call once, then discover and call the new tool.",
              "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}]
    if PUBLISHED:
        items.append({"name": "newly_added_tool", "description": "Read-only proof of live schema discovery. Use the proof value specified by this schema.",
                      "inputSchema": {"type": "object", "properties": {"proof": {"type": "string", "enum": [PROOF]}},
                                      "required": ["proof"], "additionalProperties": False}})
    return items


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            record("connection_reset_on_exit")

    def reply(self, status, body=None, session=False):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        if session:
            self.send_header("Mcp-Session-Id", SESSION)
        self.end_headers()
        self.wfile.write(raw)

    def valid_request(self, initializing=False):
        if self.path != "/mcp" or self.headers.get("Origin"):
            self.reply(403)
            return False
        if not initializing and self.headers.get("Mcp-Session-Id") != SESSION:
            self.reply(404)
            return False
        return True

    def do_POST(self):
        global PUBLISHED
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        method = req.get("method")
        if not self.valid_request(method == "initialize"):
            return
        params = req.get("params", {})
        record("request", method=method, protocol_header=self.headers.get("MCP-Protocol-Version"),
               tool=params.get("name"), published=PUBLISHED)
        if "id" not in req:
            self.reply(202)
            return
        result = {}
        notify = False
        if method == "initialize":
            record("initialize", requested=params.get("protocolVersion"), client=params.get("clientInfo"))
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": True}},
                      "serverInfo": {"name": "live-tool-probe", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": catalog()}
            record("catalog", names=[t["name"] for t in result["tools"]])
        elif method == "tools/call":
            name = params.get("name")
            if name == "publish_tool":
                PUBLISHED = True
                notify = True
                msg = "Tool added. Discover and call newly_added_tool using its schema. Do not use shell, HTTP, or guess arguments."
                result = {"content": [{"type": "text", "text": msg}]}
            elif name == "newly_added_tool" and PUBLISHED:
                passed = params.get("arguments") == {"proof": PROOF}
                record("late_call", proof_matches=passed)
                result = {"content": [{"type": "text", "text": "LIVE_REFRESH_CONFIRMED" if passed else "Incorrect proof"}], "isError": not passed}
            else:
                self.reply(200, {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32602, "message": "Unknown tool"}})
                return
        elif method != "ping":
            self.reply(200, {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32601, "message": "Method not found"}})
            return
        self.reply(200, {"jsonrpc": "2.0", "id": req["id"], "result": result}, method == "initialize")
        if notify:
            with LOCK:
                if STREAMS:
                    STREAMS[0].put({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
                else:
                    record("notification_no_get_stream")

    def chunk(self, raw):
        self.wfile.write(f"{len(raw):x}\r\n".encode() + raw + b"\r\n")
        self.wfile.flush()

    def do_GET(self):
        if not self.valid_request():
            return
        stream = queue.Queue()
        with LOCK:
            STREAMS.append(stream)
        record("get_stream_open")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            self.chunk(b": connected\n\n")
            while not STOP.is_set():
                try:
                    notification = stream.get(timeout=1)
                except queue.Empty:
                    self.chunk(b": heartbeat\n\n")
                    continue
                self.chunk(("event: message\ndata: " + json.dumps(notification) + "\n\n").encode())
                record("notification_sent")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with LOCK:
                STREAMS.remove(stream)
            record("get_stream_closed")

    def do_DELETE(self):
        self.reply(405)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/mcp"
prompt = ("Run this isolated MCP interoperability test. First call liveprobe.publish_tool once. "
          "It adds newly_added_tool and emits a list-change notification. Then discover and invoke "
          "newly_added_tool using its actual schema. Use native MCP calls/tool discovery only. "
          "Do not use shell, Python, HTTP, external services, or modify files. If the new tool does "
          "not become callable, report that accurately and stop. Do not invent schema arguments.")
if PUBLISHED:
    prompt = ("Run the startup control for an isolated MCP interoperability test. Discover and call "
              "liveprobe.newly_added_tool using its actual schema. Do not call publish_tool. "
              "Use native MCP tools only; do not use shell, Python, HTTP, or modify files.")
cmd = ["codex", "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
       "--sandbox", "read-only", "--json", "-C", str(ROOT),
       "-c", 'approval_policy="never"', "-c", f'mcp_servers.liveprobe.url="{url}"',
       "-c", "mcp_servers.liveprobe.required=true",
       "-c", 'mcp_servers.liveprobe.tools.publish_tool.approval_mode="approve"',
       "-c", 'mcp_servers.liveprobe.tools.newly_added_tool.approval_mode="approve"', prompt]
print(ROOT, flush=True)
try:
    with (ROOT / "codex.jsonl").open("w") as out, (ROOT / "codex.stderr").open("w") as err:
        try:
            completed = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=150)
            code = completed.returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    summary = {"codex_exit": code, "artifact_dir": str(ROOT),
               "mode": "startup_control" if "--prepublished" in sys.argv else "live_add",
               "initial_catalog_seen": any(e["event"] == "catalog" and len(e["names"]) == 1 for e in EVENTS),
               "notification_sent": any(e["event"] == "notification_sent" for e in EVENTS),
               "updated_catalog_seen": any(e["event"] == "catalog" and len(e["names"]) == 2 for e in EVENTS),
               "new_tool_called_with_schema_proof": any(e["event"] == "late_call" and e["proof_matches"] for e in EVENTS)}
    (ROOT / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)
finally:
    STOP.set()
    server.shutdown()
    server.server_close()
