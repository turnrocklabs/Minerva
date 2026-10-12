"""Disposable one-shot launcher and real HTTP child for the M1 boundary tests."""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import sys
import time
from pathlib import Path


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, _format: str, *args: object) -> None:
        return

    def do_POST(self) -> None:
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "id" not in request:
            self.send_response(202)
            self.end_headers()
            return
        method = request.get("method")
        result: dict[str, object] = {}
        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "docket", "version": "fixture"}}
        elif method == "tools/list":
            tools = json.loads(Path(sys.argv[3]).read_text())
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in tools]}
        response: dict[str, object] = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        if method == "server/discover":
            response = {"jsonrpc": "2.0", "id": request["id"],
                        "error": {"code": -32601, "message": "Method not found"}}
        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    mode, profile_text = sys.argv[1:3]
    profile = Path(profile_text)
    if not profile.is_absolute() or not str(profile).startswith(os.environ["MINERVA_TEST_PROFILE_ROOT"] + "/"):
        raise RuntimeError("private test profile required")
    profile.mkdir(parents=True, exist_ok=True)
    if mode == "serve":
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        record = {"pid": os.getpid(), "version": "fixture", "protocol_version": "2025-03-26",
                  "endpoint": {"host": "127.0.0.1", "port": server.server_port},
                  "profile": str(profile), "started_at": "fixture"}
        (profile / "instance.json").write_text(json.dumps(record))
        server.serve_forever()
        return 0
    with (profile / "starts.txt").open("a") as count:
        count.write("start\n")
    if mode == "fail":
        print(json.dumps({"status": "failed", "reason": "fixture startup refused"}), flush=True)
        return 2
    subprocess.Popen([sys.executable, __file__, "serve", profile_text, sys.argv[3]],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    deadline = time.monotonic() + 5
    while not (profile / "instance.json").is_file():
        if time.monotonic() >= deadline:
            raise RuntimeError("fixture did not register")
        time.sleep(.01)
    if mode == "slow":
        time.sleep(.5)
    record = json.loads((profile / "instance.json").read_text())
    print(json.dumps({"status": "spawned", "pid": record["pid"],
                      "endpoint": f"127.0.0.1:{record['endpoint']['port']}",
                      "version": record["version"]}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
