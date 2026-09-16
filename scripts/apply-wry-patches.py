#!/usr/bin/env python3
"""Prepare pinned WRY sources and apply patches without resetting local work."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import re
from typing import Tuple


def _pinned_wry(lock_text: str) -> Tuple[str, str]:
    text = lock_text
    matches = []
    for block in text.split("[[package]]")[1:]:
        name = re.search(r'^name = "([^"]+)"$', block, re.MULTILINE)
        source = re.search(r'^source = "([^"]+)"$', block, re.MULTILINE)
        version = re.search(r'^version = "([^"]+)"$', block, re.MULTILINE)
        checksum = re.search(r'^checksum = "([0-9a-f]{64})"$', block, re.MULTILINE)
        if name and name.group(1) == "wry" and source \
                and source.group(1).startswith("registry+") and version and checksum:
            matches.append((version.group(1), checksum.group(1)))
    if len(matches) != 1:
        raise SystemExit("Cargo.lock must contain one checksum-pinned registry WRY")
    return matches[0]


def _safe_extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts \
                    or not (member.isfile() or member.isdir()):
                raise SystemExit(f"Unsafe WRY archive member: {member.name}")
        bundle.extractall(destination)


def _prepare_pinned_wry(root: Path, vendor: Path) -> None:
    committed_lock = subprocess.check_output(
        ["git", "-C", str(vendor), "show", "HEAD:rust/Cargo.lock"], text=True)
    version, expected = _pinned_wry(committed_lock)
    dependency_root = vendor / "rust" / ".minerva-deps"
    source = dependency_root / f"wry-{version}"
    archive = dependency_root / f"wry-{version}.crate"
    dependency_root.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        cache_matches = list(Path.home().glob(
            f".cargo/registry/cache/*/wry-{version}.crate"))
        if cache_matches:
            shutil.copyfile(cache_matches[0], archive)
        else:
            download = archive.with_suffix(".download")
            total = 0
            try:
                with urllib.request.urlopen(
                        f"https://static.crates.io/crates/wry/wry-{version}.crate",
                        timeout=60) as response, download.open("wb") as output:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > 64 * 1024 * 1024:
                            raise SystemExit("Pinned WRY archive exceeds 64 MiB")
                        output.write(chunk)
                download.replace(archive)
            finally:
                if download.exists():
                    download.unlink()
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"WRY archive checksum mismatch: {actual} != {expected}")
    if not source.exists():
        with tempfile.TemporaryDirectory(dir=dependency_root) as temporary:
            temporary_path = Path(temporary)
            _safe_extract(archive, temporary_path)
            extracted = temporary_path / f"wry-{version}"
            if not extracted.is_dir():
                raise SystemExit("WRY archive did not contain its pinned source root")
            shutil.move(str(extracted), source)
    patch = root / "patches" / f"wry-{version}-file-ipc-request-uri.patch"
    command = ["git", "-C", str(vendor), "apply", "--directory",
               f"rust/.minerva-deps/wry-{version}"]
    if subprocess.run(command + ["--reverse", "--check", str(patch)],
                      capture_output=True).returncode != 0:
        checked = subprocess.run(command + ["--check", str(patch)],
                                 capture_output=True, text=True)
        if checked.returncode:
            raise SystemExit(f"Cannot apply pinned WRY source patch.\n{checked.stderr}")
        subprocess.run(command + [str(patch)], check=True)
    print(f"Prepared checksum-pinned WRY {version}: {source}")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    vendor = root / "vendor/godot_wry"
    for patch in sorted((root / "patches").glob("godot_wry-*.patch")):
        command = ["git", "-C", str(vendor), "apply"]
        already_applied = subprocess.run(command + ["--reverse", "--check", str(patch)],
                                         capture_output=True).returncode == 0
        if already_applied:
            print(f"Already applied: {patch.name}")
            continue
        checked = subprocess.run(command + ["--check", str(patch)], capture_output=True, text=True)
        if checked.returncode:
            raise SystemExit(f"Cannot apply {patch.name}; local WRY edits were preserved.\n"
                             f"Resolve the patch conflict and rerun.\n{checked.stderr}")
        subprocess.run(command + [str(patch)], check=True)
        print(f"Applied: {patch.name}")
    _prepare_pinned_wry(root, vendor)


if __name__ == "__main__":
    main()
