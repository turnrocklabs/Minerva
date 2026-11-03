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
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from types import ModuleType
from typing import NoReturn, TypedDict

TIMEOUT = 1200
SCHEMA = "minerva/mac-warning-gate-v1"


class ListingEntry(TypedDict):
    mode: int
    size: int
    mtime_ns: int
    link: str | None


class LiveChanges(TypedDict):
    created: list[str]
    removed: list[str]
    metadata_failures: list[str]
    mtime_warnings: list[str]
    docket_warnings: list[str]


def docket_owned(key: str, before: dict[str, ListingEntry], after: dict[str, ListingEntry]) -> bool:
    """The live Docket namespace is ambient, but never follow or exempt symlinks."""
    parts = key.split("/")
    if parts[:2] != ["app_userdata", "Docket"] or any(part in ("", ".", "..") for part in parts):
        return False
    roots = [snapshot.get("app_userdata/Docket") for snapshot in (before, after)]
    if not any(roots) or any(entry is not None and not stat.S_ISDIR(entry["mode"]) for entry in roots):
        return False
    for length in range(1, len(parts) + 1):
        ancestor = "/".join(parts[:length])
        for snapshot in (before, after):
            entry = snapshot.get(ancestor)
            if entry is not None and (stat.S_ISLNK(entry["mode"]) or entry["link"] is not None):
                return False
    return True


def live_changes(before: dict[str, ListingEntry], after: dict[str, ListingEntry]) -> LiveChanges:
    """Keep raw changes visible; Docket-owned entries and file mtimes only warn."""
    created = []
    removed = []
    failures = []
    warnings = []
    docket_warnings = []
    for key in sorted(before.keys() | after.keys()):
        old, new = before.get(key), after.get(key)
        if old == new:
            continue
        if docket_owned(key, before, after):
            docket_warnings.append(key)
            continue
        if old is None:
            created.append(key)
            continue
        if new is None:
            removed.append(key)
            continue
        fields = {field for field in old.keys() | new.keys() if old.get(field) != new.get(field)}
        if fields == {"mtime_ns"} and stat.S_ISREG(old["mode"]):
            warnings.append(key)
        else:
            failures.append(key)
    return {"created": created, "removed": removed,
            "metadata_failures": failures, "mtime_warnings": warnings,
            "docket_warnings": docket_warnings}


def minerva_processes() -> list[int]:
    result = subprocess.run(["pgrep", "-x", "Minerva"], check=False, capture_output=True, text=True, timeout=5)
    if result.returncode == 1:
        return []
    result.check_returncode()
    return [int(pid) for pid in result.stdout.split()]


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
    def fail(error: OSError) -> NoReturn:
        raise error

    result: dict[str, ListingEntry] = {}
    for folder, dirs, files in os.walk(root, followlinks=False, onerror=fail):
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
    running_before = minerva_processes()
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
    running_after = minerva_processes()
    save(output / "live-after.json", after)
    changed = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
    save(output / "live-changed.json", changed)
    changes = live_changes(before, after)
    save(output / "live-diff.json", changes)
    hard_failure = bool(changes["created"] or changes["removed"] or changes["metadata_failures"])
    wrapper_code = code if code else int(hard_failure)
    if changes["mtime_warnings"]:
        print(f"WARNING: {len(changes['mtime_warnings'])} existing file(s) changed mtime only; "
              "quit Minerva for a clean listing", flush=True)
    if changes["docket_warnings"]:
        print(f"WARNING: {len(changes['docket_warnings'])} Docket-owned entry change(s) treated as ambient; "
              "quit Docket for a clean listing", flush=True)
    result = {
        "schema": SCHEMA, "head": head, "base": base, "staging_root": str(staging),
        "command": command, "returncode": code, "timeout_s": TIMEOUT, "timed_out": timed_out,
        "elapsed_s": round(time.monotonic() - started, 1), "home": env["HOME"],
        "live_listing_unchanged": not changed, "live_changed_count": len(changed),
        "live_changes": changes, "wrapper_returncode": wrapper_code,
        "minerva_running_before": bool(running_before), "minerva_running_after": bool(running_after),
        "minerva_pids_before": running_before, "minerva_pids_after": running_after,
        "native_load_coverage": False,
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "warning_gate_sha256": hashlib.sha256(gate_script.read_bytes()).hexdigest(),
        "warning_receipt": str(clone / "gate-evidence/warning-receipt.json"),
    }
    save(output / "mac-receipt.json", result)
    print(json.dumps(result, indent=2), flush=True)
    return wrapper_code


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
