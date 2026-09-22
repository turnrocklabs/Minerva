#!/usr/bin/env python3
"""Agent-container gateway transport against stub upstreams: JSON-RPC envelope,
HTTP framing, wall-clock deadlines, SSE, the CONNECT proxy and startup
safety (fixtures in agent_gateway_fixtures.py).
"""
import json
import socket
import threading
import time
import unittest

from agent_gateway_fixtures import (  # noqa: E402
    GATEWAY, GatewayCase, SESSION, TARGET, UnixHTTPConnection, gateway, text_result)


class Test(GatewayCase):
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
        session = gateway.mcp_policy.Session(SESSION, "claude", frozenset(), lambda: gateway.mcp_policy.UNATTACHED)
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
                    # The gateway answered and closed between our reads; the
                    # answer is still waiting in the socket.
                    s.settimeout(1)
                    reply = s.recv(64)
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

    def test_existing_socket_path_refuses_and_is_untouched(self):
        taken = self.scratch / "taken"
        taken.mkdir(mode=0o700)
        (taken / "docket.sock").write_text("sentinel\n")
        sessions = {"sessions": [{**self.sessions["sessions"][0], "name": "other",
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
