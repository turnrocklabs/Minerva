#!/usr/bin/env python3
"""Strict four-owner scenario oracle, only inside a pinned isolated planned job.

Native acquisition remains owned by dev-natives.py. Each suite gets its own
seeded profile and the project's real autoloads through an explicit test scene.
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
SUITES = ("policy_owner", "skill_owner", "trigger_feed", "prompt_and_session")
JOB_ROOT = Path("/tmp/job")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def isolated_env(root):
    env = dict(os.environ)
    for key, directory in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                           ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                           ("XDG_RUNTIME_DIR", "runtime")):
        path = root / directory
        path.mkdir(parents=True, mode=0o700)
        env[key] = str(path)
    env["MINERVA_TEST_PROFILE_ROOT"] = str(root)
    return env


def diagnostics(output):
    return re.findall(r"(?:SCRIPT ERROR:|ERROR:)[^\n]*", output)


def run(args):
    host = Path.cwd().resolve()
    plugins = host.parent / "minerva-plugins"
    if (host.parent != JOB_ROOT or host.name != "Minerva" or
            not os.environ.get("MINERVA_JOB_ID") or not (plugins / ".git").exists()):
        raise ValueError("requires an isolated planned job with pinned sibling checkouts")
    logs = host / "owner-oracle-evidence"
    logs.mkdir(exist_ok=False)
    receipt = {"schema": "minerva/ripout-owner-oracles-v1", "status": "failed",
               "job": os.environ["MINERVA_JOB_ID"], "started_at": time.time(),
               "repositories": {"Minerva": git(host, "rev-parse", "HEAD"),
                                "minerva-plugins": git(plugins, "rev-parse", "HEAD")},
               "suites": [{"suite": suite, "status": "not_executed", "passed": 0,
                           "failed": 0, "skipped": 0} for suite in SUITES], "steps": []}

    def command(name, argv, env, seconds):
        path = logs / f"{name}.log"
        started = time.monotonic()
        try:
            with path.open("w") as out:
                rc = subprocess.run(argv, cwd=host, env=env, stdout=out,
                                    stderr=subprocess.STDOUT, timeout=seconds).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        except OSError as error:
            path.write_text(f"prerequisite/process failure: {error}\n")
            rc = 127
        output = path.read_text(errors="replace")
        step = {"name": name, "command": argv, "exit_code": rc, "log": path.name,
                "log_sha256": digest(path), "elapsed_s": round(time.monotonic() - started, 3),
                "diagnostics": diagnostics(output)}
        receipt["steps"].append(step)
        print(f"{name}: exit {rc}", flush=True)
        return rc, output, step

    try:
        env = isolated_env(JOB_ROOT / "owner-oracles" / "prerequisites")
        receipt["prerequisite_environment"] = {key: value for key, value in env.items()
                                               if key.startswith("XDG_")}
        rc, version, _ = command("godot-version", [args.godot, "--version"], env, 30)
        if rc or not version.strip():
            raise ValueError("Godot prerequisite unavailable")
        receipt["godot"] = {"command": args.godot, "version": version.strip()}
        rc, _, _ = command("natives", ["python3", "-B", "scripts/container-build/dev-natives.py"], env, 900)
        if rc:
            raise ValueError("native/schema prerequisites unavailable; see natives.log")
        if not env.get("MINERVA_NATIVES_MANIFEST"):
            raise ValueError("MINERVA_NATIVES_MANIFEST prerequisite unavailable")
        manifest = Path(env["MINERVA_NATIVES_MANIFEST"])
        receipt["native_manifest"] = json.loads(manifest.read_text())
        receipt["native_manifest_sha256"] = digest(manifest)
        stamps = host / git(host, "rev-parse", "--git-dir") / "minerva-dev-natives"
        receipt["native_stamps"] = {p.stem: json.loads(p.read_text()) for p in sorted(stamps.glob("*.json"))}
        helper = host / "src/bin/minerva-json-schema-helper"
        # Controlled negative: override the checked path, never delete cached natives.
        if args.missing_helper:
            helper = JOB_ROOT / "owner-oracles" / "deliberately-absent-helper"
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise ValueError(f"JSON schema helper prerequisite unavailable: {helper}")
        receipt["schema_helper"] = {"path": str(helper), "resolved_path": str(helper.resolve()),
                                    "sha256": digest(helper)}
        for number in (1, 2):
            rc, output, _ = command(f"import-{number}", [args.godot, "--headless", "--path", "src", "--import"], env, 600)
            if rc or (number == 2 and diagnostics(output)):
                raise ValueError(f"import-{number} failed")
        for suite in receipt["suites"]:
            name = suite["suite"]
            profile = JOB_ROOT / "owner-oracles" / name
            env = isolated_env(profile)
            suite["environment"] = {key: value for key, value in env.items()
                                    if key.startswith("XDG_") or key == "MINERVA_TEST_PROFILE_ROOT"}
            rc, _, _ = command(f"{name}-profile", ["bash", "-c",
                'source scripts/lib/test-profile.sh && seed_test_profile "$1"',
                "owner-oracle-profile", str(profile)], env, 30)
            if rc:
                suite["status"] = "environment_failed"
                continue
            argv = [args.godot, "--headless", "--path", "src",
                    "res://test/helpers/docket_owner_scene.tscn", "--", name]
            rc, output, step = command(name, argv, env, args.timeout)
            summaries = re.findall(r"^=== Results: (\d+) passed, (\d+) failed ===$", output, re.MULTILINE)
            passed = len(re.findall(r"^PASS: ", output, re.MULTILINE))
            failed = len(re.findall(r"^FAIL: ", output, re.MULTILINE))
            failure_marker = bool(re.search(r"^FAILURES:", output, re.MULTILINE))
            skipped = len(re.findall(r"\bSKIP(?:PED)?\b", output, re.IGNORECASE))
            script_errors = re.findall(r"SCRIPT ERROR:[^\n]*", output)
            # Failure-path tests intentionally log engine errors; retain them as evidence.
            engine_diagnostics = {}
            for level in ("ERROR", "WARNING"):
                lines = re.findall(rf"^{level}:[^\n]*", output, re.MULTILINE)
                engine_diagnostics[level] = {"count": len(lines), "first_lines": lines[:5]}
            valid = (rc == 0 and not script_errors and skipped == 0 and failed == 0
                     and not failure_marker and len(summaries) == 1 and int(summaries[0][0]) == passed
                     and passed > 0 and int(summaries[0][1]) == 0)
            suite.update(status="passed" if valid else "failed", passed=passed,
                         failed=failed, skipped=skipped, summaries=summaries, command=argv,
                         script_errors=script_errors, engine_diagnostics=engine_diagnostics,
                         exit_code=rc, log=step["log"], log_sha256=step["log_sha256"])
        if not all(suite["status"] == "passed" for suite in receipt["suites"]):
            raise ValueError("four-owner oracle failed: every suite must execute with positive passes, no failures/script errors/skips")
        receipt["status"] = "passed"
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        receipt["error"] = str(error)
        print(f"FAIL: {error}", flush=True)
    finally:
        receipt["finished_at"] = time.time()
        receipt["log_sha256"] = {p.name: digest(p) for p in sorted(logs.glob("*.log"))}
        (logs / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--missing-helper", action="store_true", help="controlled failing prerequisite fixture; no suites execute")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        return run(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
