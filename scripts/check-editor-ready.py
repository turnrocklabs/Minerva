#!/usr/bin/env python3
"""Check native editor dependencies without importing or launching the Godot project."""
import argparse
import configparser
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import queue
import runpy
import subprocess
import sys
import threading


def host_platform() -> str:
    return {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]


def host_voice_target() -> str:
    system = host_platform()
    machine = platform.machine().lower()
    if system == "macos" and machine in {"arm64", "aarch64"}:
        return "macos-arm64"
    if system == "macos" and machine in {"x86_64", "amd64"}:
        return "macos-amd64"
    if system == "linux" and machine in {"x86_64", "amd64"}:
        return "linux-x86_64"
    if system == "windows" and machine in {"x86_64", "amd64"}:
        return "windows-x86_64"
    raise RuntimeError(f"bundled Voice is not supported on {system}/{platform.machine()}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _voice_source_digest(plugin_dir: Path) -> str:
    helper_path = plugin_dir / "scripts" / "voice_runtime_inputs.py"
    namespace = runpy.run_path(str(helper_path), run_name="minerva_voice_runtime_inputs")
    return namespace["source_digest"](plugin_dir)


def voice_runtime_probe(root: Path) -> None:
    """Validate the host runtime, current source fingerprint, and MCP lifecycle."""
    target = host_voice_target()
    plugin_dir = root / "src" / "plugins" / "voice"
    runtime = plugin_dir / "runtime-build" / "stage" / target
    python_path = runtime / ("python.exe" if target.startswith("windows-") else "bin/python3")
    required = [
        python_path,
        runtime / "manifest.sha256",
        runtime / "input-artifacts.sha256",
        runtime / "source-inputs.sha256",
        runtime / "target-triple.txt",
        runtime / ("voice-worker.cmd" if target.startswith("windows-") else "voice-worker"),
    ]
    site_root = runtime / "Lib/site-packages" if target.startswith("windows-") else next(
        iter(sorted((runtime / "lib").glob("python*/site-packages"))), None)
    if site_root is None:
        raise RuntimeError(f"missing Python site-packages under {runtime}")
    required.extend([
        site_root / "minerva_voice_worker/__main__.py",
        site_root / "minerva_voice_worker/models/minerva_wakeword.onnx",
        site_root / "minerva_voice_worker/models/minerva_wakeword.onnx.data",
    ])
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError("missing required runtime file(s): " + ", ".join(missing))
    if os.name != "nt" and not os.access(python_path, os.X_OK):
        raise RuntimeError(f"runtime interpreter is not executable: {python_path}")
    recorded_target = (runtime / "target-triple.txt").read_text(encoding="utf-8").strip()
    if recorded_target != target:
        raise RuntimeError(f"runtime architecture is {recorded_target!r}, expected {target!r}")

    manifest_path = runtime / "manifest.sha256"
    runtime_resolved = runtime.resolve()
    manifest_entries = set()
    for line_number, line in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            expected, relative = line.split(None, 1)
        except ValueError as error:
            raise RuntimeError(f"invalid manifest line {line_number}") from error
        relative = relative.strip()
        candidate = (runtime / relative).resolve()
        try:
            canonical_relative = candidate.relative_to(runtime_resolved).as_posix()
        except ValueError as error:
            raise RuntimeError(f"manifest path escapes runtime: {relative}") from error
        manifest_entries.add(canonical_relative)
        if not candidate.is_file():
            raise RuntimeError(f"manifest file missing: {relative}")
        if _sha256(candidate) != expected:
            raise RuntimeError(f"manifest checksum mismatch: {relative}")
    if not manifest_entries:
        raise RuntimeError("runtime manifest is empty")
    required_manifest_entries = {
        path.resolve().relative_to(runtime_resolved).as_posix()
        for path in required if path != manifest_path
    }
    uncovered = sorted(required_manifest_entries - manifest_entries)
    if uncovered:
        raise RuntimeError("required runtime file(s) absent from manifest: " + ", ".join(uncovered))

    recorded_source = (runtime / "source-inputs.sha256").read_text(encoding="utf-8").strip()
    current_source = _voice_source_digest(plugin_dir)
    if recorded_source != current_source:
        raise RuntimeError("runtime is stale: Voice worker, recipe, or lockfile inputs changed")

    environment = dict(os.environ, PYTHONNOUSERSITE="1", MINERVA_VOICE_BUNDLE_ROOT=str(runtime),
                       MINERVA_VOICE_TARGET=target)
    architecture_result = subprocess.run(
        [str(python_path), "-B", "-I", "-c",
         "import json,platform,sysconfig;print(json.dumps({'machine':platform.machine(),'platform':sysconfig.get_platform()}))"],
        capture_output=True, text=True, encoding="utf-8", cwd=runtime, env=environment, timeout=30,
    )
    if architecture_result.returncode != 0:
        raise RuntimeError("runtime interpreter architecture probe failed: " +
                           architecture_result.stderr.strip()[-1000:])
    architecture = json.loads(architecture_result.stdout)
    machine = str(architecture.get("machine", "")).lower()
    sysconfig_platform = str(architecture.get("platform", "")).lower()
    expected_arches = {"arm64", "aarch64"} if target.endswith("-arm64") else {"x86_64", "amd64"}
    platform_matches = (any(arch in sysconfig_platform for arch in expected_arches)
                        or (target.startswith("macos-") and "universal2" in sysconfig_platform))
    if machine not in expected_arches or not platform_matches:
        raise RuntimeError(
            f"runtime interpreter architecture is {machine}/{sysconfig_platform}, expected {target}")

    request = json.dumps({
        "jsonrpc": "2.0", "id": "readiness", "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "minerva-readiness", "version": "1"},
        },
    }) + "\n"
    result = subprocess.run(
        [str(python_path), "-B", "-I", "-m", "minerva_voice_worker"],
        input=request, capture_output=True, text=True, encoding="utf-8",
        cwd=runtime, env=environment, timeout=90,
    )
    if result.returncode != 0:
        raise RuntimeError(f"worker exit={result.returncode}: {result.stderr.strip()[-1000:]}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError(f"worker emitted {len(lines)} response lines, expected one")
    response = json.loads(lines[0])
    protocol = response.get("result", {}).get("protocolVersion")
    if response.get("id") != "readiness" or protocol != "2025-06-18":
        raise RuntimeError(f"invalid initialize response: {response}")
    if "Traceback (most recent call last)" in result.stderr:
        raise RuntimeError(f"worker reported a traceback: {result.stderr.strip()[-1000:]}")


def helper_probe(path: Path) -> None:
    """Exercise the real helper, including rejecting invalid data and exiting on EOF."""
    with subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, encoding="utf-8") as process:
        lines = queue.Queue()

        def read_lines():
            for line in process.stdout:
                lines.put(line)
            lines.put(None)

        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        sequence = 0

        def call(op, **fields):
            nonlocal sequence
            sequence += 1
            request_id = str(sequence)
            process.stdin.write(json.dumps({"id": request_id, "op": op, **fields}) + "\n")
            process.stdin.flush()
            try:
                line = lines.get(timeout=3)
            except queue.Empty:
                raise RuntimeError(f"helper timed out during {op}") from None
            if line is None:
                raise RuntimeError(f"helper exited during {op}")
            result = json.loads(line)
            if result.get("id") != request_id or not result.get("ok"):
                raise RuntimeError(f"helper {op} failed: {result}")
            return result

        try:
            call("ping")
            handle = call("compile", schema_raw='{"type":"integer","minimum":1}', registry={})["handle"]
            if call("validate", handle=handle, instance_raw="2").get("valid") is not True:
                raise RuntimeError("helper rejected a valid instance")
            if call("validate", handle=handle, instance_raw='"bad"').get("valid") is not False:
                raise RuntimeError("helper accepted an invalid instance")
            call("compare_numbers", original_raw="0.5", adapted_raw="0.5")
            call("release", handle=handle)
            process.stdin.close()
            process.wait(timeout=3)
            reader.join(timeout=3)
            stderr = process.stderr.read()
            if process.returncode != 0 or stderr:
                raise RuntimeError(f"helper exit={process.returncode}: {stderr[:1000]}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def extension_library(root: Path, descriptor: str) -> tuple:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    # Only these sections are needed; dependency dictionaries use Godot syntax.
    text = (root / "src" / descriptor).read_text(encoding="utf-8").split("[dependencies]")[0]
    config.read_string(text)
    system = host_platform()
    arch = {"AMD64": "x86_64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
    features = {system, arch, "editor", "debug", "template_debug"}
    candidates = [(len(key.split(".")), value) for key, value in config["libraries"].items()
                  if set(key.split(".")).issubset(features)]
    if not candidates:
        raise RuntimeError(f"{descriptor} has no editor library for {system}/{arch}")
    resource = max(candidates)[1].strip('"')
    path = (root / "src" / resource.removeprefix("res://") if resource.startswith("res://")
            else root / "src" / Path(descriptor).parent / resource)
    if path.suffix == ".framework":
        plist_path = path / "Resources/Info.plist"
        if plist_path.is_file():
            with plist_path.open("rb") as source:
                executable = plistlib.load(source)["CFBundleExecutable"]
            path = path / executable
        else:
            path = path / path.stem
    return path, config["configuration"]["entry_symbol"].strip('"')


def load_library(path: Path, symbol: str, root: Path) -> None:
    # A child loader isolates bad native libraries and checks this host's architecture.
    directories = []
    if os.name == "nt":
        for directory in {path.parent, root / "src/bin"}:
            directories.append(os.add_dll_directory(str(directory)))
    library = ctypes.CDLL(str(path))
    if symbol:
        getattr(library, symbol)


def check_library(path: Path, symbol: str, root: Path) -> None:
    if not path.is_file():
        raise RuntimeError(f"missing {path}")
    result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--root", str(root),
                             "--load-library", str(path), "--symbol", symbol],
                            capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError(f"cannot load {path}: {result.stderr.strip()[-1500:] or result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--helper-only", action="store_true")
    parser.add_argument("--voice-only", action="store_true")
    parser.add_argument("--load-library", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--symbol", default="", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.helper_only and args.voice_only:
        parser.error("--helper-only and --voice-only are mutually exclusive")
    root = args.root.resolve()
    if args.load_library:
        load_library(args.load_library, args.symbol, root)
        return 0
    system = host_platform()
    print(f"Checking native editor dependencies for {system}/{platform.machine()}", flush=True)
    failures = []

    def check(label, operation):
        try:
            operation()
            print(f"PASS {label}", flush=True)
        except (OSError, RuntimeError, ValueError, KeyError, configparser.Error,
                subprocess.SubprocessError) as error:
            failures.append(label)
            print(f"FAIL {label}: {error}", flush=True)

    suffix = ".exe" if system == "windows" else ""
    if not args.voice_only:
        check("MCP schema helper: start, validate, reject, release, exit",
              lambda: helper_probe(root / "src/bin" / ("minerva-json-schema-helper" + suffix)))
    if not args.helper_only:
        check("Voice runtime: files, architecture, freshness, MCP initialize, clean exit",
              lambda: voice_runtime_probe(root))
    if not args.helper_only and not args.voice_only:
        shim = {"macos": "libminerva-vt.dylib", "linux": "libminerva-vt.so",
                "windows": "minerva-vt.dll"}[system]
        check("ghostty shim", lambda: check_library(root / "src/bin" / shim, "", root))
        for label, descriptor in (
            ("terminal / subprocess", "gdextension/terminal/terminal.gdextension"),
            ("SQLite", "addons/godot-sqlite/gdsqlite.gdextension"),
            ("FFmpeg", "addons/ffmpeg/ffmpeg.gdextension"),
        ):
            check(label, lambda d=descriptor: check_library(*extension_library(root, d), root))
        for label, descriptor in (
            ("WRY web panels", "addons/godot_wry/WRY.gdextension"),
            ("CEF plugin panels", "addons/godot_cef/godot_cef.gdextension"),
        ):
            try:
                path, _ = extension_library(root, descriptor)
                state = "present (not runtime-tested)" if path.is_file() else "not installed"
            except (OSError, RuntimeError, configparser.Error):
                state = "not installed for this host"
            print(f"OPTIONAL {label}: {state}")
        pdf = root / "src/bin" / ("minerva-host-pdf-" + system + suffix)
        print(f"OPTIONAL PDF sidecar: {'present (not runtime-tested)' if pdf.is_file() else 'not installed'}")
    if failures:
        command = (r"powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1"
                   if system == "windows" else "scripts/build-extensions.sh")
        if args.helper_only:
            command += " -HelperOnly" if system == "windows" else " --helper-only"
            print(f"Helper setup incomplete. Run: {command}")
        elif args.voice_only:
            command += " -VoiceOnly" if system == "windows" else " --voice-only"
            print(f"Voice runtime missing or stale. Run: {command}")
        else:
            print(f"Setup incomplete. Close Minerva and its editor before rebuilding. Run: {command}")
        return 1
    if args.helper_only:
        print("Helper ready.")
    elif args.voice_only:
        print("Voice runtime ready.")
    else:
        print("Native dependencies and Voice runtime passed. Open src/project.godot in Godot 4.6+ and verify plugin startup.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
