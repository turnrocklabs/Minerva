#!/usr/bin/env python3
"""Package one built plugin runtime as a release archive for Minerva's installer.

The archive is what Minerva's marketplace installer accepts: manifest.json and
SHA256SUMS at its root beside the runtime files, named
"<id>-<version>-<target>.tar.gz", with a ".sha256" of the archive beside it.

The manifest comes from the plugin's source template. Its version must equal
--version (the release tag's), and --target must be one of its
release_targets. --entrypoint replaces the template's backend entrypoint for
runtimes whose launcher differs per platform.

The finished archive is then extracted and its entrypoint run as an MCP
server: tools/list must name exactly the tools the manifest declares, so a
release cannot disagree with the contract Minerva reads before it starts it.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

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


def probe_tools(root: Path, manifest: dict) -> None:
    """Run the extracted release's entrypoint and compare tools/list with the
    manifest's tools."""
    backend = manifest["backend"]
    command = backend["entrypoint"]
    if command.startswith("./"):
        command = str(root / command[2:])
        if not os.path.exists(command) and os.path.exists(command + ".exe"):
            command += ".exe"
    stderr = tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace")
    process = subprocess.Popen(
        [command, *backend.get("args", [])], cwd=root,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
        text=True, encoding="utf-8")
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
    reported = {tool.get("name") for tool in listed.get("result", {}).get("tools", [])}
    declared = {tool["name"] for tool in manifest.get("tools", [])}
    if reported != declared:
        raise SystemExit(f"{manifest['id']} tools/list does not match its manifest: "
                         f"undeclared {sorted(reported - declared)}, missing {sorted(declared - reported)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", type=Path, required=True, help="the plugin's manifest template")
    parser.add_argument("--stage", type=Path, required=True, help="the built runtime for --target")
    parser.add_argument("--target", required=True)
    parser.add_argument("--version", help="the release's version (default: the template's)")
    parser.add_argument("--entrypoint", help="backend entrypoint for this target")
    parser.add_argument("--out", type=Path, required=True, help="directory for the archive")
    args = parser.parse_args()

    version = args.version or json.loads(args.manifest.read_text(encoding="utf-8"))["version"]
    manifest = build_manifest(args.manifest, version, args.target, args.entrypoint)
    archive = args.out / f"{manifest['id']}-{version}-{args.target}.tar.gz"
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch) / "package"
        shutil.copytree(args.stage, root, symlinks=True)
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        check_entries(root)
        write_sums(root)
        pack(root, archive)
        extracted = Path(scratch) / "extracted"
        extracted.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(extracted, filter="tar")
        probe_tools(extracted, manifest)
    print(f"packaged {archive}")


if __name__ == "__main__":
    sys.exit(main())
