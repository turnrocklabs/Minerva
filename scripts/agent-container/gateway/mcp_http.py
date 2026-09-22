"""The gateway's MCP transport: one Unix-socket HTTP server per upstream
service per session, forwarding what mcp_policy allows to the host upstream.

Container side: POST /mcp with one JSON-RPC message, answered with one JSON
body (never SSE; GET streams and DELETE are refused). Upstream side: the
request goes to a fixed http://127.0.0.1:<port>/<path>; the answer may be
JSON or an SSE stream (Minerva streams tool calls). SSE is parsed as it
arrives and the connection is closed as soon as the response with the
matching id is complete, so an upstream that keeps its stream open cannot
hold the request. Every read on both sides runs under a wall-clock deadline
(http_io), so a slow or dripping peer releases its server slot on time.

Logs carry fixed codes and allowlisted names only, never client-chosen
strings, arguments, upstream text or content.
"""
from dataclasses import dataclass
import itertools
import json
import re
import socket
import socketserver
import sys
import threading
import time
from urllib.parse import urlsplit

import http_io
import mcp_policy
import strict_json

MAX_REQUEST_BODY = 1024 * 1024
MAX_UPSTREAM_BODY = 8 * 1024 * 1024
MAX_HEAD = 8 * 1024
CLIENT_DEADLINE_S = 30       # whole request: head and body
UPSTREAM_DEADLINE_S = 60     # whole upstream exchange; above Minerva's 20 s notify wait
MAX_CONCURRENT = 16
SESSION_HEADER = re.compile(r"[\x21-\x7e]{1,128}")
PROTOCOL_HEADER = re.compile(r"[0-9A-Za-z.-]{1,32}")
DENIED = -32001
UPSTREAM_FAILED = -32002


class UpstreamError(Exception):
    """The upstream answered with something the gateway will not relay.
    The message is a fixed code."""


@dataclass(frozen=True)
class Upstream:
    host: str
    port: int
    path: str

    @classmethod
    def parse(cls, url):
        parts = urlsplit(url)
        if parts.scheme != "http" or parts.hostname != "127.0.0.1" or not parts.port \
                or parts.query or parts.fragment or parts.username:
            raise ValueError(f"upstream must be http://127.0.0.1:<port>/<path>: {url}")
        return cls(parts.hostname, parts.port, parts.path or "/")


def log(event):
    """One JSON line per decision."""
    event["ts"] = round(time.time(), 3)
    sys.stderr.write(json.dumps(event, sort_keys=True) + "\n")
    sys.stderr.flush()


class _SSE:
    """Incremental SSE parser yielding complete JSON-RPC messages. Lines end
    in CRLF, LF or CR (the SSE grammar), and how the bytes were split across
    reads never changes the result: a CR ends its line at once, and an LF
    arriving next (the rest of a CRLF, maybe in a later read) is skipped."""

    def __init__(self):
        self.pending, self.data, self.after_cr = b"", [], False

    def _lines(self):
        while True:
            if self.after_cr and self.pending:
                if self.pending[:1] == b"\n":
                    self.pending = self.pending[1:]
                self.after_cr = False
            ends = [i for i in (self.pending.find(b"\r"), self.pending.find(b"\n")) if i >= 0]
            if not ends:
                return
            i = min(ends)
            self.after_cr = self.pending[i:i + 1] == b"\r"
            line, self.pending = self.pending[:i], self.pending[i + 1:]
            yield line

    def feed(self, chunk):
        self.pending += chunk
        messages = []
        for line in self._lines():
            if line == b"":
                if self.data:
                    messages.append(strict_json.loads(b"\n".join(self.data), MAX_UPSTREAM_BODY))
                    self.data = []
            elif line.startswith(b"data:"):
                self.data.append(line[5:].removeprefix(b" "))
            # comments (":") and other fields are ignored
        return messages


def _matches(reply, message):
    return isinstance(reply, dict) and reply.get("jsonrpc") == "2.0" \
        and reply.get("id") == message["id"] and (("result" in reply) != ("error" in reply))


def call_upstream(upstream, message, headers, deadline_s=None):
    """POST one JSON-RPC message upstream. Returns (response message or None
    for a notification, upstream session id or None)."""
    deadline = http_io.Deadline(deadline_s or UPSTREAM_DEADLINE_S)
    body = strict_json.dumps(message)
    head = [f"POST {upstream.path} HTTP/1.1", f"Host: {upstream.host}:{upstream.port}",
            "Content-Type: application/json", "Accept: application/json, text/event-stream",
            f"Content-Length: {len(body)}", "Connection: close"]
    head += [f"{k}: {v}" for k, v in headers.items()]
    try:
        with socket.create_connection((upstream.host, upstream.port),
                                      timeout=min(5, deadline.remaining())) as sock:
            sock.settimeout(deadline.remaining())
            sock.sendall("\r\n".join(head + ["", ""]).encode("ascii") + body)
            reader = http_io.Reader(sock, deadline)
            start, resp_headers = http_io.parse_head(reader.read_until(b"\r\n\r\n", MAX_HEAD))
            if len(start) < 2 or not start[0].startswith("HTTP/1.") or not start[1].isdigit():
                raise UpstreamError("bad_status_line")
            status = int(start[1])
            session = resp_headers.get("mcp-session-id")
            if session is not None and not SESSION_HEADER.fullmatch(session):
                raise UpstreamError("bad_session_header")
            if "id" not in message:
                if status not in (200, 202, 204):
                    raise UpstreamError("bad_status")
                return None, session
            if status != 200:
                raise UpstreamError("bad_status")
            ctype = resp_headers.get("content-type", "").split(";")[0].strip().lower()
            chunks = http_io.iter_body(reader, resp_headers, MAX_UPSTREAM_BODY)
            if ctype == "text/event-stream":
                sse = _SSE()
                for chunk in chunks:
                    for reply in sse.feed(chunk):
                        if _matches(reply, message):
                            return reply, session  # closing drops the rest of the stream
                raise UpstreamError("no_matching_response")
            if ctype == "application/json":
                reply = strict_json.loads(b"".join(chunks), MAX_UPSTREAM_BODY)
                if _matches(reply, message):
                    return reply, session
                raise UpstreamError("no_matching_response")
            raise UpstreamError("bad_content_type")
    except strict_json.StrictJSONError:
        raise UpstreamError("bad_body") from None
    except http_io.HTTPError as exc:
        raise UpstreamError(f"http_{exc.code}") from None
    except OSError:
        raise UpstreamError("unreachable") from None


class Service:
    """One upstream as seen by one session."""
    _lookup_ids = itertools.count(1)

    def __init__(self, name, upstream, policy, session):
        self.name, self.upstream, self.policy, self.session = name, upstream, policy, session

    def handle(self, raw, headers):
        """Returns (http status, JSON body or None, response headers)."""
        try:
            msg = strict_json.loads(raw, MAX_REQUEST_BODY)
        except strict_json.StrictJSONError as exc:
            self._log("reject", "parse_error")
            return 200, _error(None, -32700, f"parse error: {exc}"), {}
        try:
            req = mcp_policy.parse_request(msg)
        except mcp_policy.ProtocolError as exc:
            self._log("reject", exc.code)
            return 200, _error(mcp_policy.request_id(msg), exc.rpc_code, str(exc)), {}

        if req.is_notification:
            # Only initialized is meaningful upstream; others are dropped here.
            if req.method == "notifications/initialized":
                try:
                    call_upstream(self.upstream, _message(req), headers)
                except UpstreamError as exc:
                    self._log("upstream_error", str(exc), method=req.method)
                    return 502, None, {}
            return 202, None, {}

        tool, forward = None, _message(req)
        if req.method == "tools/call":
            tool = req.params["name"]
            try:
                call = mcp_policy.plan_call(self.policy, self.name, self.session, tool,
                                            req.params.get("arguments", {}),
                                            lambda t, a: self._lookup(t, a, headers))
            except mcp_policy.Deny as exc:
                self._log("deny", exc.code, method=req.method, tool=tool)
                return 200, _error(req.id, DENIED, f"gateway denied: {exc}"), {}
            forward["params"] = {"name": tool, "arguments": call.arguments}
            shape = call.shape_result
        elif req.method == "tools/list":
            shape = lambda result: mcp_policy.shape_tools_list(self.policy, self.name, result)
        elif req.method == "initialize":
            shape = mcp_policy.shape_initialize
        else:
            shape = mcp_policy.shape_ping

        try:
            reply, session = call_upstream(self.upstream, forward, headers)
        except UpstreamError as exc:
            self._log("upstream_error", str(exc), method=req.method, tool=tool)
            return 200, _error(req.id, UPSTREAM_FAILED, "upstream request failed"), {}
        if "error" in reply:
            # JSON-RPC errors carry upstream text and data: never relayed.
            self._log("upstream_error", "jsonrpc_error", method=req.method, tool=tool)
            return 200, _error(req.id, UPSTREAM_FAILED, "upstream request failed"), {}
        try:
            result = shape(reply["result"])
        except mcp_policy.Deny as exc:
            self._log("deny_result", exc.code, method=req.method, tool=tool)
            return 200, _error(req.id, DENIED, f"gateway denied: {exc.code}"), {}
        self._log("allow", "", method=req.method, tool=tool)
        return 200, {"jsonrpc": "2.0", "id": req.id, "result": result}, \
            ({"Mcp-Session-Id": session} if session else {})

    def _lookup(self, tool, arguments, headers):
        """A read-only tools/call the policy needs before deciding."""
        message = {"jsonrpc": "2.0", "id": f"gateway-lookup-{next(self._lookup_ids)}",
                   "method": "tools/call", "params": {"name": tool, "arguments": arguments}}
        reply, _ = call_upstream(self.upstream, message, headers)
        if "result" not in reply:
            raise mcp_policy.Deny("lookup_failed")
        return reply["result"]

    def _log(self, action, code, **fields):
        if fields.get("tool") is not None and fields["tool"] not in self.policy.tools(self.name):
            fields["tool"] = "(unlisted)"   # never persist a client-chosen name
        log({"kind": "mcp", "service": self.name, "session": self.session.terminal_id,
             "action": action, "code": code, **fields})


def _message(req):
    msg = {"jsonrpc": "2.0", "method": req.method}
    if req.params:
        msg["params"] = req.params
    if not req.is_notification:
        msg["id"] = req.id
    return msg


def _error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


REASONS = {200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
           405: "Method Not Allowed", 408: "Request Timeout", 411: "Length Required",
           413: "Payload Too Large", 431: "Request Header Fields Too Large", 502: "Bad Gateway",
           503: "Service Unavailable"}


def _respond(sock, status, body=None, headers=None):
    headers = dict(headers or {})
    data = b""
    if body is not None:
        data = strict_json.dumps(body)
        headers["Content-Type"] = "application/json"
    if status == 405:
        headers["Allow"] = "POST"
    try:
        sock.sendall(http_io.response_bytes(status, REASONS.get(status, "Error"), headers, data))
    except OSError:
        pass


def read_request(sock, service):
    """Read and answer one request; everything is refused unless it is a
    well-formed POST /mcp read within CLIENT_DEADLINE_S."""
    reader = http_io.Reader(sock, http_io.Deadline(CLIENT_DEADLINE_S))
    try:
        start, headers = http_io.parse_head(reader.read_until(b"\r\n\r\n", MAX_HEAD))
    except http_io.HTTPError as exc:
        return _respond(sock, exc.status)
    if len(start) != 3 or start[2] != "HTTP/1.1":
        return _respond(sock, 400)
    method, target = start[0], start[1]
    if method != "POST":
        return _respond(sock, 405)
    if target not in ("/mcp", "/"):
        return _respond(sock, 404)
    if "origin" in headers:
        return _respond(sock, 403)
    try:
        length = http_io.content_length(headers)
    except http_io.HTTPError as exc:
        return _respond(sock, exc.status)
    if "transfer-encoding" in headers or length is None:
        return _respond(sock, 411)
    if length > MAX_REQUEST_BODY:
        return _respond(sock, 413)
    forward = {}
    for name, pattern, out in (("mcp-session-id", SESSION_HEADER, "Mcp-Session-Id"),
                               ("mcp-protocol-version", PROTOCOL_HEADER, "MCP-Protocol-Version")):
        if name in headers:
            if not pattern.fullmatch(headers[name]):
                return _respond(sock, 400)
            forward[out] = headers[name]
    try:
        raw = reader.read_exact(length)
    except http_io.HTTPError as exc:
        return _respond(sock, exc.status)
    status, body, extra = service.handle(raw, forward)
    _respond(sock, status, body, extra)


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        read_request(self.request, self.server.service)


class BoundedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """A threading Unix-socket server that refuses work beyond max_concurrent
    instead of queueing it without bound."""
    daemon_threads = True

    def __init__(self, path, handler, max_concurrent=MAX_CONCURRENT):
        self._slots = threading.BoundedSemaphore(max_concurrent)
        super().__init__(path, handler)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.refuse(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()

    def refuse(self, request):
        _respond(request, 503)
        self.shutdown_request(request)


def make_server(path, service, max_concurrent=MAX_CONCURRENT):
    server = BoundedUnixServer(path, _Handler, max_concurrent)
    server.service = service
    return server
