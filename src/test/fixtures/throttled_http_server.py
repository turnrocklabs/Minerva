#!/usr/bin/env python3
"""Serve one file slowly, with the misbehaviours a plugin download meets.

    throttled_http_server.py FILE PORT [--rate BYTES_PER_S] [--drop-after N]
                             [--stall-after N] [--no-range]

Every GET returns FILE at --rate. --drop-after closes the FIRST response's
connection after N body bytes; later requests are served whole. --stall-after
stops sending after N bytes and holds the connection open; every later
response stalls before its first byte, as a dead server does. --no-range ignores
Range headers and always answers 200 with the whole file, as a server that
cannot resume does. Range requests are otherwise answered with 206.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import re
import time

CHUNK = 16 * 1024


def main():
    p = argparse.ArgumentParser()
    p.add_argument("file")
    p.add_argument("port", type=int)
    p.add_argument("--rate", type=int, default=0, help="bytes per second; 0 = unthrottled")
    p.add_argument("--drop-after", type=int, default=-1)
    p.add_argument("--stall-after", type=int, default=-1)
    p.add_argument("--no-range", action="store_true")
    args = p.parse_args()
    data = open(args.file, "rb").read()
    dropped, stalled = [], []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            start = 0
            m = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range", ""))
            if m and not args.no_range:
                start = int(m.group(1))
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(data) - start))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            sent, began = 0, time.monotonic()
            while start + sent < len(data):
                if stalled or (args.stall_after >= 0 and sent >= args.stall_after):
                    stalled.append(True)
                    time.sleep(3600)
                if args.drop_after >= 0 and not dropped and sent >= args.drop_after:
                    dropped.append(True)
                    self.close_connection = True
                    return
                piece = data[start + sent:start + sent + CHUNK]
                self.wfile.write(piece)
                self.wfile.flush()
                sent += len(piece)
                if args.rate:
                    time.sleep(max(0.0, began + sent / args.rate - time.monotonic()))

        def log_message(self, *_):
            pass

    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
