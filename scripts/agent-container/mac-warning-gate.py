#!/usr/bin/env python3
"""Stage macOS natives and run GATE-W in disposable clones (Python >=3.10)."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from types import ModuleType
from typing import TypedDict

TIMEOUT = 1200
SCHEMA = "minerva/mac-warning-gate-v1"


class ListingEntry(TypedDict):
    mode: int
    size: int
    mtime_ns: int
    link: str | None


def gate_module() -> ModuleType:
    """Reuse the warning gate's data-path policy rather than duplicating it."""
    path = Path(__file__).resolve().with_name("warning-gate.py")
    spec = importlib.util.spec_from_file_location("minerva_warning_gate", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load warning gate: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def native_files(staging: Path) -> list[tuple[Path, Path]]:
    """Staging layout shared with the original approved Mac dry run."""
    natives = staging / "natives"
    frameworks = natives / "macos-build/x/Minerva.app/Contents/Frameworks"
    pairs = [(natives / "terminal-macos" / name, Path("src/bin") / name) for name in (
        "libterminal.macos.template_debug.framework", "libterminal.macos.template_release.framework",
        "libminerva-vt.dylib")]
    pairs += [(natives / "sqlite-dl/x/bin" / name, Path("src/addons/godot-sqlite/bin") / name)
              for name in ("libgdsqlite.macos.template_debug.framework", "libgdsqlite.macos.template_release.framework")]
    pairs += [(frameworks / name, Path("src/addons/godot_cef/bin/universal-apple-darwin") / name)
              for name in ("Godot CEF.framework", "Godot CEF.app")]
    # This explicit stand-in supports warning comparison, not native-load coverage.
    pairs.append((frameworks / "libgdffmpeg.macos.template_release.framework",
                  Path("src/addons/ffmpeg/macos/libgdffmpeg.macos.template_debug.framework")))
    pairs += [(frameworks / name, Path("src/addons/ffmpeg/macos") / name) for name in (
        "libavcodec.dylib", "libavfilter.dylib", "libavformat.dylib", "libavutil.dylib",
        "libswresample.dylib", "libswscale.dylib")]
    return pairs


def stage(staging: Path, job: Path) -> int:
    clone = Path.cwd().resolve()
    relative = clone.relative_to(job)
    allowed = relative.parts == ("Minerva",) or (
        len(relative.parts) == 2 and re.fullmatch(r"warning-base-[0-9a-f]{12}", relative.parts[0])
        and relative.parts[1] == "Minerva")
    marker = json.loads((job / "mac-job.json").read_text())
    if not allowed or marker.get("schema") != SCHEMA or not (clone / "src/project.godot").is_file():
        raise ValueError("Native staging requires a disposable clone created by the run command")
    for source, relative_path in native_files(staging):
        destination = clone / relative_path
        if not destination.resolve().is_relative_to(clone):
            raise ValueError(f"Native destination escapes the disposable clone: {destination}")
        if destination.exists() or destination.is_symlink():
            raise FileExistsError(f"Refusing to overwrite native output: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination)
    print("Staged Mac natives (ffmpeg release-as-debug; native-load coverage excluded)", flush=True)
    return 0


def listing(root: Path) -> dict[str, ListingEntry]:
    """Metadata-only before/after evidence; do not read live file contents."""
    result: dict[str, ListingEntry] = {}
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            stat = path.lstat()
            result[str(path.relative_to(root))] = {
                "mode": stat.st_mode, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns,
                "link": os.readlink(path) if path.is_symlink() else None,
            }
    return result


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def stop_group(process: subprocess.Popen) -> None:
    """Retire the whole owned group, including children after the parent exits."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(args: argparse.Namespace, staging: Path) -> int:
    if sys.platform != "darwin":
        raise ValueError("The Mac runner requires macOS; use warning-gate.py for Linux jobs")
    gate = gate_module()
    # Resolve the staging inventory before making a job or launching anything.
    godot = staging / "godot/Godot.app/Contents/MacOS/Godot"
    for source in [godot, *(source for source, _ in native_files(staging))]:
        if not source.exists():
            raise FileNotFoundError(f"Missing staged Mac artifact: {source}")
    if not any(path.is_file() for path in (godot.parent / "_sc_", staging / "godot/_sc_")):
        raise ValueError("Durable Mac staging requires _sc_ beside Godot or outside its .app bundle")
    repo = args.repo.resolve()
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--verify", f"{args.head}^{{commit}}"], text=True).strip()
    base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--verify", f"{args.base}^{{commit}}"], text=True).strip()
    if args.output:
        output = args.output.resolve()
        gate.refuse_live_data(output)
        if output.is_relative_to(repo):
            raise ValueError("Evidence/job output must be outside the source checkout")
        output.mkdir(parents=True, exist_ok=False)
    else:
        parent = Path(tempfile.gettempdir()).resolve()
        gate.refuse_live_data(parent)
        if parent.is_relative_to(repo):
            raise ValueError("Temporary job parent must be outside the source checkout")
        output = Path(tempfile.mkdtemp(prefix="minerva-gatew-mac-")).resolve()
    job = output / "job"
    job.mkdir()
    save(job / "mac-job.json", {"schema": SCHEMA, "head": head, "base": base})
    binary, env = gate.godot_environment(str(godot), job)
    env["MINERVA_JOB_ID"] = "mac-gatew-" + uuid.uuid4().hex
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    clone = job / "Minerva"
    subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(repo), str(clone)], check=True)
    subprocess.run(["git", "-C", str(clone), "checkout", "--quiet", "--detach", head], check=True)
    natives_cmd = shlex.join([sys.executable, "-B", str(Path(__file__).resolve()), "stage",
                             "--staging-root", str(staging), "--job-root", str(job)])
    gate_script = Path(__file__).resolve().with_name("warning-gate.py")
    command = [sys.executable, "-B", str(gate_script),
               "--base", base, "--godot", binary, "--job-root", str(job), "--natives-cmd", natives_cmd]
    live = gate.live_godot_data()
    before = listing(live)
    save(output / "live-before.json", before)
    started = time.monotonic()
    timed_out = False
    with (output / "run.log").open("w") as log:
        process = subprocess.Popen(command, cwd=clone, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            code = 124
        finally:
            # Retire only descendants in this disposable job's process group.
            stop_group(process)
    after = listing(live)
    save(output / "live-after.json", after)
    changed = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
    save(output / "live-changed.json", changed)
    result = {
        "schema": SCHEMA, "head": head, "base": base, "staging_root": str(staging),
        "command": command, "returncode": code, "timeout_s": TIMEOUT, "timed_out": timed_out,
        "elapsed_s": round(time.monotonic() - started, 1), "home": env["HOME"],
        "live_listing_unchanged": not changed, "live_changed_count": len(changed),
        "native_load_coverage": False,
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "warning_gate_sha256": hashlib.sha256(gate_script.read_bytes()).hexdigest(),
        "warning_receipt": str(clone / "gate-evidence/warning-receipt.json"),
    }
    save(output / "mac-receipt.json", result)
    print(json.dumps(result, indent=2), flush=True)
    return code if code else int(bool(changed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    execute = commands.add_parser("run", help="Create a fresh job and run both revisions")
    execute.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    execute.add_argument("--head", required=True)
    execute.add_argument("--base", required=True)
    execute.add_argument("--output", type=Path, help="New evidence/job directory (default: a fresh temp directory)")
    copy = commands.add_parser("stage", help="Native staging step invoked by warning-gate.py")
    copy.add_argument("--job-root", required=True, type=Path)
    for command in (execute, copy):
        command.add_argument("--staging-root", type=Path, default=os.environ.get("MINERVA_GATEW_MAC_ROOT"),
                             help="Durable editor/native staging root; defaults to MINERVA_GATEW_MAC_ROOT")
    args = parser.parse_args()
    if args.staging_root is None:
        parser.error("Set MINERVA_GATEW_MAC_ROOT or pass --staging-root")
    staging = args.staging_root.resolve()
    try:
        return run(args, staging) if args.command == "run" else stage(staging, args.job_root.resolve())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Mac GATE-W failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
