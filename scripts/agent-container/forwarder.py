#!/usr/bin/env python3
"""In-container port forwarder: 127.0.0.1:<port> -> the gateway's Unix sockets.

The dev container has no network, so the harness reaches the host services
and the egress proxy through the session's socket directory (mounted at
/run/minerva-agent). Harnesses speak TCP, so this relays each loopback port
to its socket unchanged; all filtering happens in the gateway, outside the
container. Started (and restarted if it ever exits) by minerva-session.

Usage: forwarder.py [--ready FILE] SOCKET_DIR PORT=NAME [PORT=NAME ...]
Every port is bound before FILE is created; if any bind fails the forwarder
exits non-zero without creating it.
"""
import os
import socket
import sys
import threading
import time

MAX_CONNECTIONS = 64
_slots = threading.BoundedSemaphore(MAX_CONNECTIONS)


def pipe(src, dst):
    try:
        while data := src.recv(65536):
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve_one(client, path):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(path)
    except OSError:
        upstream.close()
        client.close()
        _slots.release()
        return
    back = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
    back.start()
    pipe(client, upstream)
    back.join()
    client.close()
    upstream.close()
    _slots.release()


def accept_loop(server, path):
    while True:
        try:
            client, _ = server.accept()
        except OSError:           # e.g. out of file descriptors: back off, keep serving
            time.sleep(0.1)
            continue
        if not _slots.acquire(blocking=False):
            client.close()
            continue
        threading.Thread(target=serve_one, args=(client, path), daemon=True).start()


def main(argv):
    ready = None
    if argv[:1] == ["--ready"]:
        ready, argv = argv[1], argv[2:]
    if len(argv) < 2:
        sys.exit(__doc__)
    sock_dir, servers = argv[0], []
    for pair in argv[1:]:
        port, _, name = pair.partition("=")
        if not port.isdigit() or not name.isidentifier():
            sys.exit(f"forwarder: bad route {pair!r}")
        try:
            servers.append((socket.create_server(("127.0.0.1", int(port))),
                            os.path.join(sock_dir, f"{name}.sock")))
        except OSError as exc:
            sys.exit(f"forwarder: cannot listen on 127.0.0.1:{port}: {exc.strerror}")
    threads = [threading.Thread(target=accept_loop, args=pair, daemon=True) for pair in servers]
    for t in threads:
        t.start()
    if ready:
        with open(ready, "x"):
            pass
    for t in threads:
        t.join()


if __name__ == "__main__":
    main(sys.argv[1:])
