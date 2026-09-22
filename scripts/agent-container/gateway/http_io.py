"""Minimal HTTP/1.1 reading and writing under a wall-clock deadline.

Socket timeouts only bound inactivity, so a peer dripping one byte at a time
could hold a connection (and a server slot) forever. Every read here takes a
Deadline and gives up when it passes, however the bytes arrive. Used for the
container-facing MCP server, the upstream MCP client and the CONNECT proxy's
request head.
"""
import re
import socket
import time

HEADER_LINE = re.compile(rb"[\x20-\x7e\t]*")
TOKEN = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
CHUNK_SIZE = re.compile(rb"[0-9A-Fa-f]{1,16}")
MAX_HEADER_LINES = 50
MAX_LENGTH_DIGITS = 12     # int() of a longer digit string can raise, and none is needed


class HTTPError(Exception):
    """A request or response that cannot be read: (status, fixed code)."""

    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def remaining(self):
        left = self.end - time.monotonic()
        if left <= 0:
            raise HTTPError(408, "deadline")
        return left


class Reader:
    """Buffered reads from a socket, each bounded by the shared deadline."""

    def __init__(self, sock, deadline, initial=b""):
        self.sock, self.deadline, self.buf = sock, deadline, initial

    def _fill(self, limit=65536):
        self.sock.settimeout(self.deadline.remaining())
        try:
            chunk = self.sock.recv(limit)
        except socket.timeout:
            raise HTTPError(408, "deadline") from None
        except OSError:
            raise HTTPError(400, "connection_error") from None
        if not chunk:
            raise EOFError
        self.buf += chunk

    def read_until(self, delim, limit):
        while delim not in self.buf:
            if len(self.buf) > limit:
                raise HTTPError(431, "head_too_large")
            try:
                self._fill()
            except EOFError:
                raise HTTPError(400, "closed_early") from None
        data, _, self.buf = self.buf.partition(delim)
        if len(data) > limit:
            raise HTTPError(431, "head_too_large")
        return data

    def read_exact(self, n):
        while len(self.buf) < n:
            try:
                self._fill()
            except EOFError:
                raise HTTPError(400, "closed_early") from None
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def read_upto(self, n):
        """At most n bytes: what is buffered, else the next chunk."""
        if not self.buf:
            try:
                self._fill()
            except EOFError:
                raise HTTPError(400, "closed_early") from None
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def read_some(self):
        """Buffered bytes, or the next chunk; b"" at end of stream."""
        if not self.buf:
            try:
                self._fill()
            except EOFError:
                return b""
        data, self.buf = self.buf, b""
        return data


def parse_head(head):
    """(start-line parts, headers keyed by lowercase name). Duplicate
    headers, non-printable bytes and malformed lines are refused."""
    lines = head.split(b"\r\n")
    if len(lines) - 1 > MAX_HEADER_LINES:
        raise HTTPError(431, "too_many_headers")
    headers = {}
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if not sep or not TOKEN.fullmatch(name) or not HEADER_LINE.fullmatch(value):
            raise HTTPError(400, "bad_header")
        key = name.decode("ascii").lower()
        if key in headers:
            raise HTTPError(400, "duplicate_header")
        headers[key] = value.strip().decode("ascii")
    if not HEADER_LINE.fullmatch(lines[0]):
        raise HTTPError(400, "bad_start_line")
    return lines[0].decode("ascii").split(" "), headers


def content_length(headers):
    """The Content-Length as an int, None when absent; malformed or absurdly
    long values raise before any conversion."""
    value = headers.get("content-length")
    if value is None:
        return None
    if not value.isdigit() or not value.isascii() or len(value) > MAX_LENGTH_DIGITS:
        raise HTTPError(400, "bad_length")
    return int(value)


def iter_body(reader, headers, limit):
    """Yield a message body piece by piece: Content-Length, chunked, or until
    close. The total is capped at limit bytes, and a declared size over the
    remaining budget is refused before anything is read. Pieces are yielded
    as they arrive, so a caller can act on a complete message inside a chunk
    that has not finished."""
    total = 0

    def count(data):
        nonlocal total
        total += len(data)
        if total > limit:
            raise HTTPError(502, "body_too_large")
        return data

    encoding = headers.get("transfer-encoding", "").lower()
    if encoding == "chunked":
        while True:
            size_line = reader.read_until(b"\r\n", 64).split(b";")[0].strip()
            if not CHUNK_SIZE.fullmatch(size_line):
                raise HTTPError(502, "bad_chunk")
            size = int(size_line, 16)
            if size == 0:
                return
            if size > limit - total:
                raise HTTPError(502, "body_too_large")
            while size:
                piece = reader.read_upto(size)
                size -= len(piece)
                yield count(piece)
            if reader.read_exact(2) != b"\r\n":
                raise HTTPError(502, "bad_chunk")
    elif encoding:
        raise HTTPError(502, "unsupported_encoding")
    elif "content-length" in headers:
        remaining = content_length(headers)
        if remaining > limit:
            raise HTTPError(502, "body_too_large")
        while remaining:
            piece = reader.read_upto(remaining)
            remaining -= len(piece)
            yield count(piece)
    else:
        while data := reader.read_some():
            yield count(data)


def response_bytes(status, reason, headers, body=b""):
    lines = [f"HTTP/1.1 {status} {reason}"]
    lines += [f"{k}: {v}" for k, v in headers.items()]
    lines += [f"Content-Length: {len(body)}", "Connection: close", "", ""]
    return "\r\n".join(lines).encode("ascii") + body
