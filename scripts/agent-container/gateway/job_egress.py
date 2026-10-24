"""Two fixed, opaque Core TLS tunnels for one opt-in offline job.

The job sees only Unix sockets; it never receives a network interface or a
general CONNECT proxy. TLS still terminates at the original public server.
"""
import argparse
import os
import socket
import socketserver
import stat
import threading
from collections.abc import Callable
from pathlib import Path

import connect_proxy
import mcp_http

HOST = "www.turnrock.ai"
ROUTES = {"auth": 4040, "core": 27500}


class Tunnel(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        server = self.server
        try:
            upstream, _ = connect_proxy.open_tunnel(
                HOST, server.allowlist, server.resolve,
                lambda ip, _port: server.connect(ip, server.destination_port))
        except connect_proxy.Refused:
            return
        with upstream:
            connect_proxy.relay(self.request, upstream)


class Stop(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.server.stopping.set()


def build_servers(directory: Path, stopping: threading.Event,
                  resolve: Callable[[str], list[str]] = connect_proxy.system_resolve,
                  connect: Callable[[str, int], socket.socket] = connect_proxy.system_connect
                  ) -> list[socketserver.UnixStreamServer]:
    """Bind fresh sockets only in the invoking user's private directory."""
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Core egress needs an owned mode-0700 socket directory")
    paths = [directory / (name + ".sock") for name in [*ROUTES, "stop"]]
    if any(os.path.lexists(p) for p in paths):
        raise ValueError("Core egress socket already exists; refusing replacement")
    allowlist = connect_proxy.Allowlist({"allow": [{"exact": HOST}]})
    resolver = connect_proxy.BoundedResolver(resolve)
    servers = []
    try:
        for name, port in ROUTES.items():
            server = mcp_http.BoundedUnixServer(str(directory / (name + ".sock")), Tunnel, 16)
            server.allowlist, server.resolve, server.connect = allowlist, resolver, connect
            server.destination_port = port
            servers.append(server)
        server = mcp_http.BoundedUnixServer(str(directory / "stop.sock"), Stop, 1)
        server.stopping = stopping
        servers.append(server)
    except OSError:
        for server in servers:
            server.server_close()
        raise
    return servers


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sockets", type=Path, required=True)
    parser.add_argument("--seconds", type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 86430:
        parser.error("seconds must be 1-86430")
    stopping = threading.Event()
    servers = build_servers(args.sockets, stopping)
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    stopping.wait(args.seconds)
    for server in servers:
        server.server_close()


if __name__ == "__main__":
    main()
