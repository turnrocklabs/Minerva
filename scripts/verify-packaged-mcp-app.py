#!/usr/bin/env python3
"""Exercise the exported app's helper resolver with isolated user data."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

TIMEOUT_SECONDS = 30


def _seed_profile(root: Path, env: dict[str, str]) -> None:
    for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        directory = root / key.lower()
        directory.mkdir(parents=True)
        env[key] = str(directory)
    env["HOME"] = str(root / "home")
    env["APPDATA"] = str(root / "appdata")
    env["LOCALAPPDATA"] = str(root / "localappdata")
    for key in ("HOME", "APPDATA", "LOCALAPPDATA"):
        Path(env[key]).mkdir(parents=True, exist_ok=True)

    relative = Path("Godot") / "app_userdata" / "Minerva"
    profile_roots = {
        Path(env["XDG_DATA_HOME"]) / "godot" / "app_userdata" / "Minerva",
        Path(env["APPDATA"]) / relative,
        Path(env["HOME"]) / "Library" / "Application Support" / relative,
    }
    config = "[Voice]\nturnrock_enabled=false\nalways_listening=false\n\n[HCP]\nauto_connect=false\n"
    for profile in profile_roots:
        profile.mkdir(parents=True, exist_ok=True)
        (profile / "config_file.cfg").write_text(config, encoding="utf-8")
        disabled_servers = [{
            "name": name,
            "type": "http",
            "url": "http://127.0.0.1:9",
            "enabled": False,
            "auto_connect": False,
            "origin": "known",
        } for name in ("nudge", "cobrowser")]
        (profile / "mcp_config.json").write_text(
            json.dumps({"version": 3, "servers": disabled_servers}), encoding="utf-8")


def _terminate_tree(process: subprocess.Popen[str]) -> None:
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                check=False, timeout=5)
        except subprocess.TimeoutExpired:
            pass
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-packaged-mcp-app.py <Minerva executable>")
    executable = Path(sys.argv[1]).resolve()
    if not executable.is_file():
        print(f"exported Minerva executable is missing: {executable}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(
            prefix="minerva-packaged-mcp-",
            ignore_cleanup_errors=os.name == "nt") as temporary:
        temporary_root = Path(temporary)
        env = os.environ.copy()
        _seed_profile(temporary_root, env)
        env["MINERVA_PACKAGED_MCP_HELPER_PROBE"] = "1"
        kwargs = {"start_new_session": True} if os.name != "nt" else {
            "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
        stdout_path = temporary_root / "minerva.stdout.log"
        stderr_path = temporary_root / "minerva.stderr.log"
        timed_out = False
        with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
            process = subprocess.Popen(
                [str(executable), "--headless"], cwd=str(executable.parent), env=env,
                stdout=stdout_file, stderr=stderr_file, **kwargs)
            try:
                process.wait(timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                timed_out = True
            # Unix can retire the app's process group after leader exit.
            # taskkill is best-effort once a Windows leader has exited; the
            # Actions runner performs final job-wide process cleanup.
            _terminate_tree(process)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
        stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
        if timed_out:
            sys.stdout.write(stdout)
            sys.stderr.write(stderr)
            print("exported MCP helper probe timed out", file=sys.stderr)
            return 1

    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    combined = stdout + "\n" + stderr
    fatal = re.search(
        r"SCRIPT ERROR|Can't open dynamic library|GDExtension dynamic library not found|Error loading extension"
        r"|\[GodotCef\] Failed to set executable permissions|\[CefTexture\] Failed to load CEF framework"
        r"|Failed to initialize CEF",
        combined)
    return 0 if (process.returncode == 0
                 and "PACKAGED_MCP_HELPER_OK" in stdout
                 and fatal is None) else 1


if __name__ == "__main__":
    raise SystemExit(main())
