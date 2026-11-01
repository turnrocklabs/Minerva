#!/usr/bin/env python3
"""Exercise the exported app's MCP helper or native document bridge."""

import json
import os
from contextlib import contextmanager
from dataclasses import dataclass
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import re
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from typing import Any

# Match the established tarball smoke allowance for a cold application start.
# Once startup returns to the scene tree, helper requests retain their
# independent two-second deadlines; this outer bound also covers native start.
TIMEOUT_SECONDS = 60
# Windows bridge passes ranged up to 80.7s (run 37616479739), while another
# run reached initialize but missed the 60s policy-ready window. Allow cold
# boot, two bounded 90s readiness attempts and the existing browser windows.
# This outer bound does not change transport or bridge assertion deadlines.
BRIDGE_TIMEOUT_SECONDS = 360


@contextmanager
def _required_releases(served_repositories: list[str] | None = None,
                       served_assets: list[str] | None = None) -> Iterator[str | None]:
    """Serve CI's per-repository snapshot through the same paged API paths."""
    snapshot = os.environ.get("MINERVA_REQUIRED_RELEASES_JSON")
    if not snapshot:
        yield None
        return
    pages_by_repo = json.loads(Path(snapshot).read_text(encoding="utf-8"))
    if not isinstance(pages_by_repo, dict):
        raise TypeError("required-release snapshot must be keyed by repository")
    releases_by_repo: dict[str, list[Any]] = {}
    for repo, pages in pages_by_repo.items():
        if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
                or not isinstance(pages, list)
                or any(not isinstance(page, list) for page in pages)):
            raise ValueError("required-release repository must contain an array of pages")
        releases_by_repo[repo] = [release for page in pages for release in page]

    # Only the Sheets probe opts into download observation. Redirect to the
    # original published URL, leaving the real archive and checksum untouched.
    asset_urls: dict[str, str] = {}
    if served_assets is not None:
        for releases in releases_by_repo.values():
            for release in releases:
                for asset in release.get("assets", []):
                    url = asset.get("browser_download_url", "")
                    if url:
                        path = f"/assets/{len(asset_urls)}"
                        asset_urls[path] = url
                        asset["browser_download_url"] = path

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            url = urlsplit(self.path)
            if url.path in asset_urls:
                original = asset_urls[url.path]
                if served_assets is not None:
                    served_assets.append(original)
                self.send_response(302)
                self.send_header("Location", original)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                query = parse_qs(url.query, strict_parsing=True, keep_blank_values=True)
                page = int(query.get("page", ["1"])[0])
                count = int(query.get("per_page", ["100"])[0])
                if (not url.path.startswith("/repos/") or not url.path.endswith("/releases")
                        or page < 1 or not 1 <= count <= 100):
                    raise ValueError("invalid release page")
                repo = url.path.removeprefix("/repos/").removesuffix("/releases")
            except ValueError:
                self.send_error(400)
                return
            if repo not in releases_by_repo:
                self.send_error(404)
                return
            if served_repositories is not None:
                served_repositories.append(repo)
            releases = releases_by_repo[repo]
            body = json.dumps(releases[(page - 1) * count:page * count]).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format: str, *_args: object) -> None:
            pass

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        if served_assets is not None:
            for releases in releases_by_repo.values():
                for release in releases:
                    for asset in release.get("assets", []):
                        path = asset.get("browser_download_url", "")
                        if path in asset_urls:
                            asset["browser_download_url"] = f"http://127.0.0.1:{server.server_port}{path}"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join()


def _seed_profile(root: Path, env: dict[str, str]) -> None:
    # Docket survives Minerva, so private profiles also need separate ports.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_probe:
        port_probe.bind(("127.0.0.1", 0))
        docket_port = port_probe.getsockname()[1]
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
        docket_profile = profile.with_name("Docket")
        docket_profile.mkdir(parents=True, exist_ok=True)
        (docket_profile / "docket_prefs.json").write_text(
            json.dumps({"mcp_port": docket_port}), encoding="utf-8")
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


# The helper probe writes its phases to stderr and the bridge probe to stdout;
# each run has only one probe's phases.
def _phases(text: str) -> list[str]:
    return re.findall(r"PACKAGED_(?:MCP_HELPER|BRIDGE)_PHASE=([^\r\n]+)", text)


# The app and its direct children (a child it is waiting on, such as a helper
# or a tool it ran, shows up here), without command-line arguments.
def _process_snapshot(pid: int) -> str:
    if os.name == "nt":
        command = ["powershell", "-NoProfile", "-Command",
                   "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); "
                   "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -eq %d -or "
                   "$_.ParentProcessId -eq %d } | Format-Table -AutoSize ProcessId, "
                   "ParentProcessId, Name, CreationDate | Out-String -Width 200" % (pid, pid)]
    else:
        command = ["ps", "-A", "-o", "pid=,ppid=,stat=,etime=,comm="]
    try:
        listing = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=10,
                                 check=False).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {error}"
    if os.name != "nt":
        listing = "\n".join(line for line in listing.splitlines()
                            if str(pid) in line.split()[:2])
    return listing.strip() or "no matching process"


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
        # macOS can refuse the group kill with EPERM (seen after the app had
        # exited). Cleanup is best-effort either way: the probe's own result
        # still decides the run.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            print(f"exported native probe cleanup: killpg({process.pid}) refused: {error}",
                  file=sys.stderr)


def _private_docket_running(pid: int, root: Path) -> bool:
    """Check identity before signalling, and distinguish exited Unix zombies."""
    command = subprocess.run(["ps", "-p", str(pid), "-o", "stat=", "-o", "comm="],
                             capture_output=True, text=True, encoding="utf-8", timeout=5, check=False)
    if command.returncode == 1:
        return False
    fields = command.stdout.strip().split(maxsplit=1)
    if command.returncode != 0 or len(fields) != 2:
        raise RuntimeError("private Docket process identity is unavailable")
    if fields[0].startswith("Z"):
        return False
    if sys.platform.startswith("linux"):
        try:
            executable = Path(f"/proc/{pid}/exe").resolve(strict=True)
        except FileNotFoundError:
            if not Path(f"/proc/{pid}").exists():
                return False
            raise
    else:
        executable = Path(fields[1]).resolve()
    if (not executable.is_relative_to(root.resolve())
            or executable.name.lower() not in ("docket", "docket.x86_64")):
        raise RuntimeError("private Docket pid no longer names a Docket executable inside its disposable root")
    return True


def _stop_private_docket(root: Path) -> None:
    """Retire only Docket registered in this disposable POSIX profile."""
    if os.name != "posix":
        return
    for path in root.rglob("instance.json"):
        if path.parent.name != "Docket":
            continue
        if not path.resolve().is_relative_to(root.resolve()):
            raise RuntimeError("private Docket registration escapes its disposable root")
        record = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(record, dict) or not isinstance(record.get("profile"), str) or Path(record["profile"]).resolve() != path.parent.resolve():
            raise RuntimeError("private Docket registration does not match its profile")
        pid = record.get("pid")
        if type(pid) is not int or pid <= 1:
            raise RuntimeError("private Docket registration has invalid pid")
        if not _private_docket_running(pid, root):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not _private_docket_running(pid, root):
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("private Docket did not exit before profile cleanup")
        except ProcessLookupError:
            pass
        print(f"exported native probe cleanup: private Docket pid={pid} exited")


@dataclass
class ProbeProfile:
    root: Path
    cleanup_error: str = ""


@contextmanager
def _private_profile() -> Iterator[ProbeProfile]:
    profile = ProbeProfile(Path(tempfile.mkdtemp(prefix="minerva-packaged-mcp-")))
    try:
        yield profile
    finally:
        try:
            _stop_private_docket(profile.root)
            shutil.rmtree(profile.root, ignore_errors=os.name == "nt")
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            profile.cleanup_error = str(error)
            print(f"exported native probe cleanup failed: {error}; retained {profile.root}", file=sys.stderr)


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--with-required-releases":
        with _required_releases() as releases_url:
            if releases_url is None:
                raise SystemExit("--with-required-releases requires MINERVA_REQUIRED_RELEASES_JSON")
            env = os.environ.copy()
            env["MINERVA_REQUIRED_RELEASES_URL"] = releases_url
            result = subprocess.call(sys.argv[2:], env=env)
            return result if result >= 0 else 128 - result
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("--bridge", "--warmup")):
        raise SystemExit("usage: verify-packaged-mcp-app.py <Minerva executable> [--bridge|--warmup]")
    executable = Path(sys.argv[1]).resolve()
    bridge_probe = len(sys.argv) == 3 and sys.argv[2] == "--bridge"
    warmup = len(sys.argv) == 3 and sys.argv[2] == "--warmup"
    if warmup and os.name != "nt":
        raise SystemExit("--warmup is Windows-only")
    if not executable.is_file():
        print(f"exported Minerva executable is missing: {executable}", file=sys.stderr)
        return 1

    with _private_profile() as profile, _required_releases() as releases_url:
        temporary_root = profile.root
        env = os.environ.copy()
        if releases_url is not None:
            env["MINERVA_REQUIRED_RELEASES_URL"] = releases_url
        _seed_profile(temporary_root, env)
        env["MINERVA_PACKAGED_BRIDGE_PROBE" if bridge_probe
            else "MINERVA_PACKAGED_MCP_HELPER_PROBE"] = "1"
        kwargs = {"start_new_session": True} if os.name != "nt" else {
            "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
        stdout_path = temporary_root / "minerva.stdout.log"
        stderr_path = temporary_root / "minerva.stderr.log"
        timed_out = False
        diagnostic = None
        diagnostic_log = None
        command = [str(executable), "--verbose"]
        if bridge_probe:
            command += ["--rendering-method", "gl_compatibility"]
            if sys.platform.startswith("linux"):
                command += ["--display-driver", "x11"]
        else:
            command.insert(1, "--headless")
        if sys.platform.startswith("linux"):
            command = ["stdbuf", "-oL", "-eL", *command]
        with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
            started_at = time.monotonic()
            process = subprocess.Popen(
                command, cwd=str(executable.parent), env=env,
                stdout=stdout_file, stderr=stderr_file, **kwargs)
            try:
                procdump_path = os.environ.get("MINERVA_PROCDUMP_PATH", "")
                dump_directory = os.environ.get("MINERVA_PROCDUMP_DUMP_DIR", "")
                if os.name == "nt" and procdump_path and dump_directory:
                    diagnostic_log = open(
                        Path(dump_directory) / f"procdump-{process.pid}.log", "wb")
                    diagnostic = subprocess.Popen(
                        [procdump_path, "-accepteula", "-ma", "-e", str(process.pid),
                         dump_directory],
                        stdout=diagnostic_log, stderr=subprocess.STDOUT)
                try:
                    process.wait(
                        timeout=BRIDGE_TIMEOUT_SECONDS if bridge_probe else (90 if warmup else TIMEOUT_SECONDS))
                except subprocess.TimeoutExpired:
                    timed_out = True
                    # Snapshot the last flushed phase while the hung process is
                    # still alive; teardown can itself block or change evidence.
                    timeout_stdout = stdout_path.read_text(
                        encoding="utf-8", errors="replace")
                    timeout_stderr = stderr_path.read_text(
                        encoding="utf-8", errors="replace")
                    phases = _phases(timeout_stdout + timeout_stderr)
                    print("exported native probe timeout snapshot: "
                          f"pid={process.pid}, last_phase={phases[-1] if phases else 'not-entered'}, "
                          f"stdout_bytes={len(timeout_stdout.encode())}, "
                          f"stderr_bytes={len(timeout_stderr.encode())}")
                    print("exported native probe process snapshot:\n" + _process_snapshot(process.pid))
            finally:
                # Unix can retire the app's process group after leader exit.
                # taskkill is best-effort once a Windows leader has exited; the
                # Actions runner performs final job-wide process cleanup.
                try:
                    _terminate_tree(process)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                finally:
                    try:
                        if diagnostic is not None:
                            try:
                                diagnostic.wait(timeout=10 if process.returncode else 2)
                            except subprocess.TimeoutExpired:
                                diagnostic.terminate()
                                try:
                                    diagnostic.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    diagnostic.kill()
                                    diagnostic.wait(timeout=5)
                    finally:
                        if diagnostic_log is not None:
                            diagnostic_log.close()
        elapsed_seconds = time.monotonic() - started_at
        stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
        stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
        if timed_out:
            sys.stdout.write(stdout)
            sys.stderr.write(stderr)
            phases = _phases(stdout + stderr)
            last_phase = phases[-1] if phases else "not-entered"
            print(
                "exported native probe timed out: "
                f"elapsed_seconds={elapsed_seconds:.1f}, returncode={process.returncode}, "
                f"last_phase={last_phase}",
                file=sys.stderr)
            return 1

    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    combined = stdout + "\n" + stderr
    fatal = re.search(
        r"SCRIPT ERROR|Can't open dynamic library|GDExtension dynamic library not found|Error loading extension"
        r"|\[GodotCef\] Failed to set executable permissions|\[CefTexture\] Failed to load CEF framework"
        r"|Failed to initialize CEF",
        combined)
    marker_name = "PACKAGED_BRIDGE_OK" if bridge_probe else "PACKAGED_MCP_HELPER_OK"
    marker_found = marker_name in stdout
    missing_cef_phases = []
    if os.name == "nt":
        required_cef_phases = (
            "[GodotCef] Retained module: libcef.dll",
            "[GodotCef] Finalize entry: initialized=true",
            "[GodotCef] Finalize after drain: browsers=0",
            "[GodotCef] Finalize after CefShutdown",
        )
        missing_cef_phases = [phase for phase in required_cef_phases if phase not in combined]
    passed = (
        process.returncode == 0
        and marker_found
        and fatal is None
        and not missing_cef_phases
        and not profile.cleanup_error
    )
    if not passed:
        print(
            "exported native probe failed: "
            f"elapsed_seconds={elapsed_seconds:.1f}, returncode={process.returncode}, "
            f"marker={marker_found}, fatal_log={fatal is not None}, "
            f"missing_cef_phases={missing_cef_phases}",
            file=sys.stderr)
    else:
        print(f"exported native {'warm-up' if warmup else 'probe'} passed in {elapsed_seconds:.1f}s")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
