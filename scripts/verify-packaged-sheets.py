#!/usr/bin/env python3
"""Verify required Sheets through a normally launched packaged app's public MCP."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any, TypedDict
from urllib.error import URLError

PROBE_TIMEOUT_SECONDS = 300
REPOSITORIES = {"turnrocklabs/Minerva", "imrans-lab/minerva-plugins"}
CSV_BYTES = "Name,Value\nZoë,5\n李,7".encode()
CSV_DATA = [["Name", "Value"], ["Zoë", 5], ["李", 7]]
MCP_PORT = 9315
SHEETS_TOOLS = {"minerva_sheets_create_editor", "minerva_sheets_get_data"}


class SheetsRelease(TypedDict):
    version: str
    downloads: dict[str, str]


def expected_sheets(snapshot: Path) -> SheetsRelease:
    """Independent expectation from the stable releases in CI's served catalog."""
    catalog = json.loads(snapshot.read_text(encoding="utf-8"))
    releases = [release for page in catalog.get("imrans-lab/minerva-plugins", []) for release in page
                if release.get("tag_name", "").startswith("sheets-v")
                and not release.get("draft") and not release.get("prerelease")]
    if not releases:
        raise ValueError("Required-release catalog has no stable Sheets release")

    def version_key(release: dict[str, Any]) -> tuple[int, int, int]:
        version = release["tag_name"].removeprefix("sheets-v")
        match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+[^\s]+)?", version)
        if match is None:
            raise ValueError(f"Unsupported stable Sheets release version: {version}")
        return int(match[1]), int(match[2]), int(match[3])

    newest = max(releases, key=version_key)
    version = newest["tag_name"].removeprefix("sheets-v")
    prefix = f"sheets-{version}-"
    return {"version": version, "downloads": {
        asset["name"].removeprefix(prefix).removesuffix(".tar.gz"): asset["browser_download_url"]
        for asset in newest.get("assets", [])
        if asset.get("name", "").startswith(prefix) and asset["name"].endswith(".tar.gz")}}


def expected_asset(release: SheetsRelease, system: str, machine: str) -> str:
    arm = machine.lower() in {"arm64", "aarch64"}
    if system == "darwin":
        targets = ["macos-arm64" if arm else "macos-amd64", "macos-universal"]
    elif system == "win32":
        targets = ["windows-x86_64"]
    elif system.startswith("linux"):
        targets = ["linux-arm64" if arm else "linux-x86_64"]
    else:
        raise ValueError(f"Unsupported probe platform: {system}/{machine}")
    for target in targets:
        if target in release["downloads"]:
            return release["downloads"][target]
    raise ValueError(f"Sheets {release['version']} has no asset for {targets}")


def helpers(root: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("packaged_helpers", root / "scripts/verify-packaged-mcp-app.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Packaged helper module is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class MCPClient:
    """JSON-RPC boundary used by app-smoke and tarball-smoke.

    Tool payloads are dynamic JSON owned by the app's advertised schemas.
    """

    def __init__(self, port: int, deadline: float | None = None) -> None:
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.sequence = 0
        self.deadline = deadline if deadline is not None else time.monotonic() + PROBE_TIMEOUT_SECONDS

    def rpc(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Required Sheets probe exceeded its 300 second deadline")
        self.sequence += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.sequence,
                           "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, body, {
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-06-18"})
        with urllib.request.urlopen(request, timeout=min(30, remaining)) as response:
            reply = json.load(response)
        if reply.get("id") != self.sequence or "error" in reply:
            raise RuntimeError(f"MCP {method} failed: {reply}")
        return reply["result"]

    def call(self, name: str, arguments: dict[str, Any], *, allow_error: bool = False) -> dict[str, Any]:
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        content = result.get("content", [])
        if len(content) != 1 or content[0].get("type") != "text":
            raise RuntimeError(f"MCP {name} returned no single JSON result: {result}")
        value = json.loads(content[0]["text"])
        if not isinstance(value, dict):
            raise TypeError(f"MCP {name} returned a non-object result")
        if not allow_error and (result.get("isError") or value.get("error")):
            raise RuntimeError(f"MCP {name} failed: {value}")
        return value


def require(ok: bool, label: str) -> None:
    if not ok:
        raise RuntimeError(label)
    print(f"PASS: {label}", flush=True)


def wait_for(ready: Callable[[], bool], process: subprocess.Popen[str], label: str,
             deadline: float) -> None:
    while True:
        if process.poll() is not None:
            raise RuntimeError(f"App exited {process.returncode} while waiting for {label}")
        if ready():
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for {label}")
        time.sleep(0.25)


def require_free_port(port: int) -> None:
    # The normal app uses this public default in its fresh private profile.
    # Refuse before launch if another app already owns it.
    try:
        connection = socket.create_connection(("127.0.0.1", port), timeout=1)
    except ConnectionRefusedError:
        return
    connection.close()
    raise RuntimeError(f"MCP port {port} is already in use; refusing to probe another app")


def hello(process: subprocess.Popen[str], deadline: float) -> MCPClient:
    # Release templates buffer stdout, so readiness comes from the protocol,
    # after the exclusive-port preflight, while our launched app stays alive.
    client = MCPClient(MCP_PORT, deadline)
    initialized: dict[str, Any] = {}

    def answering() -> bool:
        nonlocal initialized
        try:
            initialized = client.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                   "clientInfo": {"name": "required-sheets", "version": "1"}})
        except URLError as error:
            if not isinstance(error.reason, ConnectionRefusedError):
                raise
            return False
        return True

    wait_for(answering, process, "the launched app's MCP initialize", min(deadline, time.monotonic() + 60))
    require(initialized.get("serverInfo", {}).get("name") == "minerva"
            and initialized.get("protocolVersion") == "2025-06-18", "normal app answers MCP initialize")
    require(bool(client.rpc("tools/list", {}).get("tools")), "normal app advertises tools")
    print("PACKAGED_REQUIRED_SHEETS_HELLO", flush=True)
    return client


def policy_ready(client: MCPClient) -> bool:
    reply = client.call("minerva_policy_reload", {}, allow_error=True)
    if reply.get("success") is True:
        return True
    if reply.get("error_code") == "docket_not_ready" and reply.get("retryable") is True:
        return False
    raise RuntimeError(f"Docket policy readiness failed: {reply}")


def provider_running(reply: dict[str, Any]) -> bool:
    status = reply.get("status", {})
    if status.get("state_name") in {"BUILD_FAILED", "NEEDS_BINARY", "CRASH_LOOP", "ERROR"}:
        raise RuntimeError(f"Required Sheets cannot start: {reply}")
    if reply.get("error"):
        # Absence is expected while required-plugin pickup installs Sheets.
        if reply.get("error") == "Plugin 'sheets' not found":
            return False
        raise RuntimeError(f"Required Sheets inspection failed: {reply}")
    if status.get("running") is True:
        return True
    if status.get("state_name") in {"INSTALLED", "STARTING", "BUILDING"}:
        return False
    raise RuntimeError(f"Required Sheets is not pending or running: {reply}")


def wait_for_exit(process: subprocess.Popen[str], timeout: float = 10) -> None:
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def verify_provider(client: MCPClient, user: Path, fixture: Path,
                    inspected: dict[str, Any], served: list[str],
                    release: SheetsRelease, downloaded: list[str]) -> None:
    require(REPOSITORIES <= set(served), "public catalog fetches both declared repositories")
    require(inspected.get("version") == release["version"]
            and inspected.get("status", {}).get("running") is True,
            f"required Sheets {release['version']} from the served catalog is running")
    records = json.loads((user / "plugins/plugins.json").read_text(encoding="utf-8"))["plugins"]
    definition = next(record for record in records if record.get("id") == "sheets")
    require(definition.get("version") == release["version"] and definition.get("install_lane") == "marketplace"
            and definition.get("autostart") is True and definition.get("auto_update") is True,
            "installed required provider has first-install choices")
    asset = expected_asset(release, sys.platform, platform.machine())
    sheets_downloads = set(downloaded) & set(release["downloads"].values())
    require(sheets_downloads == {asset}, f"installed Sheets requested the platform's expected asset: {asset}")
    tools = {tool["name"] for tool in inspected.get("tools", [])}
    require(SHEETS_TOOLS <= tools, f"installed Sheets exposes the tools this probe calls: {sorted(SHEETS_TOOLS)}")
    csv = fixture / "required-source.csv"
    opened = client.call("minerva_sheets_create_editor", {"name": "Required CSV provider", "file_path": str(csv)})
    data = client.call("minerva_sheets_get_data", {"editor_name": opened.get("editor_name", ""), "format": "json"})
    require(opened.get("success") is True and data.get("data") == CSV_DATA and csv.read_bytes() == CSV_BYTES,
            "installed release opens Unicode CSV through the canonical host path without changing bytes")
    native = client.call("minerva_sheets_create_editor", {
        "name": "Required native provider", "file_path": str(fixture / "required-native.minsheet")})
    names = {opened.get("editor_name"), native.get("editor_name")}
    editors = client.call("minerva_list_editors", {})
    live_names = {editor["name"] for editor in editors.get("editors", [])}
    require(native.get("success") is True and None not in names and len(names) == 2 and names <= live_names,
            "installed release opens native format as a second live editor")
    refused = client.call("minerva_plugin_remove", {"id": "sheets"}, allow_error=True)
    require("required" in str(refused.get("error", "")).lower(), "required Sheets cannot be removed")
    for name in names:
        client.call("minerva_close_editor", {"editor_name": name, "force": True})
    client.call("minerva_plugin_stop", {"id": "sheets"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog=
        "--script is ignored by release templates; use the MCP mode.")
    if any(arg.split("=", 1)[0] in ("--script", "--source-project", "--local-archive") for arg in sys.argv[1:]):
        parser.error("--script is ignored by release templates; use the MCP mode")
    parser.add_argument("app", type=Path)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--hello-only", action="store_true", help="only confirm normal app execution through MCP")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = args.app.resolve(strict=True)
    if not app.is_file():
        raise ValueError("App must be an executable file")
    if not args.hello_only and not os.environ.get("MINERVA_REQUIRED_RELEASES_JSON"):
        raise ValueError("Published probe requires MINERVA_REQUIRED_RELEASES_JSON")
    probe = helpers(root)
    args.logs.mkdir(parents=True, exist_ok=True)
    served: list[str] = []
    downloaded: list[str] = []
    with probe._private_profile() as profile, probe._required_releases(served, downloaded) as base:
        # Validate the snapshot first: malformed input must fail independently
        # of another Minerva instance owning the public port on this machine.
        release = expected_sheets(Path(os.environ["MINERVA_REQUIRED_RELEASES_JSON"])) if not args.hello_only else None
        require_free_port(MCP_PORT)
        env = os.environ.copy()
        probe._seed_profile(profile.root, env)
        env["MINERVA_REQUIRED_RELEASES_URL"] = base or "http://127.0.0.1:9"
        if sys.platform == "darwin":
            user = Path(env["HOME"]) / "Library/Application Support/Godot/app_userdata/Minerva"
        elif os.name == "nt":
            user = Path(env["APPDATA"]) / "Godot/app_userdata/Minerva"
        else:
            user = Path(env["XDG_DATA_HOME"]) / "godot/app_userdata/Minerva"
        require(not (user / "plugins/plugins.json").exists(), "fresh profile has no Sheets provider")
        fixture = profile.root / "release-fixture"
        fixture.mkdir()
        (fixture / "required-source.csv").write_bytes(CSV_BYTES)
        shutil.copy2(root / "src/test/fixtures/spreadsheet_contract/baseline.minsheet", fixture / "required-native.minsheet")
        log = args.logs / "required-sheets.log"
        command = [str(app), "--verbose", "--rendering-method", "gl_compatibility"]
        deadline = time.monotonic() + PROBE_TIMEOUT_SECONDS
        with log.open("w", encoding="utf-8") as output:
            process = subprocess.Popen(command, cwd=app.parent, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, text=True, start_new_session=os.name != "nt")
            try:
                client = hello(process, deadline)
                if not args.hello_only:
                    wait_for(lambda: policy_ready(client),
                             process, "Docket policy readiness", min(deadline, time.monotonic() + 90))
                    inspected: dict[str, Any] = {}

                    def running() -> bool:
                        nonlocal inspected
                        inspected = client.call("minerva_plugin_inspect", {"id": "sheets", "include": ["tools"]}, allow_error=True)
                        return provider_running(inspected)

                    wait_for(running, process, "required Sheets pickup and start", min(deadline, time.monotonic() + 60))
                    assert release is not None
                    verify_provider(client, user, fixture, inspected, served, release, downloaded)
            finally:
                failed = sys.exc_info()[0] is not None
                try:
                    probe._terminate_tree(process)
                    wait_for_exit(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    if not failed:
                        raise
                    print(f"App cleanup also failed: {error}", file=sys.stderr)
                output.flush()
                print(log.read_text(encoding="utf-8", errors="replace"), flush=True)
        fatal = re.search(r"SCRIPT ERROR:|Can't open dynamic library|Error loading extension", log.read_text(encoding="utf-8", errors="replace"))
        require(fatal is None, "packaged execution has no script or extension load errors")
    if profile.cleanup_error:
        raise RuntimeError(profile.cleanup_error)
    if not args.hello_only:
        print("PACKAGED_REQUIRED_SHEETS_OK", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
