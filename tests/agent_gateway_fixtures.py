"""Shared fixtures for the agent-container gateway tests: instrumented stub
upstreams, a Unix-socket HTTP client, a loopback echo "remote host", and
GatewayCase, which serves a gateway session against the stubs.

Every stub records each request it receives. A denied call must leave no
record of the denied tool on the stub; the dangerous tools are only ever
sent to stubs, never to a real Minerva, Docket or Nudge. Proxy tests inject a
resolver table and a connector that lands on the echo server, so no private
or real address is dialled. Scratch directories are kept.
"""
import http.client
import http.server
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATEWAY = ROOT / "scripts/agent-container/gateway"
sys.dont_write_bytecode = True
sys.path.insert(0, str(GATEWAY))
import gateway  # noqa: E402

TERMINAL, TARGET, OTHER = "1111", "2222", "3333"
SESSION = "claude-a"
NOTE_A, NOTE_B, NOTE_IMG = "1" * 64, "2" * 64, "3" * 64
BUG, POLICY, SECRET, NOTE = ("a" * 32, "b" * 32, "c" * 32, "d" * 32)
PLUGIN_BUG, DCR, KB = "e" * 32, "f" * 32, "0" * 32
ITEMS = {
    ("minerva", BUG): {"id": BUG, "type": "bug", "title": "a bug"},
    ("minerva", POLICY): {"id": POLICY, "type": "policy", "title": "a policy",
                          "description": "POLICY-SENTINEL"},
    ("minerva", SECRET): {"id": SECRET, "type": "secret", "title": "s",
                          "description": "SECRET-SENTINEL"},
    ("minerva", NOTE): {"id": NOTE, "type": "encrypted_note", "title": "n"},
    ("plugins.dct", PLUGIN_BUG): {"id": PLUGIN_BUG, "type": "bug", "title": "plugin bug"},
    ("minerva", DCR): {"id": DCR, "type": "dcr", "title": "a dcr"},
    ("minerva", KB): {"id": KB, "type": "kb", "title": "rubric"},
}
SENTINEL = "LEAK-SENTINEL"
TERMINALS = [
    {"id": TERMINAL, "name": "me", "harness": "claude", "cwd": "/home/x", "foreground_process": "docker"},
    {"id": TARGET, "name": "codex-1", "harness": "codex", "cwd": "/home/y"},
    {"id": OTHER, "name": "private tab", "cwd": "/home/z"},
]


def scratch_dir():
    """Retained scratch; short enough for a Unix socket path (108 bytes)."""
    base = tempfile.gettempdir()
    if len(base) > 60:
        base = "/tmp"
    return Path(tempfile.mkdtemp(prefix="agw-", dir=base))


def text_result(value, is_error=False):
    result = {"content": [{"type": "text", "text": json.dumps(value)}]}
    if is_error:
        result["isError"] = True
    return result


class Stub:
    """An upstream MCP service that records and answers from fixtures."""

    def __init__(self, name):
        self.name, self.records = name, []
        self.mode = "json"          # json | sse | status500 | badjson | wrongid
        self.lookup_mode = "ok"     # ok | error | malformed
        self.custom = None          # custom(handler, body) -> True when it answered
        self.decorate = None        # decorate(tool, result) -> result, for tools/call
        self.terminals = TERMINALS  # what minerva_terminal_list answers
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.records.append({"body": body, "session": self.headers.get("Mcp-Session-Id")})
                stub.reply(self, body)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/mcp"

    def tools_called(self):
        return [r["body"]["params"]["name"] for r in self.records
                if r["body"].get("method") == "tools/call"]

    def calls(self, tool):
        return [r["body"]["params"]["arguments"] for r in self.records
                if r["body"].get("method") == "tools/call" and r["body"]["params"]["name"] == tool]

    def result_for(self, method, params):
        if method == "initialize":
            return {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                    "serverInfo": {"name": self.name}}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [
                {"name": "minerva_terminal_create", "inputSchema": {"type": "object", "properties": {}}},
                {"name": "minerva_terminal_notify", "inputSchema": {"type": "object", "properties": {
                    "to": {}, "text": {}, "from": {}, "reply_to": {}, "wait_ms": {}, "sneaky": {}},
                    "required": ["to", "text", "from"]}},
                {"name": "docket_delete", "inputSchema": {"type": "object", "properties": {}}},
                {"name": "nudge_list_components", "inputSchema": {"type": "object", "properties": {}}},
                {"name": "docket_get", "inputSchema": {"type": "object", "properties": {
                    "id": {}, "project": {}, "include": {}}, "required": ["id"]}},
            ]}
        name, args = params["name"], params["arguments"]
        result = self.tool_result(name, args)
        return self.decorate(name, result) if self.decorate else result

    def tool_result(self, name, args):
        if name == "docket_get":
            if self.lookup_mode == "error":
                return text_result({"error": "backend down"}, is_error=True)
            if self.lookup_mode == "malformed":
                return {"content": [{"type": "text", "text": "not json"}]}
            item = ITEMS.get((args.get("project"), args["id"]))
            return text_result(item) if item else text_result({"error": "not found"}, True)
        if name == "docket_query":
            return text_result({"count": 4, "items": [ITEMS[("minerva", k)] for k in (BUG, POLICY, SECRET, NOTE)]})
        if name == "minerva_get_note":
            notes = {NOTE_A: {"note_id": NOTE_A, "title": "board", "content": "hello", "type": "TEXT",
                              "tab": "Minerva Core Cycle", "enabled": False, "success": True},
                     NOTE_IMG: {"note_id": NOTE_IMG, "title": "img", "content": "", "type": "IMAGE",
                                "image_path": "/home/x/secret.png", "success": True}}
            note = notes.get(args["note_id"])
            return text_result(note) if note else text_result({"error": "no note"}, True)
        if name == "minerva_terminal_list":
            return text_result({"success": True, "terminals": self.terminals, "count": len(self.terminals)})
        return text_result({"success": True, "echo": args})

    def reply(self, handler, body):
        if self.custom and self.custom(handler, body):
            return
        if "id" not in body:
            handler.send_response(202)
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return
        message = {"jsonrpc": "2.0", "id": body["id"],
                   "result": self.result_for(body["method"], body.get("params", {}))}
        mode = self.mode
        if mode == "status500":
            data, ctype, status = b"{}", "application/json", 500
        elif mode == "badjson":
            data, ctype, status = b"{not json", "application/json", 200
        elif mode == "wrongid":
            data, ctype, status = json.dumps({**message, "id": "other"}).encode(), "application/json", 200
        elif mode == "sse":
            progress = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}
            data = (": heartbeat\n\n" + f"data: {json.dumps(progress)}\n\n"
                    + f"data: {json.dumps(message)}\n\n").encode()
            ctype, status = "text/event-stream", 200
        else:
            data, ctype, status = json.dumps(message).encode(), "application/json", 200
        handler.send_response(status)
        handler.send_header("Content-Type", ctype)
        handler.send_header("Content-Length", str(len(data)))
        if body["method"] == "initialize":
            handler.send_header("Mcp-Session-Id", "sess-1")
        handler.end_headers()
        handler.wfile.write(data)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=10)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(self.path)


class Echo:
    """A loopback TCP echo server standing in for a vetted remote host."""

    def __init__(self):
        self.sock = socket.create_server(("127.0.0.1", 0))
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while True:
            conn, _ = self.sock.accept()
            threading.Thread(target=self.echo, args=(conn,), daemon=True).start()

    @staticmethod
    def echo(conn):
        with conn:
            while data := conn.recv(65536):
                conn.sendall(data)


class GatewayCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = scratch_dir()
        cls.stubs = {name: Stub(name) for name in gateway.SERVICES}
        cls.echo = Echo()
        cls.connects = []
        cls.resolve_table = {
            "api.example.com": ["93.184.216.34"],
            "a.allowed.example.org": ["2606:2800:220:1:248:1893:25c8:1946"],
            "mixed.example.com": ["93.184.216.34", "10.0.0.5"],
            "mapped.example.com": ["::ffff:127.0.0.1"],
            "sixtofour.example.com": ["2002:c000:0204::1"],
            "zero.example.com": ["0.0.0.0"],
            "cgnat.example.com": ["100.64.0.1"],
            "linklocal.example.com": ["169.254.169.254"],
            "empty.example.com": [],
            "mappedpublic.example.com": ["::ffff:93.184.216.34"],
        }
        egress = cls.scratch / "egress.json"
        egress.write_text(json.dumps({"allow": [
            {"exact": "api.example.com"}, {"exact": "mixed.example.com"},
            {"exact": "mapped.example.com"}, {"exact": "sixtofour.example.com"},
            {"exact": "zero.example.com"}, {"exact": "cgnat.example.com"},
            {"exact": "linklocal.example.com"}, {"exact": "empty.example.com"},
            {"exact": "mappedpublic.example.com"},
            {"suffix": ".allowed.example.org"}]}))
        cls.sock_dir = cls.scratch / "session"
        cls.sock_dir.mkdir(mode=0o700)
        config = {"upstreams": {n: s.url for n, s in cls.stubs.items()},
                  "policy": str(GATEWAY / "policy.json"), "egress": str(egress)}
        # Laid out as agent.py's state root (MINERVA_AGENT_STATE=cls.state), so
        # agent.py's grant writer and this gateway share one control dir.
        cls.state = cls.scratch / "state"
        cls.control = cls.state / "sessions" / SESSION / "control"
        for private in (cls.state, cls.state / "sessions", cls.control.parent, cls.control):
            private.mkdir(mode=0o700)   # agent.py refuses a state dir others can open
        cls.binding_file = cls.control / "binding.json"
        cls.grants_file = cls.control / "grants.json"
        cls.bind(TERMINAL, [TARGET])
        cls.grant()
        cls.sessions = {"sessions": [{
            "name": SESSION, "harness": "claude", "socket_dir": str(cls.sock_dir),
            "control_dir": str(cls.control),
            "docket_projects": ["minerva", "plugins.dct"]}]}
        cls.config = config

        def connect(ip, port):
            cls.connects.append((ip, port))
            return socket.create_connection(cls.echo.sock.getsockname(), timeout=5)
        cls.servers = gateway.build_servers(config, cls.sessions,
                                            resolve=lambda h: cls.resolve_table[h], connect=connect)
        gateway.serve(cls.servers)

    @classmethod
    def bind(cls, terminal_id, targets, lease_s=60):
        """Write the session's binding the way agent.py attach does."""
        value = {"terminal_id": terminal_id, "notify_targets": targets, "generation": "g1",
                 "expires_at": time.time() + lease_s} if terminal_id else {}
        cls.binding_file.write_text(json.dumps(value))

    @classmethod
    def grant(cls, read=(), write=(), notify=True):
        """Write the session's grant record in the shape agent.py keeps it."""
        cls.grants_file.write_text(json.dumps({"version": 1, "note_read": list(read),
                                               "note_write": list(write), "notify": notify}))

    def setUp(self):
        for stub in self.stubs.values():
            stub.records.clear()
            stub.mode, stub.lookup_mode = "json", "ok"
            stub.custom = stub.decorate = None
            stub.terminals = TERMINALS
        self.connects.clear()
        self.bind(TERMINAL, [TARGET])
        self.grant()

    def post(self, service, body, headers=None, raw=None):
        conn = UnixHTTPConnection(str(self.sock_dir / f"{service}.sock"))
        data = raw if raw is not None else json.dumps(body).encode()
        conn.request("POST", "/mcp", body=data,
                     headers={"Content-Type": "application/json", **(headers or {})})
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, (json.loads(payload) if payload else None), resp

    def call(self, service, tool, args, headers=None):
        _, body, _ = self.post(service, {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                         "params": {"name": tool, "arguments": args}}, headers)
        return body

    def assertDenied(self, body, stub_service=None, tool=None):
        self.assertIn("error", body, body)
        self.assertEqual(body["error"]["code"], -32001, body)
        if tool:
            self.assertNotIn(tool, self.stubs[stub_service].tools_called())

    def result_value(self, body):
        return json.loads(body["result"]["content"][0]["text"])


    def connect_via_proxy(self, head):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(str(self.sock_dir / "proxy.sock"))
        s.sendall(head)
        reply = b""
        while b"\r\n\r\n" not in reply:
            chunk = s.recv(4096)
            if not chunk:
                break
            reply += chunk
        return s, reply
