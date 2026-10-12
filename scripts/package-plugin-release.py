#!/usr/bin/env python3
"""Package one built plugin runtime as a release archive for Minerva's installer.

The archive is what Minerva's marketplace installer accepts: manifest.json and
SHA256SUMS at its root beside the runtime files, named
"<id>-<version>-<target>.tar.gz", with a ".sha256" of the archive beside it.

The manifest comes from the plugin's source template. Its version must equal
--version (the release tag's), and --target must be one of its
release_targets. --entrypoint replaces the template's backend entrypoint for
runtimes whose launcher differs per platform.

The finished archive is then extracted and its entrypoint probed against its
contract: MCP servers must match their declared tools; Docket's one-shot
launcher must spawn and attach to its registered standalone HTTP server.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request

PROBE_TIMEOUT_S = 30.0


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(template: Path, version: str, target: str, entrypoint: str | None) -> dict:
    manifest = json.loads(template.read_text(encoding="utf-8"))
    if manifest.get("version") != version:
        raise SystemExit(f"{template} is version {manifest.get('version')!r}, not the release's {version!r}")
    if target not in manifest.get("release_targets", []):
        raise SystemExit(f"{target} is not in {template}'s release_targets")
    if entrypoint:
        manifest["backend"]["entrypoint"] = entrypoint
    return manifest


def write_sums(root: Path) -> None:
    """SHA256SUMS over every regular file (a symlink counts as its target's
    content, as the installer reads it), in a stable order."""
    lines = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS":
            lines.append(f"{sha256(path)}  {path.relative_to(root).as_posix()}\n")
    (root / "SHA256SUMS").write_text("".join(lines), encoding="utf-8", newline="\n")


def check_entries(root: Path) -> None:
    """Refuse entries Minerva's archive scan (PluginArchiveScan) would refuse:
    a name that is not UTF-8 or holds ":" or "\\"; a symlink with a non-ASCII
    name or target, or a target that is absolute, holds ":" or "\\", passes
    through a symlink, leaves the archive, or resolves to the archive root or
    to the link itself; or an entry at or below a symlink's path when compared
    ignoring case, as some filesystems do."""
    walked = list(root.rglob("*"))
    entries = [p.relative_to(root).as_posix() for p in walked]
    links = {p.relative_to(root).as_posix().lower() for p in walked if p.is_symlink()}
    for rel in entries:
        try:
            rel.encode("utf-8")
        except UnicodeEncodeError:
            raise SystemExit(f"{rel!r} is not a UTF-8 name")
        if ":" in rel or "\\" in rel:
            raise SystemExit(f"{rel} holds a character the installer refuses in names (: or \\)")
        parts = rel.lower().split("/")
        if any("/".join(parts[:i]) in links for i in range(1, len(parts))):
            raise SystemExit(f"{rel} lies below a symlink")
        if rel.lower() in links and sum(e.lower() == rel.lower() for e in entries) > 1:
            raise SystemExit(f"{rel} differs only in case from a symlink")
    for rel in (e for e in entries if (root / e).is_symlink()):
        target = os.readlink(root / rel)
        if not (rel.isascii() and target.isascii()) or target.startswith(("/", "\\")) \
                or ":" in target or "\\" in target or _resolve(rel, target, links) in ("", rel):
            raise SystemExit(f"symlink {rel} -> {target} would be refused by the installer")


def _resolve(rel: str, target: str, links: set[str]) -> str:
    """The archive path symlink `rel` names, "" if the walk leaves the archive
    or passes through a symlink (as PluginArchiveScan._resolve)."""
    parts: list[str] = []
    for part in [p for p in rel.split("/")[:-1] + target.split("/") if p]:
        if parts and "/".join(parts).lower() in links:
            return ""
        if part == "..":
            if not parts:
                return ""
            parts.pop()
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def pack(root: Path, archive: Path) -> None:
    with tarfile.open(archive, "w:gz") as tar:
        for path in sorted(root.iterdir()):
            tar.add(path, arcname=path.name)
    archive.with_name(archive.name + ".sha256").write_text(sha256(archive) + "\n", encoding="ascii")


def tool_name(plugin_id: str, raw: str) -> str:
    if plugin_id == "docket" and raw.startswith("docket_"):
        return "minerva_" + raw.replace(".", "_")
    prefix = f"minerva_{plugin_id}_"
    return raw if raw.startswith(prefix) else prefix + raw.replace(".", "_")


def verify_docket_bundle(root: Path) -> None:
    apps = list(root.glob("official/*/Docket.app"))
    if len(apps) != 1:
        raise SystemExit("Docket macOS package must contain one official app bundle")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(apps[0])], check=True)


def probe_tools(root: Path, manifest: dict, discover: bool = False) -> list:
    """Run the extracted release's entrypoint and compare tools/list with the
    manifest's tools."""
    backend = manifest["backend"]
    command = backend["entrypoint"]
    if command.startswith("./"):
        command = str(root / command[2:])
        if not os.path.exists(command) and os.path.exists(command + ".exe"):
            command += ".exe"
    stderr = tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace")
    env = dict(os.environ)
    if manifest.get("panel_authority"):
        env[manifest["panel_authority"]["secret_env"]] = secrets.token_hex(32)
        env["MINERVA_PLUGIN_DATA_DIR"] = str(root.parent / "probe-data")
    argv = [command, *backend.get("args", [])]
    process = subprocess.Popen(
        argv, cwd=root,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
        text=True, encoding="utf-8", env=env)
    assert process.stdin is not None and process.stdout is not None
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in process.stdout], daemon=True).start()
    deadline = time.monotonic() + PROBE_TIMEOUT_S

    def fail(why: str) -> None:
        stderr.seek(0)
        tail = stderr.read()[-4000:].strip()
        raise SystemExit(f"{manifest['id']} {why}" + (f"; its stderr ends:\n{tail}" if tail else ""))

    def request(message: dict) -> dict:
        try:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
        except OSError:
            fail(f"stopped reading its input before {message['method']}")
        if "id" not in message:
            return {}
        while True:
            if time.monotonic() > deadline:
                fail(f"did not answer {message['method']} within {PROBE_TIMEOUT_S:.0f}s")
            try:
                reply = json.loads(lines.get(timeout=0.2))
            except queue.Empty:
                if process.poll() is not None:
                    fail(f"exited (code {process.returncode}) without answering {message['method']}")
                continue
            except json.JSONDecodeError:
                continue  # not a protocol line
            if reply.get("id") == message["id"]:
                if "error" in reply:
                    fail(f"answered {message['method']} with an error: {reply['error']}")
                return reply

    try:
        request({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "minerva-plugin-release", "version": "1"}}})
        request({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        listed = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    finally:
        with contextlib.suppress(OSError):
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        stderr.close()
    tools = listed.get("result", {}).get("tools", [])
    if discover:
        return [{"name": tool_name(manifest["id"], t["name"]), "description": t.get("description", ""),
                 "input_schema": t.get("inputSchema", {})} for t in tools]
    reported = {tool_name(manifest["id"], tool["name"]) for tool in tools}
    declared = {tool["name"] for tool in manifest.get("tools", [])}
    if reported != declared:
        raise SystemExit(f"{manifest['id']} tools/list does not match its manifest: "
                         f"undeclared {sorted(reported - declared)}, missing {sorted(declared - reported)}")

    return tools


def stop_docket_fixture(pid: int) -> None:
    """Wait for our detached fixture to stop before deleting its profile."""
    if sys.platform == "win32":
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x100001, False, pid)
        if not handle:
            raise SystemExit(f"Cannot open owned Docket fixture PID {pid} for cleanup")
        try:
            if not kernel.TerminateProcess(handle, 0) or kernel.WaitForSingleObject(handle, 5000) != 0:
                raise SystemExit(f"Docket fixture PID {pid} did not stop")
        finally:
            kernel.CloseHandle(handle)
        return

    def alive() -> bool:
        with contextlib.suppress(ChildProcessError):
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        # A detached Linux child may remain a zombie under a container init.
        stat = Path(f"/proc/{pid}/stat")
        if sys.platform.startswith("linux"):
            try:
                return stat.read_text().rsplit(")", 1)[1].split()[0] != "Z"
            except FileNotFoundError:
                return False
        return True

    for sig in (signal.SIGTERM, signal.SIGKILL):
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, sig)
        deadline = time.monotonic() + 5
        while alive() and time.monotonic() < deadline:
            time.sleep(0.1)
        if not alive():
            return
    raise SystemExit(f"Docket fixture PID {pid} did not stop")


def probe_docket(root: Path, manifest: dict) -> None:
    """Probe the bundled launcher with a fresh profile, never an owner's server."""
    if manifest.get("tools") or manifest["backend"].get("args"):
        raise SystemExit("Docket launcher must have empty tools and arguments")
    command = (root / manifest["backend"]["entrypoint"]).resolve()
    receipts = list(root.glob("official/*/acquisition.lock.json"))
    if len(receipts) != 1:
        raise SystemExit("Docket package must contain one acquisition receipt")
    receipt = json.loads(receipts[0].read_text(encoding="utf-8"))
    if receipt.get("tag") != "v" + manifest["version"] or not receipt.get("source"):
        raise SystemExit("Docket acquisition receipt does not identify this release")
    identity = receipt["tag"] + "+" + receipt["source"]
    mac_profile_link = None
    owned_pid = None
    with contextlib.ExitStack() as scratch_cleanup:
        scratch = Path(tempfile.mkdtemp(prefix="docket-package-probe-")).resolve()
        cleanup_failed = False
        scratch_cleanup.callback(lambda: None if cleanup_failed else shutil.rmtree(scratch))
        env = dict(os.environ)
        env["MINERVA_PLUGIN_DATA_DIR"] = str(scratch / "plugin-data")
        for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "APPDATA", "LOCALAPPDATA"):
            env[key] = str(scratch / key)
            Path(env[key]).mkdir()
        if sys.platform == "win32":
            profile = Path(env["APPDATA"]) / "Godot/app_userdata/Docket"
        elif sys.platform == "darwin":
            verify_docket_bundle(root)
            # macOS has no per-process user-data base override. Refuse any
            # existing profile; redirect only a newly created runner fixture.
            profile = scratch / "Docket"
            profile.mkdir()
            link = Path.home() / "Library/Application Support/Godot/app_userdata/Docket"
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(profile, target_is_directory=True)
            mac_profile_link = link
        else:
            profile = Path(env["XDG_DATA_HOME"]) / "godot/app_userdata/Docket"

        def invoke() -> dict:
            result = subprocess.run([str(command)], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=PROBE_TIMEOUT_S + 5)
            if result.returncode:
                raise SystemExit(f"Docket launcher exited {result.returncode}: {result.stderr[-4000:]}")
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise SystemExit(f"Docket launcher did not return one status: {result.stdout[-4000:]}") from error

        try:
            spawned = invoke()
            record = json.loads((profile / "instance.json").read_text(encoding="utf-8"))
            pid = record.get("pid")
            endpoint = record.get("endpoint", {})
            if isinstance(pid, int) and pid > 0 and Path(record.get("profile", "")).resolve() == profile.resolve():
                owned_pid = pid
            if (spawned.get("status") != "spawned" or not isinstance(pid, int) or pid <= 0
                    or spawned.get("pid") != pid or endpoint.get("host") != "127.0.0.1"
                    or not isinstance(endpoint.get("port"), int) or not 1 <= endpoint["port"] <= 65535):
                raise SystemExit(f"Docket did not spawn a registered fixture: {spawned}")
            address = f"127.0.0.1:{endpoint['port']}"
            if spawned.get("endpoint") != address or spawned.get("version") != identity:
                raise SystemExit(f"Docket registered identity does not match release: {spawned}")
            if Path(record["profile"]).resolve() != profile.resolve():
                raise SystemExit("Docket registered outside the isolated profile")
            request = urllib.request.Request("http://" + address + "/mcp",
                data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "minerva-plugin-release", "version": "1"}}}).encode(),
                headers={"Content-Type": "application/json"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=5) as response:
                initialized = json.load(response)
            result = initialized.get("result", {})
            if (initialized.get("id") != 1 or "error" in initialized
                    or result.get("serverInfo", {}).get("version") != identity
                    or result.get("_meta", {}).get("registration_status") != "registered"):
                raise SystemExit(f"Docket standalone initialize failed: {initialized}")
            attached = invoke()
            if attached != dict(spawned, status="attached"):
                raise SystemExit(f"Docket launcher did not attach to its fixture: {attached}")
            print(f"Docket launcher spawn/HTTP/attach passed ({manifest['version']})")
        finally:
            try:
                # Recover ownership even if parsing the launcher response failed.
                if owned_pid is None and (profile / "instance.json").is_file():
                    record = json.loads((profile / "instance.json").read_text(encoding="utf-8"))
                    pid = record.get("pid")
                    if isinstance(pid, int) and pid > 0 and Path(record.get("profile", "")).resolve() == profile.resolve():
                        owned_pid = pid
                if owned_pid is not None:
                    stop_docket_fixture(owned_pid)
            except BaseException:
                cleanup_failed = True
                print(f"Docket fixture cleanup failed; preserve {scratch} and discard this runner", file=sys.stderr)
                raise
            finally:
                if mac_profile_link is not None and not cleanup_failed:
                    if mac_profile_link.is_symlink() and mac_profile_link.resolve() == profile:
                        mac_profile_link.unlink()
                    verify_docket_bundle(root)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", type=Path, required=True, help="the plugin's manifest template")
    parser.add_argument("--stage", type=Path, required=True, help="the built runtime for --target")
    parser.add_argument("--target", required=True)
    parser.add_argument("--version", help="the release's version (default: the template's)")
    parser.add_argument("--entrypoint", help="backend entrypoint for this target")
    parser.add_argument("--out", type=Path, required=True, help="directory for the archive")
    parser.add_argument("--docket-source", type=Path, help="stage Docket from its pinned plugin source using signed upstream acquisition")
    args = parser.parse_args()

    if args.docket_source:
        args.stage.mkdir(parents=True, exist_ok=True)
        binary = args.stage.resolve() / "docket-plugin.exe"
        subprocess.run(["go", "build", "-mod=readonly", "-o", str(binary), "."], cwd=args.docket_source / "docket", check=True)
        subprocess.run([str(binary), "acquire", str(args.stage.resolve() / "official")], check=True)
    version = args.version or json.loads(args.manifest.read_text(encoding="utf-8"))["version"]
    manifest = build_manifest(args.manifest, version, args.target, args.entrypoint)
    archive = args.out / f"{manifest['id']}-{version}-{args.target}.tar.gz"
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch) / "package"
        shutil.copytree(args.stage, root, symlinks=True)
        if args.docket_source:
            manifest.pop("setup", None)
            manifest["description"] = "Docket's signed upstream GUI, packaged for Minerva's required-plugin installer."
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        check_entries(root)
        write_sums(root)
        pack(root, archive)
        extracted = Path(scratch) / "extracted"
        extracted.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(extracted, filter="tar")
        if manifest["id"] == "docket":
            probe_docket(extracted, manifest)
        else:
            probe_tools(extracted, manifest)
    print(f"packaged {archive}")


if __name__ == "__main__":
    sys.exit(main())
