#!/usr/bin/env python3
"""Run the external required-provider case against a packaged app and real releases."""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from types import ModuleType

# Two sequential 60s state waits plus a 10s bootstrap leave 170s for the
# catalog, first published installation, CSV/native opens and cleanup. Keep
# the inner assertions/deadlines intact; phase markers identify any stall.
PROBE_TIMEOUT_SECONDS = 300


def helpers(root: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("packaged_helpers", root / "scripts/verify-packaged-mcp-app.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Packaged helper module is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--source-project", type=Path)
    parser.add_argument("--local-archive", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    probe = helpers(root)
    args.logs.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()
    with probe._private_profile() as profile, probe._required_releases() as base:
        env = os.environ.copy()
        probe._seed_profile(profile.root, env)
        # Keep startup offline until the case observes the fresh profile, then
        # let its public ensure fetch the captured repository listings.
        env["MINERVA_REQUIRED_RELEASES_URL"] = "http://127.0.0.1:9"
        fixture = profile.root / "release-fixture"
        fixture.mkdir()
        env["MINERVA_REQUIRED_SHEETS_FIXTURE"] = str(fixture)
        if args.local_archive is None:
            if base is None:
                raise ValueError("Published probe requires MINERVA_REQUIRED_RELEASES_JSON")
            env["MINERVA_REQUIRED_SHEETS_PUBLISHED"] = "1"
            env["MINERVA_REQUIRED_SHEETS_BASE"] = base
            marker = "PACKAGED_REQUIRED_SHEETS_OK"
        else:
            if args.source_project is None:
                raise ValueError("Local archive mode requires --source-project")
            shutil.copy2(args.local_archive, fixture / args.local_archive.name)
            with tarfile.open(args.local_archive) as archive:
                manifest_file = archive.extractfile("manifest.json")
                if manifest_file is None:
                    raise ValueError("Local Sheets archive has no manifest")
                version = json.load(manifest_file)["version"]
            if not isinstance(version, str) or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
                raise ValueError("Local Sheets archive has an invalid version")
            env["MINERVA_REQUIRED_SHEETS_ASSET"] = args.local_archive.name
            env["MINERVA_REQUIRED_SHEETS_VERSION"] = version
            env["MINERVA_REQUIRED_SHEETS_PUBLISHED"] = "0"
            marker = "SOURCE_REQUIRED_SHEETS_OK"
        # Test code and immutable fixtures stay outside the product package.
        script = profile.root / "required-sheets.gd"
        source = (root / "tests/godot/test_required_sheets.gd").read_text(encoding="utf-8")
        source = source.replace("res://test/", (root / "src/test").as_posix() + "/")
        script.write_text(source, encoding="utf-8")
        command = [str(app), "--rendering-method", "gl_compatibility", "--script", str(script)]
        if args.source_project is not None:
            command += ["--path", str(args.source_project.resolve())]
        log = args.logs / "required-sheets.log"
        with log.open("w", encoding="utf-8") as output:
            process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=os.name != "nt")
            try:
                status = process.wait(timeout=PROBE_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                if sys.platform == "darwin":
                    # Capture the live stack before cleanup kills the timed-out app.
                    output.write(f"REQUIRED_SHEETS_TIMEOUT_SAMPLE pid={process.pid}\n")
                    output.flush()
                    sample_path = args.logs / "required-sheets.sample.txt"
                    try:
                        sample = subprocess.run(
                            ["/usr/bin/sample", str(process.pid), "5", "-file", str(sample_path)],
                            stdout=output, stderr=subprocess.STDOUT,
                            text=True, timeout=10, check=False)
                        output.write(f"REQUIRED_SHEETS_TIMEOUT_SAMPLE exit={sample.returncode}\n")
                    except (OSError, subprocess.TimeoutExpired) as error:
                        output.write(f"REQUIRED_SHEETS_TIMEOUT_SAMPLE unavailable: {error}\n")
                    if sample_path.is_file():
                        output.write(sample_path.read_text(encoding="utf-8", errors="replace"))
                    else:
                        output.write("REQUIRED_SHEETS_TIMEOUT_SAMPLE report missing\n")
                    output.flush()
                raise
            finally:
                probe._terminate_tree(process)
                output.flush()
                print(log.read_text(encoding="utf-8", errors="replace"))
        text = log.read_text(encoding="utf-8", errors="replace")
        if status != 0 or "SCRIPT ERROR:" in text or marker not in text:
            raise RuntimeError(f"Required Sheets probe failed; see {log}")
    if profile.cleanup_error:
        raise RuntimeError(profile.cleanup_error)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
