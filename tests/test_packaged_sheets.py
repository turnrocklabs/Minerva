"""Public HTTP contract and falsifying checks for the packaged Sheets verifier."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import socket
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
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("packaged_sheets", ROOT / "scripts/verify-packaged-sheets.py")
assert SPEC is not None and SPEC.loader is not None
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
PREFETCH_SPEC = importlib.util.spec_from_file_location("prefetch", ROOT / "scripts/prefetch-required-releases.py")
assert PREFETCH_SPEC is not None and PREFETCH_SPEC.loader is not None
PREFETCH = importlib.util.module_from_spec(PREFETCH_SPEC)
PREFETCH_SPEC.loader.exec_module(PREFETCH)


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
            "id": "sheets", "version": "0.2.10", "install_lane": "marketplace",
            "autostart": True, "auto_update": True}]}))
        (self.user / "plugins/sheets/manifest.json").write_text(json.dumps({
            "release_targets": ["macos-universal"]}))
        (self.fixture / "required-source.csv").write_bytes(PROBE.CSV_BYTES)
        self.inspected = {"version": "0.2.10", "status": {"running": True},
                          "tools": [{"name": name} for name in PROBE.SHEETS_TOOLS]}
        self.release = {"version": "0.2.10", "downloads": {
            target: f"https://example.invalid/sheets-0.2.10-{target}.tar.gz"
            for target in ("macos-universal", "linux-x86_64", "linux-arm64", "windows-x86_64")}}
        self.downloaded = [PROBE.expected_asset(self.release, sys.platform, PROBE.platform.machine())]
        self.replies: dict[str, dict[str, Any]] = {
            "minerva_sheets_get_data": {"data": PROBE.CSV_DATA},
            "minerva_plugin_remove": {"error": "Sheets is required by Minerva and cannot be removed"},
            "minerva_list_editors": {"editors": [{"name": "Required CSV provider"}, {"name": "Required native provider"}]},
            "minerva_policy_reload": {"success": True},
        }
        self.calls: list[str] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                body = b"published archive bytes"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

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
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
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
            PROBE.verify_provider(self.client, self.user, self.fixture, self.inspected,
                                  list(PROBE.REPOSITORIES), self.release, self.downloaded)

    def test_public_http_provider_path_and_cleanup(self) -> None:
        self.verify()
        self.assertIn("minerva_sheets_get_data", self.calls)
        self.assertIn("minerva_plugin_remove", self.calls)
        self.assertEqual(self.calls[-3:], ["minerva_close_editor", "minerva_close_editor", "minerva_plugin_stop"])

    def test_release_fetch_decodes_utf8_and_reports_failed_command(self) -> None:
        release = [[{"body": "release \u008f"}]]
        replies = iter([(0, json.dumps(release, ensure_ascii=False).encode("utf-8"), b""),
                        (7, b"", "permission denied \u008f".encode("utf-8")),
                        (9, b"", b"permission denied \xff"), (0, b"\xff", b"")])
        run = subprocess.run

        def gh_output(_command: list[str], **options: object) -> subprocess.CompletedProcess[str | bytes]:
            code, output, errors = next(replies)
            # Exercise the real pipe decoder with Windows' fallback on every OS.
            if options.get("text"):
                options.setdefault("encoding", "cp1252")
            program = (f"import sys; sys.stdout.buffer.write({output!r}); "
                       f"sys.stderr.buffer.write({errors!r}); sys.exit({code})")
            return run([sys.executable, "-c", program], **options)

        with mock.patch.object(PREFETCH.subprocess, "run", side_effect=gh_output):
            self.assertEqual(PREFETCH.fetch_releases(["owner/repo"]), {"owner/repo": release})
            with self.assertRaisesRegex(RuntimeError, "gh api .*owner/repo.*exit code 7: permission denied \u008f"):
                PREFETCH.fetch_releases(["owner/repo"])
            with self.assertRaisesRegex(RuntimeError, "exit code 9: permission denied \ufffd"):
                PREFETCH.fetch_releases(["owner/repo"])
            with self.assertRaises(UnicodeDecodeError):
                PREFETCH.fetch_releases(["owner/repo"])

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
        with self.assertRaisesRegex(RuntimeError, "tools this probe calls"):
            self.verify()

    def test_extra_tools_do_not_pin_release_tool_count(self) -> None:
        self.inspected["tools"].extend({"name": f"future_tool_{i}"} for i in range(35))
        self.verify()

    def test_wrong_download_cannot_pass_manifest_target_list(self) -> None:
        self.downloaded = ["https://example.invalid/sheets-wrong-platform.tar.gz"]
        with self.assertRaisesRegex(RuntimeError, "expected asset"):
            self.verify()

    def test_mac_arm64_prefers_native_else_universal(self) -> None:
        self.assertEqual(PROBE.expected_asset(self.release, "darwin", "arm64"),
                         self.release["downloads"]["macos-universal"])
        self.release["downloads"]["macos-arm64"] = "https://example.invalid/arm64.tar.gz"
        self.assertEqual(PROBE.expected_asset(self.release, "darwin", "arm64"),
                         self.release["downloads"]["macos-arm64"])

    def test_newest_stable_catalog_version_and_stale_install(self) -> None:
        snapshot = self.root / "releases.json"
        releases = [{"tag_name": f"sheets-v{version}", "assets": []}
                    for version in ("0.2.9", "0.2.10", "0.1.2")]
        releases += [{"tag_name": "sheets-v9.0.0", flag: True} for flag in ("draft", "prerelease")]
        snapshot.write_text(json.dumps({"imrans-lab/minerva-plugins": [releases]}))
        self.assertEqual(PROBE.expected_sheets(snapshot)["version"], "0.2.10")
        self.inspected["version"] = "0.1.2"
        with self.assertRaisesRegex(RuntimeError, "served catalog"):
            self.verify()

    def test_terminal_provider_failures_include_response(self) -> None:
        for state in ("BUILD_FAILED", "NEEDS_BINARY", "CRASH_LOOP", "ERROR", "STOPPED"):
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, "fixture failure"):
                PROBE.provider_running({"status": {"state_name": state}, "detail": "fixture failure"})
        for state in ("INSTALLED", "STARTING", "BUILDING"):
            self.assertFalse(PROBE.provider_running({"status": {"state_name": state}}))
        self.assertFalse(PROBE.provider_running({"error": "Plugin 'sheets' not found"}))

    def test_policy_retries_only_pending_docket(self) -> None:
        self.replies["minerva_policy_reload"] = {
            "error": "still starting", "error_code": "docket_not_ready", "retryable": True}
        self.assertFalse(PROBE.policy_ready(self.client))
        self.replies["minerva_policy_reload"] = {
            "error": "fixture policy failure", "error_code": "policy_unavailable", "retryable": False}
        with self.assertRaisesRegex(RuntimeError, "fixture policy failure"):
            PROBE.policy_ready(self.client)
        self.assertEqual(self.calls, ["minerva_policy_reload", "minerva_policy_reload"])

    def test_wait_timeout_kills_child_and_preserves_original_failure(self) -> None:
        process = subprocess.Popen([sys.executable, "-u", "-c",
                                    "import time; print('ready'); time.sleep(30)"],
                                   stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            with self.assertRaisesRegex(RuntimeError, "original probe failure"):
                try:
                    raise RuntimeError("original probe failure")
                finally:
                    PROBE.wait_for_exit(process, timeout=0)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()

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

    def test_catalog_records_selected_asset_and_redirects_to_original_bytes(self) -> None:
        snapshot = self.root / "assets.json"
        original = f"http://127.0.0.1:{self.port}/sheets-0.2.10-macos-universal.tar.gz"
        snapshot.write_text(json.dumps({"imrans-lab/minerva-plugins": [[{
            "tag_name": "sheets-v0.2.10", "assets": [{"name": "sheets-0.2.10-macos-universal.tar.gz",
                                                      "browser_download_url": original}]}]]}))
        previous = os.environ.get("MINERVA_REQUIRED_RELEASES_JSON")
        os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = str(snapshot)
        downloaded: list[str] = []
        try:
            with PROBE.helpers(ROOT)._required_releases([], downloaded) as base:
                with urllib.request.urlopen(f"{base}/repos/imrans-lab/minerva-plugins/releases", timeout=5) as response:
                    release = json.load(response)[0]
                self.assertEqual(downloaded, [])
                with urllib.request.urlopen(release["assets"][0]["browser_download_url"], timeout=5) as response:
                    self.assertEqual(response.read(), b"published archive bytes")
        finally:
            if previous is None:
                del os.environ["MINERVA_REQUIRED_RELEASES_JSON"]
            else:
                os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = previous
        self.assertEqual(downloaded, [original])

    def test_bad_release_snapshot_fails_before_launch(self) -> None:
        snapshot = self.root / "broken-releases.json"
        snapshot.write_text("[]")
        with socket.socket() as busy:
            try:
                busy.bind(("127.0.0.1", PROBE.MCP_PORT))
                busy.listen()
            except OSError:
                pass  # A live Minerva already supplies the busy-port condition.
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
