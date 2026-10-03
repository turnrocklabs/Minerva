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
JOB_ROOT = Path("/tmp/job")
# Exact cold-cache diagnostics measured on Godot 4.6.2, absent after import.
# They are allowed only in the first import; the second has no exemptions.
COLD_IMPORT_DIAGNOSTICS = frozenset({
    "ERROR: Can't load dependency: 'res://assets/icons/green_toggle_icons/checkbutton_checked.png'.",
    "ERROR: Error loading custom project theme 'uid://cr3k2fgiaguik'",
    'ERROR: Failed loading resource: res://.godot/imported/checkbutton_checked.png-3fedb868e83f8f33b50413d28c676b2a.ctex.',
    'ERROR: Failed loading resource: res://.godot/imported/visibility_not_visible.png-0f110cd3cab4249a7162ff8dab36f972.ctex.',
    'ERROR: Failed loading resource: res://.godot/imported/visibility_visible.svg-49adc87bfd59c2f20f74534eb10da39a.ctex.',
    'ERROR: Failed loading resource: res://addons/markdownlabel/assets/fonts/Fira_Code/static/FiraCode-Regular.ttf.',
    'ERROR: Failed loading resource: res://assets/icons/eye_icons/visibility_not_visible.png.',
    'ERROR: Failed loading resource: res://assets/icons/eye_icons/visibility_visible.svg.',
    'ERROR: Failed loading resource: res://assets/icons/green_toggle_icons/checkbutton_checked.png.',
    'ERROR: Failed loading resource: res://assets/themes/blue_dark_mode.theme.',
    'ERROR: Failed to load script "res://addons/markdownlabel/plugin.gd" with error "Parse error".',
    'ERROR: Unable to open file: res://.godot/imported/checkbutton_checked.png-3fedb868e83f8f33b50413d28c676b2a.ctex.',
    'ERROR: Unable to open file: res://.godot/imported/visibility_not_visible.png-0f110cd3cab4249a7162ff8dab36f972.ctex.',
    'ERROR: Unable to open file: res://.godot/imported/visibility_visible.svg-49adc87bfd59c2f20f74534eb10da39a.ctex.',
    'SCRIPT ERROR: Parse Error: Preload file "res://addons/markdownlabel/icon.svg" has no resource loaders (unrecognized file extension).',
})



def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def git_paths(root, *args):
    names = subprocess.check_output(["git", "-C", str(root), *args])
    return [os.fsdecode(name) for name in names.split(b"\0") if name]


def changed_scripts(root, base):
    git(root, "rev-parse", "--verify", f"{base}^{{commit}}")
    return [root / name for name in git_paths(root, "diff", "--name-only", "-z",
                                            "--diff-filter=ACMR", base, "HEAD", "--", "*.gd")]


def plugin_checks(host, plugins, host_base, plugins_base, requested):
    """Whole-plugin compilation covers consumers omitted by changed-file gates."""
    names = git_paths(plugins, "ls-files", "-z", "--", "*.gd")
    changed = git_paths(plugins, "diff", "--name-only", "-z", plugins_base, "HEAD")
    known = {name.split("/", 1)[0] for name in names}
    changed_trees = {name.split("/", 1)[0] for name in changed}
    selected = set(requested) | (changed_trees & known)
    host_changes = git_paths(host, "diff", "--name-only", "-z", host_base, "HEAD", "--", "src")
    resources = ["res://" + name.removeprefix("src/") for name in host_changes]
    for name in names:
        source = (plugins / name).read_text(errors="replace") if resources else ""
        if any(resource in source for resource in resources):
            selected.add(name.split("/", 1)[0])
    # Dynamic/class-name dependencies are not statically discoverable.
    if host_changes or changed_trees - known:
        selected.update(name for name in ("cad", "pcb") if (plugins / name).is_dir())
    if set(requested) - known:
        raise ValueError("--plugin must name a tracked plugin script tree")
    return sorted(selected), [plugins / name for name in names if name.split("/", 1)[0] in selected]


def check_errors(output, rc, allowed=()):
    """Godot may report a compile error while returning zero. Fail on both."""
    diagnostics = re.findall(r"(?:SCRIPT ERROR:|^ERROR:)[^\n]*", output, re.MULTILINE)
    return rc != 0 or any(line not in allowed for line in diagnostics)


def run_gate(args):
    host = Path.cwd().resolve()
    plugins = host.parent / "minerva-plugins"
    if host.name != "Minerva" or not (plugins / ".git").exists():
        raise ValueError("requires literal sibling checkouts Minerva and minerva-plugins")
    if not os.environ.get("MINERVA_JOB_ID") or host.parent != JOB_ROOT:
        raise ValueError("run only in an isolated agent.py planned job")
    logs = host / "gate-evidence"
    logs.mkdir(exist_ok=False)
    env = dict(os.environ)
    for key, subdir in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                        ("XDG_RUNTIME_DIR", "runtime")):
        path = JOB_ROOT / "xdg" / subdir
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
                started = time.monotonic()
                rc = subprocess.run(argv, env=env, stdout=out, stderr=subprocess.STDOUT,
                                    timeout=seconds).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        output = path.read_text(errors="replace")
        receipt["steps"].append({"name": name, "command": argv, "exit_code": rc,
                                 "log": path.name, "elapsed_s": round(time.monotonic() - started, 3)})
        print(f"== {name}: exit {rc}", flush=True)
        return rc, output

    try:
        scripts = changed_scripts(host, args.host_base) + changed_scripts(plugins, args.plugins_base)
        selected, plugin_scripts = plugin_checks(host, plugins, args.host_base, args.plugins_base, args.plugin)
        receipt["plugins_under_test"] = selected
        receipt["plugin_scripts"] = [str(path.relative_to(host.parent)) for path in plugin_scripts]
        receipt["changed_scripts"] = [str(path.relative_to(host.parent)) for path in scripts]
        # Optional static contract sentinels also prove external res:// paths
        # on a runner-only revision where neither tree changed GDScript.
        extra = [(host.parent / name).resolve() for name in args.check_script]
        if any(path.suffix != ".gd" or not path.is_file() or
               not (path.is_relative_to(host) or path.is_relative_to(plugins)) for path in extra):
            raise ValueError("--check-script must name a .gd inside one of the assembled trees")
        receipt["extra_scripts"] = [str(path.relative_to(host.parent)) for path in extra]
        scripts = list(dict.fromkeys(scripts + plugin_scripts + extra))
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
        # class cache, both imports must return zero AND emit no error diagnostics.
        for number in (1, 2):
            rc, output = command(f"import-{number}", [args.godot, "--headless", "--path", "src", "--import"], 600)
            allowed = COLD_IMPORT_DIAGNOSTICS if number == 1 and receipt["godot"] == "4.6.2.stable.official.71f334935" else ()
            receipt["steps"][-1]["allowed_diagnostics"] = sorted(set(allowed).intersection(output.splitlines()))
            if check_errors(output, rc, allowed):
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
            raise ValueError("script checks failed: " + ", ".join(failed))
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
    parser.add_argument("--plugin", action="append", default=[], metavar="NAME",
                        help="also compile every tracked .gd of this plugin")
    parser.add_argument("--check-script", action="append", default=[], metavar="REPO/PATH.gd")
    return run_gate(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
