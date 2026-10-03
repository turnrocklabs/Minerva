#!/usr/bin/env python3
"""Static gates only, in a planned job with Minerva + minerva-plugins siblings.

No suites or application scenes run. Plugin scripts compile in the real host
project context; the plugin repository does not have its own Godot project.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def changed_scripts(root, base):
    git(root, "rev-parse", "--verify", f"{base}^{{commit}}")
    names = subprocess.check_output(["git", "-C", str(root), "diff", "--name-only", "-z",
                                     "--diff-filter=ACMR", base, "HEAD", "--", "*.gd"])
    return [root / os.fsdecode(name) for name in names.split(b"\0") if name]


def check_errors(output, rc):
    """Godot may report a compile error while returning zero. Fail on both."""
    return rc != 0 or bool(re.search(r"(?:SCRIPT ERROR:|^ERROR:)", output, re.MULTILINE))


def run_gate(args):
    host = Path.cwd().resolve()
    plugins = host.parent / "minerva-plugins"
    if host.name != "Minerva" or not (plugins / ".git").exists():
        raise ValueError("requires literal sibling checkouts Minerva and minerva-plugins")
    if not os.environ.get("MINERVA_JOB_ID") or host.parent != Path("/tmp/job"):
        raise ValueError("run only in an isolated agent.py planned job")
    logs = host / "gate-evidence"
    logs.mkdir(exist_ok=False)
    env = dict(os.environ)
    for key, subdir in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                        ("XDG_RUNTIME_DIR", "runtime")):
        path = Path("/tmp/job/xdg") / subdir
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        env[key] = str(path)
    receipt = {"schema": "minerva/two-repo-gate-v1", "job": os.environ["MINERVA_JOB_ID"],
               "started_at": time.time(), "repositories": {
                   "Minerva": {"revision": git(host, "rev-parse", "HEAD"), "base": args.host_base},
                   "minerva-plugins": {"revision": git(plugins, "rev-parse", "HEAD"), "base": args.plugins_base}},
               "environment": {key: value for key, value in env.items() if key.startswith("XDG_")},
               "steps": [], "status": "failed"}

    def command(name, argv, seconds):
        path = logs / f"{name}.log"
        try:
            with path.open("w") as out:
                rc = subprocess.run(argv, env=env, stdout=out, stderr=subprocess.STDOUT,
                                    timeout=seconds).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        output = path.read_text(errors="replace")
        receipt["steps"].append({"name": name, "command": argv, "exit_code": rc,
                                 "log": path.name})
        print(f"== {name}: exit {rc}", flush=True)
        return rc, output

    try:
        scripts = changed_scripts(host, args.host_base) + changed_scripts(plugins, args.plugins_base)
        receipt["changed_scripts"] = [str(path.relative_to(host.parent)) for path in scripts]
        # Optional static contract sentinels also prove external res:// paths
        # on a runner-only revision where neither tree changed GDScript.
        extra = [(host.parent / name).resolve() for name in args.check_script]
        if any(path.suffix != ".gd" or not path.is_file() or
               not (path.is_relative_to(host) or path.is_relative_to(plugins)) for path in extra):
            raise ValueError("--check-script must name a .gd inside one of the assembled trees")
        receipt["extra_scripts"] = [str(path.relative_to(host.parent)) for path in extra]
        scripts = list(dict.fromkeys(scripts + extra))
        rc, version = command("godot-version", [args.godot, "--version"], 30)
        if rc:
            raise ValueError("Godot unavailable")
        receipt["godot"] = version.strip()
        rc, _ = command("natives", ["python3", "-B", "scripts/container-build/dev-natives.py"], 900)
        if rc:
            raise ValueError("native/schema prerequisites unavailable; see natives.log")
        manifest = Path(env["MINERVA_NATIVES_MANIFEST"])
        receipt["native_manifest"] = json.loads(manifest.read_text())
        stamps = host / git(host, "rev-parse", "--git-dir") / "minerva-dev-natives"
        receipt["native_stamps"] = {path.stem: json.loads(path.read_text()) for path in stamps.glob("*.json")}
        # Match the existing native-backed dev gate: initial scan establishes
        # class cache, final import must return zero AND emit no script errors.
        for number in (1, 2):
            rc, output = command(f"import-{number}", [args.godot, "--headless", "--path", "src", "--import"], 600)
            if rc or (number == 2 and re.search(r"(?:SCRIPT ERROR:|^ERROR:)", output, re.MULTILINE)):
                raise ValueError(f"import-{number} failed")
        failed = []
        for number, path in enumerate(scripts):
            relative = os.path.relpath(path, host / "src")
            rc, output = command(f"check-{number:04d}", [args.godot, "--headless", "--path", "src",
                                                       "--check-only", "--script", f"res://{relative}"], 120)
            bad = check_errors(output, rc)
            receipt["steps"][-1].update(script=str(path.relative_to(host.parent)), passed=not bad)
            if bad:
                failed.append(str(path))
        if failed:
            raise ValueError("changed script checks failed: " + ", ".join(failed))
        receipt["status"] = "passed"
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        receipt["error"] = str(error)
        print(f"FAIL: {error}", flush=True)
    finally:
        receipt["finished_at"] = time.time()
        receipt["log_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in logs.glob("*.log")}
        (logs / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-base", required=True)
    parser.add_argument("--plugins-base", required=True)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--check-script", action="append", default=[], metavar="REPO/PATH.gd")
    return run_gate(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
