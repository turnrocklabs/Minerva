"""Public HTTP contract and falsifying checks for the packaged Sheets verifier."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("packaged_sheets", ROOT / "scripts/verify-packaged-sheets.py")
assert SPEC is not None and SPEC.loader is not None
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class PackagedSheetsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user = self.root / "user"
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        (self.user / "plugins/sheets").mkdir(parents=True)
        (self.user / "plugins/plugins.json").write_text(json.dumps({"plugins": [{
            "id": "sheets", "version": "0.1.2", "install_lane": "marketplace",
            "autostart": True, "auto_update": True}]}))
        (self.user / "plugins/sheets/manifest.json").write_text(json.dumps({
            "release_targets": ["macos-universal"]}))
        (self.fixture / "required-source.csv").write_bytes(PROBE.CSV_BYTES)
        self.inspected = {"version": "0.1.2", "status": {"running": True},
                          "tools": [{"name": name} for name in [
                              "minerva_sheets_create_editor", "minerva_sheets_get_data",
                              *[f"minerva_sheets_other_{i}" for i in range(28)]]]}
        self.replies: dict[str, dict[str, Any]] = {
            "minerva_sheets_get_data": {"data": PROBE.CSV_DATA},
            "minerva_plugin_remove": {"error": "Sheets is required by Minerva and cannot be removed"},
            "minerva_list_editors": {"editors": [{"name": "Required CSV provider"}, {"name": "Required native provider"}]},
        }
        self.calls: list[str] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                name = request["params"]["name"]
                owner.calls.append(name)
                arguments = request["params"]["arguments"]
                if name == "minerva_sheets_create_editor":
                    value = {"success": True, "editor_name": arguments["name"]}
                else:
                    value = owner.replies.get(name, {"success": True})
                body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {
                    "content": [{"type": "text", "text": json.dumps(value)}],
                    "isError": "error" in value}}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def close() -> None:
            server.shutdown()
            thread.join()
            server.server_close()

        self.addCleanup(close)
        self.port = server.server_port
        self.client = PROBE.MCPClient(server.server_port)

    def verify(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            PROBE.verify_provider(self.client, self.user, self.fixture, self.inspected, list(PROBE.REPOSITORIES))

    def test_public_http_provider_path_and_cleanup(self) -> None:
        self.verify()
        self.assertIn("minerva_sheets_get_data", self.calls)
        self.assertIn("minerva_plugin_remove", self.calls)
        self.assertEqual(self.calls[-3:], ["minerva_close_editor", "minerva_close_editor", "minerva_plugin_stop"])

    def test_broken_csv_reply_fails(self) -> None:
        self.replies["minerva_sheets_get_data"] = {"data": [["Name", "Value"], ["Zoë", 500], ["李", 7]]}
        with self.assertRaisesRegex(RuntimeError, "Unicode CSV"):
            self.verify()

    def test_changed_source_bytes_fail(self) -> None:
        (self.fixture / "required-source.csv").write_bytes(b"mutated")
        with self.assertRaisesRegex(RuntimeError, "Unicode CSV"):
            self.verify()

    def test_missing_tools_fail(self) -> None:
        self.inspected["tools"].pop()
        with self.assertRaisesRegex(RuntimeError, "30 tools"):
            self.verify()

    def test_removal_must_be_refused(self) -> None:
        self.replies["minerva_plugin_remove"] = {"success": True}
        with self.assertRaisesRegex(RuntimeError, "cannot be removed"):
            self.verify()

    def test_missing_second_editor_fails(self) -> None:
        self.replies["minerva_list_editors"] = {"editors": [{"name": "Required CSV provider"}]}
        with self.assertRaisesRegex(RuntimeError, "second live editor"):
            self.verify()

    def test_unsupported_script_modes_refuse_before_launch(self) -> None:
        for mode in ("--script", "--source-project", "--local-archive"):
            with self.subTest(mode=mode):
                result = subprocess.run([
                    sys.executable, str(ROOT / "scripts/verify-packaged-sheets.py"),
                    "/nonexistent/app", "--logs", str(self.root / "logs"), mode, "/nonexistent/case"],
                    capture_output=True, text=True, timeout=5, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--script is ignored by release templates; use the MCP mode", result.stderr)
                self.assertFalse((self.root / "logs").exists())

    def test_global_deadline_refuses_before_another_request(self) -> None:
        client = PROBE.MCPClient(1, time.monotonic() - 1)
        with self.assertRaisesRegex(TimeoutError, "300 second deadline"):
            client.call("minerva_clock", {})

    def test_busy_port_refuses_an_unrelated_app(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "refusing to probe another app"):
            PROBE.require_free_port(self.port)

    def test_catalog_provenance_records_real_repository_requests(self) -> None:
        snapshot = self.root / "releases.json"
        snapshot.write_text(json.dumps({repo: [[]] for repo in PROBE.REPOSITORIES}))
        previous = os.environ.get("MINERVA_REQUIRED_RELEASES_JSON")
        os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = str(snapshot)
        served: list[str] = []
        try:
            with PROBE.helpers(ROOT)._required_releases(served) as base:
                for repo in PROBE.REPOSITORIES:
                    with urllib.request.urlopen(f"{base}/repos/{repo}/releases?per_page=100&page=1", timeout=5) as response:
                        self.assertEqual(json.load(response), [])
        finally:
            if previous is None:
                del os.environ["MINERVA_REQUIRED_RELEASES_JSON"]
            else:
                os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = previous
        self.assertEqual(set(served), PROBE.REPOSITORIES)

    def test_bad_release_snapshot_fails_before_launch(self) -> None:
        snapshot = self.root / "broken-releases.json"
        snapshot.write_text("[]")
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts/verify-packaged-sheets.py"),
            sys.executable, "--logs", str(self.root / "logs")],
            env={**os.environ, "MINERVA_REQUIRED_RELEASES_JSON": str(snapshot)},
            capture_output=True, text=True, timeout=5, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("snapshot must be keyed by repository", result.stderr)
        self.assertFalse((self.root / "logs/required-sheets.log").exists())


if __name__ == "__main__":
    unittest.main()
