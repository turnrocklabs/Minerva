#!/usr/bin/env python3
"""Agent-container gateway (scripts/agent-container/gateway) against
instrumented stub upstreams.

Every stub records each request it receives. A denied call must leave no
record of the denied tool on the stub; the dangerous tools are only ever
sent to stubs, never to a real Minerva, Docket or Nudge. Proxy tests inject a
resolver table and a connector that lands on a local echo server, so no
private or real address is dialled. Scratch directories are kept.
"""
import http.client
import http.server
import json
from pathlib import Path
import socket
import sys
import io
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
        if name == "minerva_terminal_list":
            return text_result({"success": True, "terminals": TERMINALS, "count": 3})
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


class GatewayTest(unittest.TestCase):
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
        cls.sessions = {"sessions": [{
            "terminal_id": TERMINAL, "harness": "claude", "socket_dir": str(cls.sock_dir),
            "notify_targets": [TARGET], "docket_projects": ["minerva", "plugins.dct"]}]}
        cls.config = config

        def connect(ip, port):
            cls.connects.append((ip, port))
            return socket.create_connection(cls.echo.sock.getsockname(), timeout=5)
        cls.servers = gateway.build_servers(config, cls.sessions,
                                            resolve=lambda h: cls.resolve_table[h], connect=connect)
        gateway.serve(cls.servers)

    def setUp(self):
        for stub in self.stubs.values():
            stub.records.clear()
            stub.mode, stub.lookup_mode = "json", "ok"
            stub.custom = stub.decorate = None
        self.connects.clear()

    # ── helpers ──
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

    # ── envelope and transport ──
    def test_envelope_rejections_never_reach_upstream(self):
        cases = {
            "batch": b'[{"jsonrpc":"2.0","id":1,"method":"ping"}]',
            "duplicate keys": b'{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}',
            "invalid utf8": b'{"jsonrpc":"2.0","id":1,"method":"\xff"}',
            "nan": b'{"jsonrpc":"2.0","id":NaN,"method":"ping"}',
            "lone surrogate": b'{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":"\\ud800"}}',
            "unknown field": b'{"jsonrpc":"2.0","id":1,"method":"ping","extra":1}',
            "bad version": b'{"jsonrpc":"1.0","id":1,"method":"ping"}',
            "unknown method": b'{"jsonrpc":"2.0","id":1,"method":"resources/list"}',
            "bool id": b'{"jsonrpc":"2.0","id":true,"method":"ping"}',
            "unknown call param": b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","task":1}}',
            "request without id": b'{"jsonrpc":"2.0","method":"tools/list"}',
        }
        for label, raw in cases.items():
            with self.subTest(label):
                status, body, _ = self.post("minerva", None, raw=raw)
                if label == "request without id":
                    self.assertEqual(status, 200)
                self.assertIn("error", body)
        self.assertEqual(self.stubs["minerva"].records, [])

    def test_http_level_refusals(self):
        status, _, _ = self.post("docket", {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                                 headers={"Origin": "http://evil.example"})
        self.assertEqual(status, 403)
        # The gateway answers 413 from the header alone, before any body is read.
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(str(self.sock_dir / "docket.sock"))
        s.sendall(b"POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n")
        self.assertTrue(s.recv(64).startswith(b"HTTP/1.1 413"))
        s.close()
        conn = UnixHTTPConnection(str(self.sock_dir / "docket.sock"))
        conn.request("GET", "/mcp")
        self.assertEqual(conn.getresponse().status, 405)
        conn.close()
        status, _, _ = self.post("docket", {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                                 headers={"Mcp-Session-Id": "bad id with spaces"})
        self.assertEqual(status, 400)
        self.assertEqual(self.stubs["docket"].records, [])

    def test_session_header_round_trip_and_meta_stripped(self):
        status, body, resp = self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": {"protocolVersion": "2025-06-18",
                                                            "capabilities": {}, "clientInfo": {"name": "t"},
                                                            "_meta": {"x": 1}}})
        self.assertEqual(status, 200)
        self.assertEqual(resp.getheader("Mcp-Session-Id"), "sess-1")
        self.assertNotIn("_meta", self.stubs["nudge"].records[0]["body"]["params"])
        status, _, _ = self.post("nudge", {"jsonrpc": "2.0", "method": "notifications/initialized"},
                                 headers={"Mcp-Session-Id": "sess-1"})
        self.assertEqual(status, 202)
        self.call("nudge", "nudge_list_components", {}, headers={"Mcp-Session-Id": "sess-1"})
        self.assertEqual([r["session"] for r in self.stubs["nudge"].records], [None, "sess-1", "sess-1"])

    def test_upstream_failures_are_not_relayed(self):
        for mode in ("status500", "badjson", "wrongid"):
            with self.subTest(mode):
                self.stubs["nudge"].mode = mode
                body = self.call("nudge", "nudge_list_components", {})
                self.assertEqual(body["error"]["code"], -32002)

    def test_concurrency_is_bounded(self):
        # A zero-slot server refuses at once instead of queueing.
        path = self.scratch / "bounded.sock"
        server = gateway.mcp_http.make_server(str(path), None, max_concurrent=1)
        server._slots.acquire()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        conn = UnixHTTPConnection(str(path))
        conn.request("POST", "/mcp", body=b"{}")
        self.assertEqual(conn.getresponse().status, 503)
        conn.close()
        server.shutdown()
        server.server_close()

    # ── tool allowlist ──
    def test_dangerous_tools_never_reach_upstream(self):
        cases = [
            ("minerva", "minerva_terminal_create", {"background": True}),
            ("minerva", "minerva_terminal_write", {"text": "id\r"}),
            ("minerva", "minerva_terminal_read", {}),
            ("minerva", "minerva_disk_write", {"path": "/tmp/x", "content": "x"}),
            ("minerva", "minerva_plugin_install", {"path": "/tmp/x"}),
            ("minerva", "minerva_container_build", {"name": "x"}),
            ("minerva", "minerva_enable_tool_sets", {"sets": ["all"]}),
            ("minerva", "minerva_policy_reload", {}),
            ("docket", "docket_delete", {"id": BUG, "project": "minerva"}),
            ("docket", "docket_secret_get", {"key": "k"}),
            ("docket", "docket_project_add", {"path": "/tmp/x.dct", "create": True}),
            ("docket", "docket_link", {"id": BUG, "project": "minerva"}),
            ("docket", "docket_context", {"project": "minerva"}),
            ("nudge", "nudge_import", {"payload": {}, "mode": "replace"}),
            ("nudge", "nudge_delete_hint", {"component": "c", "key": "k"}),
            ("nudge", "nudge_export", {}),
        ]
        for service, tool, args in cases:
            with self.subTest(tool):
                self.assertDenied(self.call(service, tool, args))
        for stub in self.stubs.values():
            self.assertEqual(stub.records, [], stub.name)

    def test_tools_list_is_filtered_and_pruned(self):
        _, body, _ = self.post("minerva", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = {t["name"]: t for t in body["result"]["tools"]}
        self.assertEqual(set(tools), {"minerva_terminal_notify"})
        schema = tools["minerva_terminal_notify"]["inputSchema"]
        self.assertNotIn("sneaky", schema["properties"])
        _, body, _ = self.post("docket", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = {t["name"]: t for t in body["result"]["tools"]}
        self.assertEqual(set(tools), {"docket_get"})
        schema = tools["docket_get"]["inputSchema"]
        self.assertEqual(schema["required"], ["id", "project"])
        self.assertEqual(set(schema["properties"]), {"id", "project", "include"})
        self.assertFalse(schema["additionalProperties"])

    def test_unknown_arguments_and_values_denied(self):
        cases = [
            ("nudge", "nudge_get_hint", {"component": "c", "key": "k", "path": "/etc"}),
            ("nudge", "nudge_set_hint", {"component": "c\nx", "key": "k", "value": 1}),
            ("nudge", "nudge_bump", {"component": "c", "key": "k", "delta": True}),
            ("docket", "docket_query", {"project": "minerva", "detail": "lean"}),
            ("docket", "docket_query", {"project": "minerva", "limit": 100000}),
            ("nudge", "nudge_query", {"regex": "(a+)+$"}),
        ]
        for service, tool, args in cases:
            with self.subTest(tool=tool, args=args):
                self.assertDenied(self.call(service, tool, args))
        self.assertEqual(self.stubs["nudge"].records + self.stubs["docket"].records, [])

    def test_allowed_nudge_call_forwards_unchanged(self):
        args = {"component": "c", "key": "k", "value": {"nested": [1, 2]}}
        body = self.call("nudge", "nudge_set_hint", args)
        self.assertTrue(self.result_value(body)["success"])
        self.assertEqual(self.stubs["nudge"].calls("nudge_set_hint"), [args])

    # ── Docket ──
    def test_docket_project_and_id_shape(self):
        cases = [
            {"id": BUG},                                         # no project: no silent default
            {"id": BUG, "project": "Master-Private"},            # not in session scope
            {"id": "aaaa", "project": "minerva"},                # prefix id
            {"id": BUG.upper(), "project": "minerva"},           # not canonical hex
            {"id": f"plugins.dct:{PLUGIN_BUG}", "project": "minerva"},  # cross-project primary id
        ]
        for args in cases:
            with self.subTest(args=args):
                self.assertDenied(self.call("docket", "docket_get", args))
        self.assertEqual(self.stubs["docket"].records, [])

    def test_docket_get_discloses_nothing_for_denied_types(self):
        for item in (POLICY, SECRET, NOTE):
            with self.subTest(item=item):
                body = self.call("docket", "docket_get", {"id": item, "project": "minerva"})
                self.assertDenied(body)
                self.assertNotIn("SENTINEL", json.dumps(body))
        body = self.call("docket", "docket_get", {"id": BUG, "project": "minerva"})
        self.assertEqual(self.result_value(body)["type"], "bug")

    def test_docket_query_drops_denied_types_and_forces_full(self):
        body = self.call("docket", "docket_query", {"project": "minerva", "filter": {"status": "new"}})
        value = self.result_value(body)
        self.assertEqual([i["id"] for i in value["items"]], [BUG])
        self.assertEqual(value["count"], 1)
        self.assertNotIn("SENTINEL", json.dumps(body))
        self.assertEqual(self.stubs["docket"].calls("docket_query")[0]["detail"], "full")

    def test_docket_mutations_on_denied_types_fail_closed(self):
        cases = [
            ("docket_update", {"id": POLICY, "project": "minerva", "description": "x"}),
            ("docket_update", {"id": SECRET, "project": "minerva", "title": "x"}),
            ("docket_transition", {"id": POLICY, "project": "minerva", "to": "active"}),
            ("docket_transition", {"id": NOTE, "project": "minerva", "to": "sealed"}),
            ("docket_comment", {"action": "add", "item_id": POLICY, "project": "minerva", "text": "x"}),
            ("docket_create", {"type": "policy", "title": "x", "project": "minerva"}),
            ("docket_create", {"type": "bug", "title": "x", "project": "minerva", "parent": POLICY}),
            ("docket_update", {"id": BUG, "project": "minerva", "blocked_by": SECRET}),
            ("docket_update", {"id": BUG, "project": "minerva", "parent": f"Master:{BUG}"}),
            ("docket_update", {"id": BUG, "project": "minerva", "type": "policy"}),
            ("docket_comment", {"action": "accept", "item_id": BUG, "project": "minerva", "comment_id": 1}),
            # A reply names a comment the gateway cannot tie to the vetted item.
            ("docket_comment", {"action": "reply", "item_id": BUG, "project": "minerva",
                                "comment_id": 5, "text": "x"}),
            ("docket_comment", {"action": "reply", "item_id": BUG, "project": "minerva", "text": "x"}),
            ("docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                "comment_id": 5, "text": "x"}),
            ("docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                "text": "x", "author": "codex@codex-1"}),
        ]
        for tool, args in cases:
            with self.subTest(tool=tool, args=args):
                self.assertDenied(self.call("docket", tool, args))
        mutations = {"docket_update", "docket_transition", "docket_comment", "docket_create"}
        self.assertFalse(mutations & set(self.stubs["docket"].tools_called()),
                         self.stubs["docket"].tools_called())

    def test_docket_lookup_failures_deny(self):
        for mode in ("error", "malformed"):
            with self.subTest(mode):
                self.stubs["docket"].lookup_mode = mode
                self.assertDenied(self.call("docket", "docket_update",
                                            {"id": BUG, "project": "minerva", "title": "x"}))
        self.assertNotIn("docket_update", self.stubs["docket"].tools_called())

    def test_docket_allowed_mutations_forward_with_canonical_refs(self):
        body = self.call("docket", "docket_update", {"id": BUG, "project": "minerva", "title": "t",
                                                     "parent": f"plugins.dct:{PLUGIN_BUG}"})
        self.assertIn("result", body, body)
        self.assertEqual(self.stubs["docket"].calls("docket_update"),
                         [{"id": BUG, "project": "minerva", "title": "t",
                           "parent": f"plugins.dct:{PLUGIN_BUG}"}])
        self.call("docket", "docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                               "text": "hello"})
        self.assertEqual(self.stubs["docket"].calls("docket_comment")[0]["author"],
                         f"container:claude@{TERMINAL}")
        body = self.call("docket", "docket_create", {"type": "bug", "title": "t", "project": "minerva",
                                                     "parent": BUG})
        self.assertIn("result", body, body)

    def test_readable_types_are_not_all_mutable(self):
        for item in (DCR, KB):
            with self.subTest(item=item):
                body = self.call("docket", "docket_get", {"id": item, "project": "minerva"})
                self.assertIn("result", body, body)
        body = self.call("docket", "docket_comment", {"action": "list", "item_id": DCR, "project": "minerva"})
        self.assertIn("result", body, body)
        for tool, args in (
                ("docket_update", {"id": KB, "project": "minerva", "article": "x"}),
                ("docket_transition", {"id": DCR, "project": "minerva", "to": "approved"}),
                ("docket_comment", {"action": "add", "item_id": DCR, "project": "minerva", "text": "x"}),
                ("docket_create", {"type": "dcr", "title": "x", "project": "minerva"})):
            with self.subTest(tool=tool):
                self.assertDenied(self.call("docket", tool, args))
        called = self.stubs["docket"].tools_called()
        self.assertFalse({"docket_update", "docket_transition", "docket_create"} & set(called), called)
        self.assertEqual(len(self.stubs["docket"].calls("docket_comment")), 1)  # the list

    # ── numbers, bounds and shaping ──
    def test_nonfinite_and_oversized_numbers_refused_over_http(self):
        cases = [
            b'{"jsonrpc":"2.0","id":1e999,"method":"ping"}',
            b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nudge_set_hint",'
            b'"arguments":{"component":"c","key":"k","value":-1e999}}}',
            b'{"jsonrpc":"2.0","id":' + b"9" * 40 + b',"method":"ping"}',
            b'{"jsonrpc":"2.0","id":99999999999999999999,"method":"ping"}',   # beyond 2**53
        ]
        for raw in cases:
            with self.subTest(raw=raw[:50]):
                status, body, _ = self.post("nudge", None, raw=raw)
                self.assertEqual(status, 200)
                self.assertIn("error", body)
        self.assertEqual(self.stubs["nudge"].records, [])
        self.assertIn("result", self.call("nudge", "nudge_list_components", {}))  # still serving

    def test_initialize_and_cursor_bounds(self):
        cases = [
            {"protocolVersion": "x" * 100, "capabilities": {}, "clientInfo": {}},
            {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"n": "x" * 5000}},
            {"capabilities": {}},
        ]
        for params in cases:
            with self.subTest(params=str(params)[:40]):
                _, body, _ = self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": params})
                self.assertIn("error", body)
        _, body, _ = self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                         "params": {"cursor": "c" * 1000}})
        self.assertIn("error", body)
        self.assertEqual(self.stubs["nudge"].records, [])

    def test_upstream_payloads_are_rebuilt_not_relayed(self):
        nudge, docket = self.stubs["nudge"], self.stubs["docket"]

        def decorate(tool, result):
            if tool == "nudge_set_hint":
                return {"content": [{"type": "text", "text": json.dumps(
                    {"error": "version conflict", "data": SENTINEL})}], "isError": True}
            return {**result, "structuredContent": {"s": SENTINEL}, "_meta": {"s": SENTINEL}}
        nudge.decorate = decorate
        body = self.call("nudge", "nudge_list_components", {})
        self.assertEqual(set(body["result"]), {"content"})
        body = self.call("nudge", "nudge_set_hint", {"component": "c", "key": "k", "value": 1})
        self.assertTrue(body["result"]["isError"])
        self.assertEqual(self.result_value(body), {"error": "version conflict"})

        docket.decorate = lambda tool, result: {**result, "structuredContent": {"s": SENTINEL}}
        body = self.call("docket", "docket_get", {"id": BUG, "project": "minerva"})
        self.assertEqual(self.result_value(body)["id"], BUG)
        docket.decorate = lambda tool, result: text_result({"error": SENTINEL}, is_error=True)
        self.assertDenied(self.call("docket", "docket_get", {"id": BUG, "project": "minerva"}))
        self.assertDenied(self.call("docket", "docket_query", {"project": "minerva"}))

        def rpc_error(handler, body):
            if body.get("method") != "tools/call":
                return False
            data = json.dumps({"jsonrpc": "2.0", "id": body["id"],
                               "error": {"code": -32000, "message": SENTINEL, "data": SENTINEL}}).encode()
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(data)))
            handler.end_headers()
            handler.wfile.write(data)
            return True
        nudge.decorate, nudge.custom = None, rpc_error
        errors = [self.call("nudge", "nudge_list_components", {})]

        def init_extra(handler, body):
            if body.get("method") != "initialize":
                return False
            data = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": {
                "protocolVersion": "2025-06-18", "instructions": SENTINEL,
                "capabilities": {"tools": {}, "resources": {"s": SENTINEL}},
                "serverInfo": {"name": "n", "extra": SENTINEL}}}).encode()
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(data)))
            handler.end_headers()
            handler.wfile.write(data)
            return True
        nudge.custom = init_extra
        _, init, _ = self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}}})
        self.assertEqual(init["result"]["capabilities"], {"tools": {}})
        self.assertEqual(errors[0]["error"]["code"], -32002)
        everything = json.dumps([body, errors, init])
        self.assertNotIn(SENTINEL, everything)

    def test_logs_carry_codes_not_client_or_upstream_strings(self):
        captured, saved = io.StringIO(), sys.stderr
        sys.stderr = captured
        try:
            self.call("nudge", "leak_sentinel_tool", {})
            self.call("nudge", "nudge_get_hint", {"component": "c", "key": "k", "leak_sentinel_arg": 1})
            self.post("nudge", None, raw=b'{"jsonrpc":"2.0","id":1,"leak_sentinel_key":1,"leak_sentinel_key":2}')
            self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "leak_sentinel/x"})
            self.stubs["nudge"].mode = "badjson"
            self.call("nudge", "nudge_list_components", {})
        finally:
            sys.stderr = saved
        log = captured.getvalue()
        self.assertIn('"tool": "(unlisted)"', log)
        self.assertIn('"code": "argument_not_allowed"', log)
        self.assertNotIn("leak_sentinel", log)

    # ── deadlines ──
    def test_upstream_sse_kept_open_returns_on_match(self):
        def open_stream(handler, body):
            if body.get("method") != "tools/call":
                return False
            message = {"jsonrpc": "2.0", "id": body["id"], "result": text_result({"success": True})}
            handler.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
                                + b": heartbeat\n\n" + f"data: {json.dumps(message)}\n\n".encode())
            handler.wfile.flush()
            time.sleep(5)   # the stream stays open well past the answer
            handler.close_connection = True
            return True
        self.stubs["minerva"].custom = open_stream
        started = time.monotonic()
        body = self.call("minerva", "minerva_terminal_notify", {"to": TARGET, "text": "see item"})
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(self.result_value(body)["success"])

    def test_dripping_upstream_hits_the_deadline(self):
        def drip(handler, body):
            if body.get("method") != "tools/call":
                return False
            handler.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                b"Content-Length: 1000\r\n\r\n")
            try:
                for _ in range(25):
                    handler.wfile.write(b" ")
                    handler.wfile.flush()
                    time.sleep(0.2)
            except OSError:
                pass
            handler.close_connection = True
            return True
        self.stubs["nudge"].custom = drip
        saved = gateway.mcp_http.UPSTREAM_DEADLINE_S
        gateway.mcp_http.UPSTREAM_DEADLINE_S = 1.0
        try:
            started = time.monotonic()
            body = self.call("nudge", "nudge_list_components", {})
        finally:
            gateway.mcp_http.UPSTREAM_DEADLINE_S = saved
        self.assertLess(time.monotonic() - started, 2.5)
        self.assertEqual(body["error"]["code"], -32002)

    def test_dripping_client_releases_its_slot(self):
        policy = gateway.mcp_policy.Policy.load(GATEWAY / "policy.json")
        session = gateway.mcp_policy.Session(TERMINAL, "claude", frozenset(), frozenset())
        service = gateway.mcp_http.Service("nudge", gateway.mcp_http.Upstream.parse(self.stubs["nudge"].url),
                                           policy, session)
        path = self.scratch / "one-slot.sock"
        server = gateway.mcp_http.make_server(str(path), service, max_concurrent=1)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        saved = gateway.mcp_http.CLIENT_DEADLINE_S
        gateway.mcp_http.CLIENT_DEADLINE_S = 1.0
        dripper = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            dripper.connect(str(path))
            dripper.sendall(b"POST /mcp HTTP/1.1\r\n")
            answer = b""
            started = time.monotonic()
            while time.monotonic() - started < 4:
                try:
                    dripper.sendall(b"X")
                except OSError:
                    break
                dripper.settimeout(0.2)
                try:
                    chunk = dripper.recv(64)
                except socket.timeout:
                    continue
                answer += chunk
                if not chunk or answer:
                    break
            self.assertLess(time.monotonic() - started, 2.5)
            self.assertTrue(answer == b"" or answer.startswith(b"HTTP/1.1 408"), answer)
        finally:
            gateway.mcp_http.CLIENT_DEADLINE_S = saved
            dripper.close()
        conn = UnixHTTPConnection(str(path))
        conn.request("POST", "/mcp", body=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}))
        self.assertEqual(conn.getresponse().status, 200)   # the slot came back
        conn.close()
        server.shutdown()
        server.server_close()

    def test_slow_resolver_and_dripping_proxy_client_are_bounded(self):
        allowlist = gateway.connect_proxy.Allowlist({"allow": [{"exact": "slow.example.com"}]})

        def slow(host):
            time.sleep(3)
            return ["93.184.216.34"]
        saved = gateway.connect_proxy.RESOLVE_DEADLINE_S
        gateway.connect_proxy.RESOLVE_DEADLINE_S = 0.5
        try:
            path = self.scratch / "slow-proxy.sock"
            server = gateway.connect_proxy.make_server(str(path), "t", allowlist, resolve=slow,
                                                       connect=lambda ip, port: self.fail("dialled"))
        finally:
            gateway.connect_proxy.RESOLVE_DEADLINE_S = saved
        threading.Thread(target=server.serve_forever, daemon=True).start()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(str(path))
        started = time.monotonic()
        s.sendall(b"CONNECT slow.example.com:443 HTTP/1.1\r\n\r\n")
        self.assertTrue(s.recv(64).startswith(b"HTTP/1.1 504"))
        self.assertLess(time.monotonic() - started, 1.5)
        s.close()
        server.shutdown()
        server.server_close()

        saved = gateway.connect_proxy.HEAD_DEADLINE_S
        gateway.connect_proxy.HEAD_DEADLINE_S = 1.0
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(str(self.sock_dir / "proxy.sock"))
            started = time.monotonic()
            reply = b""
            for ch in b"CONNECT api.example.com:443 HTTP/1.1\r\n":
                try:
                    s.sendall(bytes([ch]))
                except OSError:
                    break
                s.settimeout(0.2)
                try:
                    reply = s.recv(64)
                    break
                except socket.timeout:
                    continue
            self.assertTrue(reply.startswith(b"HTTP/1.1 408"), reply)
            self.assertLess(time.monotonic() - started, 2)
            s.close()
        finally:
            gateway.connect_proxy.HEAD_DEADLINE_S = saved
        self.assertEqual(self.connects, [])

    # ── framing (#2086) ──
    def test_chunk_sizes_are_checked_before_any_read(self):
        http_io = gateway.mcp_http.http_io

        class FakeReader:
            def __init__(self, size_line):
                self.size_line, self.requested = size_line, []

            def read_until(self, delim, limit):
                return self.size_line

            def read_upto(self, n):
                self.requested.append(n)
                return b"x" * min(n, 10)

            read_exact = read_upto
        cases = {b"10000000": "body_too_large", b"-5": "bad_chunk", b"+5": "bad_chunk",
                 b"0x10": "bad_chunk", b"1" * 17: "bad_chunk", b"": "bad_chunk"}
        for size_line, code in cases.items():
            with self.subTest(size_line=size_line):
                reader = FakeReader(size_line)
                with self.assertRaises(http_io.HTTPError) as caught:
                    list(http_io.iter_body(reader, {"transfer-encoding": "chunked"}, 8 * 1024 * 1024))
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(reader.requested, [])

    def raw_reply(self, stub, pieces, hold=0.0, method="tools/call"):
        """Answer the next matching request with raw bytes sent in pieces."""
        def answer(handler, body):
            if body.get("method") != method:
                return False
            try:
                for piece in pieces(body):
                    handler.wfile.write(piece)
                    handler.wfile.flush()
                    time.sleep(0.05)
                time.sleep(hold)
            except OSError:
                pass
            handler.close_connection = True
            return True
        stub.custom = answer

    @staticmethod
    def chunk(data):
        return f"{len(data):x}\r\n".encode() + data + b"\r\n"

    def test_oversized_lengths_refused_and_server_keeps_serving(self):
        huge = "9" * 5000
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(str(self.sock_dir / "nudge.sock"))
        s.sendall(f"POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: {huge}\r\n\r\n".encode())
        self.assertTrue(s.recv(64).startswith(b"HTTP/1.1 400"))
        s.close()
        nudge = self.stubs["nudge"]
        for label, head in (
                ("upstream content-length", f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                            f"Content-Length: {huge}\r\n\r\n".encode()),
                ("upstream chunk size", b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                                        b"Transfer-Encoding: chunked\r\n\r\n10000000\r\n")):
            with self.subTest(label):
                self.raw_reply(nudge, lambda body, head=head: [head])
                started = time.monotonic()
                body = self.call("nudge", "nudge_list_components", {})
                self.assertEqual(body["error"]["code"], -32002)
                self.assertLess(time.monotonic() - started, 2)
        nudge.custom = None
        self.assertIn("result", self.call("nudge", "nudge_list_components", {}))

    def test_sse_parsing_ignores_read_boundaries(self):
        SSE = gateway.mcp_http._SSE
        event = b'data: {"jsonrpc":"2.0","id":1,"result":{}}'
        for ending in (b"\r\n", b"\n", b"\r"):
            # One event whose JSON spans two data lines: a line end read as
            # a blank line would split it into two broken events.
            stream = (b": hi" + ending + b'data: {"jsonrpc":"2.0",' + ending
                      + b'data: "id":1,"result":{}}' + ending + ending)
            for cut in range(len(stream) + 1):
                for cut2 in range(cut, len(stream) + 1, 7):
                    with self.subTest(ending=ending, cut=cut, cut2=cut2):
                        parser = SSE()
                        got = parser.feed(stream[:cut]) + parser.feed(stream[cut:cut2]) + parser.feed(stream[cut2:])
                        self.assertEqual(got, [{"jsonrpc": "2.0", "id": 1, "result": {}}])
        # One byte per read: CR, then the LF completing it, then the blank line's LF.
        parser = SSE()
        got = []
        for byte in event + b"\r\n\n":
            got += parser.feed(bytes([byte]))
        self.assertEqual(got, [{"jsonrpc": "2.0", "id": 1, "result": {}}])

    def test_split_crlf_and_unfinished_chunk_answer_before_stream_end(self):
        minerva = self.stubs["minerva"]
        head = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

        def data_line(body):
            message = {"jsonrpc": "2.0", "id": body["id"], "result": text_result({"success": True})}
            return b"data: " + json.dumps(message).encode()

        # CRLF line endings split across HTTP chunks (and so across reads).
        self.raw_reply(minerva, lambda body: [head, self.chunk(data_line(body) + b"\r"),
                                              self.chunk(b"\n\r"), self.chunk(b"\n")], hold=5)
        started = time.monotonic()
        body = self.call("minerva", "minerva_terminal_notify", {"to": TARGET, "text": "see item"})
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(self.result_value(body)["success"])

        # A complete event inside a chunk whose declared size has not arrived yet.
        def unfinished(body):
            event = data_line(body) + b"\r\n\r\n"
            return [head, f"{len(event) + 500:x}\r\n".encode() + event]
        self.raw_reply(minerva, unfinished, hold=5)
        started = time.monotonic()
        body = self.call("minerva", "minerva_terminal_notify", {"to": TARGET, "text": "see item"})
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(self.result_value(body)["success"])

    # ── Minerva terminals ──
    def test_notify_targets_and_identity(self):
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": OTHER, "text": "see item"}))
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": "codex", "text": "see item"}))
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": TARGET, "text": "line one\nline two"}))
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": TARGET, "text": "x" * 401}))
        self.assertEqual(self.stubs["minerva"].records, [])
        self.stubs["minerva"].mode = "sse"
        body = self.call("minerva", "minerva_terminal_notify",
                         {"to": TARGET, "text": "see item", "from": "codex@codex-1", "reply_to": OTHER})
        self.assertTrue(self.result_value(body)["success"])
        self.assertEqual(self.stubs["minerva"].calls("minerva_terminal_notify"),
                         [{"to": TARGET, "text": "see item", "from": f"container:claude@{TERMINAL}",
                           "reply_to": TERMINAL}])

    def test_terminal_list_is_filtered_and_projected(self):
        body = self.call("minerva", "minerva_terminal_list", {})
        value = self.result_value(body)
        self.assertEqual(value["terminals"], [
            {"id": TERMINAL, "name": "me", "harness": "claude"},
            {"id": TARGET, "name": "codex-1", "harness": "codex"}])
        self.assertNotIn("private tab", json.dumps(body))
        self.assertNotIn("/home/", json.dumps(body))

    # ── proxy ──
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

    def test_proxy_tunnels_to_vetted_address_once(self):
        # A public IPv4-mapped IPv6 answer is dialled as the plain IPv4 address.
        for host, ip in (("api.example.com", "93.184.216.34"),
                         ("mappedpublic.example.com", "93.184.216.34"),
                         ("a.allowed.example.org", "2606:2800:220:1:248:1893:25c8:1946")):
            with self.subTest(host):
                self.connects.clear()
                s, reply = self.connect_via_proxy(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
                self.assertTrue(reply.startswith(b"HTTP/1.1 200"), reply)
                s.sendall(b"ping")
                self.assertEqual(s.recv(4), b"ping")
                s.close()
                self.assertEqual(self.connects, [(ip, 443)])

    def test_proxy_refusals_never_connect(self):
        cases = [
            b"CONNECT evil.example.net:443 HTTP/1.1\r\n\r\n",          # not allowlisted
            b"CONNECT allowed.example.org:443 HTTP/1.1\r\n\r\n",       # suffix is not the bare domain
            b"CONNECT evilallowed.example.org:443 HTTP/1.1\r\n\r\n",   # label boundary
            b"CONNECT api.example.com:80 HTTP/1.1\r\n\r\n",            # port
            b"CONNECT 93.184.216.34:443 HTTP/1.1\r\n\r\n",             # IP literal
            b"CONNECT [::1]:443 HTTP/1.1\r\n\r\n",                     # IPv6 literal
            b"CONNECT user@api.example.com:443 HTTP/1.1\r\n\r\n",      # userinfo
            b"CONNECT API.example.com:443 HTTP/1.1\r\n\r\n",           # not lowercase
            b"CONNECT api.example.com:443 HTTP/1.1\r\nX: a\x01b\r\n\r\n",  # control char
            b"GET http://api.example.com/ HTTP/1.1\r\n\r\n",           # not CONNECT
            b"CONNECT mixed.example.com:443 HTTP/1.1\r\n\r\n",         # one private candidate
            b"CONNECT mapped.example.com:443 HTTP/1.1\r\n\r\n",        # ::ffff:127.0.0.1
            b"CONNECT sixtofour.example.com:443 HTTP/1.1\r\n\r\n",     # 6to4
            b"CONNECT zero.example.com:443 HTTP/1.1\r\n\r\n",          # 0.0.0.0
            b"CONNECT cgnat.example.com:443 HTTP/1.1\r\n\r\n",         # 100.64/10
            b"CONNECT linklocal.example.com:443 HTTP/1.1\r\n\r\n",     # metadata address
            b"CONNECT empty.example.com:443 HTTP/1.1\r\n\r\n",         # no candidates
            b"CONNECT api.example.com:443 HTTP/1.1\r\n\r\n\x16\x03\x01",  # data before 200
            b"CONNECT api.example.com:443 HTTP/1.1\r\n" + b"X: y\r\n" * 2000 + b"\r\n",  # oversized head
        ]
        for head in cases:
            with self.subTest(head=head[:60]):
                s, reply = self.connect_via_proxy(head)
                s.close()
                self.assertRegex(reply, rb"^HTTP/1.1 (4|5)\d\d ")
        self.assertEqual(self.connects, [])

    def test_egress_entries_are_validated(self):
        for entry in ({"suffix": "example.org"}, {"exact": ".example.org"}, {"exact": "10.0.0.1"},
                      {"exact": "Example.org"}, {"suffix": ".org", "exact": "a.org"}):
            with self.subTest(entry=entry):
                with self.assertRaises(ValueError):
                    gateway.connect_proxy.Allowlist({"allow": [entry]})

    # ── startup safety ──
    def test_existing_socket_path_refuses_and_is_untouched(self):
        taken = self.scratch / "taken"
        taken.mkdir(mode=0o700)
        (taken / "docket.sock").write_text("sentinel\n")
        sessions = {"sessions": [{**self.sessions["sessions"][0], "terminal_id": "9999",
                                  "socket_dir": str(taken)}]}
        with self.assertRaises(ValueError):
            gateway.build_servers(self.config, sessions)
        self.assertEqual((taken / "docket.sock").read_text(), "sentinel\n")
        self.assertFalse((taken / "minerva.sock").exists())

    def test_open_socket_dir_refuses(self):
        loose = self.scratch / "loose"
        loose.mkdir(mode=0o755)
        loose.chmod(0o755)
        sessions = {"sessions": [{**self.sessions["sessions"][0], "socket_dir": str(loose)}]}
        with self.assertRaises(ValueError):
            gateway.build_servers(self.config, sessions)
        self.assertEqual(list(loose.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
