"""The gateway's egress: an HTTPS CONNECT proxy on a Unix socket.

Only `CONNECT <hostname>:443` is accepted. The name is resolved
once; EVERY candidate address must be public (loopback, private, link-local,
CGNAT, multicast, reserved, unspecified and IPv6 forms that embed or translate
IPv4 all refuse), and the proxy then connects once to a vetted address. No
second lookup happens, so a rebinding name cannot swap in a host address.
The request head is read under a wall-clock deadline, and resolution runs in
a small fixed pool with its own deadline, so neither a dripping client nor a
hanging resolver holds a slot or grows threads without bound.

What this does not do: TLS is opaque, so paths, redirects and anything a
client reaches inside an allowed tunnel are the remote host's business. Any
allowed destination can receive data; this limits WHERE, not WHAT.
"""
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
import ipaddress
import re
import selectors
import socket
import socketserver
import threading
import time

import http_io
import mcp_http
import strict_json

MAX_HEAD = 8 * 1024
HEAD_DEADLINE_S = 10
RESOLVE_DEADLINE_S = 5
RESOLVER_THREADS = 4
CONNECT_TIMEOUT_S = 10
IDLE_TIMEOUT_S = 300
MAX_TUNNEL_S = 4 * 3600
MAX_TUNNELS = 32
LABEL = re.compile(r"(?!-)[a-z0-9-]{1,63}(?<!-)")
NAT64 = ipaddress.ip_network("64:ff9b::/96")
NAT64_LOCAL = ipaddress.ip_network("64:ff9b:1::/48")


class Refused(Exception):
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status


class Allowlist:
    """Public-internet mode or destination names from egress.json. Suffixes
    start with '.', so '.example.com' matches 'a.example.com' but neither
    'example.com' nor 'evilexample.com'."""

    def __init__(self, data):
        self.public_internet = data.get("public_internet", False)
        if not isinstance(self.public_internet, bool):
            raise ValueError("public_internet must be a boolean")
        self.exact, self.suffixes = set(), []
        for entry in data.get("allow", []):
            if set(entry) == {"exact"} and valid_hostname(entry["exact"]):
                self.exact.add(entry["exact"])
            elif set(entry) == {"suffix"} and entry["suffix"].startswith(".") \
                    and valid_hostname(entry["suffix"][1:]):
                self.suffixes.append(entry["suffix"])
            else:
                raise ValueError(f"bad egress entry: {entry}")

    @classmethod
    def load(cls, path):
        with open(path, "rb") as f:
            return cls(strict_json.loads(f.read(), 1024 * 1024))

    def allows(self, host):
        return valid_hostname(host) and (self.public_internet or host in self.exact
                                        or any(host.endswith(s) for s in self.suffixes))


def valid_hostname(host):
    """A lowercase DNS name of 2+ labels whose last label is not numeric,
    so no IPv4 literal, IPv6 literal, userinfo or percent form passes."""
    labels = host.split(".")
    return len(host) <= 253 and len(labels) >= 2 and all(LABEL.fullmatch(l) for l in labels) \
        and not labels[-1].isdigit()


def public_address(text):
    """The address as an ip_address when it is safe to connect to, else None."""
    if "%" in text:  # scoped IPv6
        return None
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    if ip.version == 6:
        if ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        elif ip.sixtofour is not None or ip.teredo is not None \
                or ip in NAT64 or ip in NAT64_LOCAL or int(ip) >> 32 == 0:
            return None  # translated/embedded IPv4 and IPv4-compatible forms
    if not ip.is_global or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
        return None
    return ip


def system_resolve(host):
    return [info[4][0] for info in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)]


def system_connect(ip, port):
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(CONNECT_TIMEOUT_S)
    try:
        sock.connect((ip, port))
    except OSError:
        sock.close()
        raise
    return sock


class BoundedResolver:
    """Runs a blocking resolver in a fixed pool with a deadline. A lookup
    that hangs keeps its pool thread until the OS gives up, but the pool never
    grows and at most RESOLVER_THREADS lookups are pending; beyond that,
    requests are refused rather than queued."""

    def __init__(self, resolve, threads=RESOLVER_THREADS, deadline_s=None):
        self.resolve, self.deadline_s = resolve, deadline_s or RESOLVE_DEADLINE_S
        self.pool = ThreadPoolExecutor(max_workers=threads, thread_name_prefix="resolve")
        self.slots = threading.BoundedSemaphore(threads)

    def __call__(self, host):
        if not self.slots.acquire(blocking=False):
            raise Refused(503, "resolver_busy")
        future = self.pool.submit(self.resolve, host)
        future.add_done_callback(lambda _: self.slots.release())
        try:
            return future.result(timeout=self.deadline_s)
        except FutureTimeout:
            raise Refused(504, "resolve_timeout") from None
        except OSError:
            raise Refused(502, "resolve_failed") from None


def read_connect(sock):
    """Returns the hostname of a well-formed CONNECT host:443 request, read
    within HEAD_DEADLINE_S."""
    reader = http_io.Reader(sock, http_io.Deadline(HEAD_DEADLINE_S))
    try:
        start, _ = http_io.parse_head(reader.read_until(b"\r\n\r\n", MAX_HEAD))
    except http_io.HTTPError as exc:
        raise Refused(exc.status, exc.code) from None
    if reader.buf:
        raise Refused(400, "data_before_tunnel")
    if len(start) != 3 or start[0] != "CONNECT" or start[2] not in ("HTTP/1.1", "HTTP/1.0"):
        raise Refused(405, "not_connect")
    host, sep, port = start[1].rpartition(":")
    if not sep or port != "443":
        raise Refused(403, "port_not_allowed")
    if not valid_hostname(host):
        raise Refused(403, "not_a_hostname")
    return host


def open_tunnel(host, allowlist, resolve, connect):
    """Resolve once, vet every candidate, connect once. Returns (socket, ip)."""
    if not allowlist.allows(host):
        raise Refused(403, "not_allowlisted")
    candidates = resolve(host)
    if not isinstance(candidates, list) or not candidates:
        raise Refused(502, "resolve_empty")
    vetted = [public_address(c) if isinstance(c, str) else None for c in candidates]
    if any(ip is None for ip in vetted):
        raise Refused(403, "non_public_address")
    ip = str(vetted[0])
    try:
        return connect(ip, 443), ip
    except OSError:
        raise Refused(502, "connect_failed") from None


def relay(client, upstream):
    """Copy both ways until either side closes, idles out or the tunnel ages out.
    Returns (bytes up, bytes down)."""
    counts = {client: 0, upstream: 0}
    peer = {client: upstream, upstream: client}
    started = time.monotonic()
    with selectors.DefaultSelector() as sel:
        for s in (client, upstream):
            s.setblocking(False)
            sel.register(s, selectors.EVENT_READ)
        while time.monotonic() - started < MAX_TUNNEL_S:
            ready = sel.select(IDLE_TIMEOUT_S)
            if not ready:
                break
            for key, _ in ready:
                try:
                    data = key.fileobj.recv(65536)
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    data = b""
                if not data:
                    return counts[client], counts[upstream]
                counts[key.fileobj] += len(data)
                target = peer[key.fileobj]
                target.setblocking(True)
                target.settimeout(IDLE_TIMEOUT_S)
                try:
                    target.sendall(data)
                except OSError:
                    return counts[client], counts[upstream]
                finally:
                    target.setblocking(False)
    return counts[client], counts[upstream]


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        server, client = self.server, self.request
        event = {"kind": "connect", "session": server.session_id}
        started = time.monotonic()
        try:
            host = read_connect(client)
            event["host"] = host
            upstream, ip = open_tunnel(host, server.allowlist, server.resolve, server.connect)
        except Refused as exc:
            event.update(action="deny", status=exc.status, code=str(exc))
            mcp_http.log(event)
            try:
                client.sendall(f"HTTP/1.1 {exc.status} Refused\r\nContent-Length: 0\r\n"
                               f"Connection: close\r\n\r\n".encode("ascii"))
            except OSError:
                pass
            return
        event.update(action="allow", ip=ip, status=200)
        try:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            up, down = relay(client, upstream)
            event.update(bytes_up=up, bytes_down=down)
        finally:
            upstream.close()
            event["secs"] = round(time.monotonic() - started, 1)
            mcp_http.log(event)


def make_server(path, session_id, allowlist, resolve=system_resolve, connect=system_connect,
                max_tunnels=MAX_TUNNELS):
    server = mcp_http.BoundedUnixServer(path, _Handler, max_tunnels)
    server.session_id, server.allowlist = session_id, allowlist
    server.resolve, server.connect = BoundedResolver(resolve), connect
    return server
