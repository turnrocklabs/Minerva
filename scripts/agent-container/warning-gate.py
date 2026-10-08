#!/usr/bin/env python3
"""GATE-W: GDScript analyzer warnings may not increase from a base commit to HEAD.

Owns the warning ratchet of the engineering-constraints pilot (Master:01a11a91820a).
Analyzer warnings only come from the editor, so each tree is imported and then
scanned through a headless editor's language server. There is no committed
baseline: the base commit is cloned and scanned in the same job.

A warning's identity is (file, code, message with line numbers normalised); the
gate fails when any identity's count rises. In src/test, untyped_declaration and
unsafe_* are informational. With --refactor, changed files are compared by
per-code totals instead, so moved or renamed code keeps its warnings.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True
JOB_ROOT = Path("/tmp/job")
# Off by default in Godot; the pilot's G3 typing rule needs them reported.
TYPING_WARNINGS = ("untyped_declaration", "unsafe_property_access", "unsafe_method_access",
                   "unsafe_cast", "unsafe_call_argument")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def enable_typing_warnings(root):
    """The editor ignores override.cfg, so patch the job copy's project.godot."""
    path = root / "src/project.godot"
    lines = "".join(f"gdscript/warnings/{name}=1\n" for name in TYPING_WARNINGS)
    text = path.read_text()
    if re.search(r"(?m)^\[debug\]$", text):
        text = re.sub(r"(?m)^\[debug\]\n", lambda match: match[0] + "\n" + lines, text, count=1)
    else:
        text += "\n[debug]\n\n" + lines
    path.write_text(text)


class LanguageServer:
    """Minimal LSP client over the editor's TCP port."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buffer = b""
        self.next_id = 0

    def send(self, method, params, request=True):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request:
            self.next_id += 1
            message["id"] = self.next_id
        body = json.dumps(message).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        return message.get("id")

    def receive(self, timeout):
        self.sock.settimeout(timeout)
        while b"\r\n\r\n" not in self.buffer:
            self.buffer += self.sock.recv(1 << 20)
        head, rest = self.buffer.split(b"\r\n\r\n", 1)
        size = int(re.search(rb"Content-Length: *(\d+)", head, re.I)[1])
        while len(rest) < size:
            rest += self.sock.recv(1 << 20)
        self.buffer = rest[size:]
        return json.loads(rest[:size])

    def wait(self, predicate, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            message = self.receive(max(0.1, end - time.monotonic()))
            if predicate(message):
                return message
        raise TimeoutError


def identity(path, diagnostic):
    message = diagnostic["message"]
    match = re.match(r"\(([A-Z_]+)\): ", message)
    code = match[1].lower() if match else ("error" if diagnostic.get("severity") == 1 else "other")
    message = re.sub(r"\bline \d+", "line N", message[match.end():] if match else message)
    return path, code, message


def scan(root, godot, env, log, port):
    """Return a Counter of warning identities for every first-party script under root/src."""
    project = root / "src"
    files = sorted(path for path in project.rglob("*.gd")
                   if not {"addons", ".godot"} & set(path.relative_to(project).parts))
    found = Counter()
    with log.open("w") as out:
        editor = subprocess.Popen([godot, "--headless", "--editor", "--path", "src", "--lsp-port", str(port)],
                                  cwd=root, env=env, stdout=out, stderr=subprocess.STDOUT)
        try:
            started = time.monotonic()
            while True:
                try:
                    server = LanguageServer(port)
                    break
                except OSError:
                    if editor.poll() is not None or time.monotonic() - started > 600:
                        raise ValueError(f"editor language server unavailable; see {log.name}")
                    time.sleep(1)
            request = server.send("initialize", {"processId": None, "rootUri": project.as_uri(),
                                                 "rootPath": str(project), "capabilities": {}})
            server.wait(lambda message: message.get("id") == request, 600)
            server.send("initialized", {}, request=False)
            for path in files:
                uri = path.as_uri()
                server.send("textDocument/didOpen", {"textDocument": {
                    "uri": uri, "languageId": "gdscript", "version": 1,
                    "text": path.read_text(errors="replace")}}, request=False)
                reply = server.wait(lambda message: message.get("method") == "textDocument/publishDiagnostics"
                                    and message["params"]["uri"] == uri, 60)
                server.send("textDocument/didClose", {"textDocument": {"uri": uri}}, request=False)
                name = str(path.relative_to(root))
                found.update(identity(name, diagnostic) for diagnostic in reply["params"]["diagnostics"])
        finally:
            editor.terminate()
            try:
                editor.wait(20)
            except subprocess.TimeoutExpired:
                editor.kill()
    return found, len(files)


def informational(path, code):
    return path.startswith("src/test/") and (code == "untyped_declaration" or code.startswith("unsafe_"))


def regressions(base, head, changed, refactor):
    """Identities (or, for a refactor's changed files, codes) whose count rose."""
    risen = []
    for key in sorted(head):
        path, code, _ = key
        if head[key] > base[key] and not informational(path, code) and not (refactor and path in changed):
            risen.append({"file": path, "code": code, "message": key[2], "base": base[key], "head": head[key]})
    if refactor:
        def totals(scan):
            return Counter({code: count for (path, code, _), count in scan.items()
                            if path in changed and not informational(path, code)})
        before, after = totals(base), totals(head)
        risen += [{"files": "refactor touch-set", "code": code, "base": before[code], "head": after[code]}
                  for code in sorted(after) if after[code] > before[code]]
    return risen


def run_gate(args):
    host = Path.cwd().resolve()
    if not (host / "src/project.godot").is_file() or not os.environ.get("MINERVA_JOB_ID") or host.parent != JOB_ROOT:
        raise SystemExit("run only from a Minerva checkout in an isolated agent.py planned job")
    logs = host / "gate-evidence"
    logs.mkdir(exist_ok=True)
    env = dict(os.environ)
    env["MINERVA_REQUIRED_RELEASES_URL"] = "http://127.0.0.1:9/required-releases.json"
    for key, subdir in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"),
                        ("XDG_RUNTIME_DIR", "runtime")):
        path = JOB_ROOT / "xdg" / subdir
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        env[key] = str(path)
    receipt = {"schema": "minerva/warning-gate-v1", "job": os.environ["MINERVA_JOB_ID"],
               "head": git(host, "rev-parse", "HEAD"), "refactor": args.refactor, "status": "failed"}

    def step(name, argv, cwd, seconds):
        with (logs / f"{name}.log").open("w") as out:
            try:
                rc = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT,
                                    timeout=seconds).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        print(f"== {name}: exit {rc}", flush=True)
        if rc:
            raise ValueError(f"{name} failed; see {name}.log")

    def prepare_and_scan(root, prefix, port):
        started = time.monotonic()
        step(f"{prefix}natives", ["python3", "-B", "scripts/container-build/dev-natives.py"], root, 900)
        step(f"{prefix}import", [args.godot, "--headless", "--path", "src", "--import"], root, 900)
        enable_typing_warnings(root)
        found, files = scan(root, args.godot, env, logs / f"{prefix}editor.log", port)
        receipt[f"{prefix}scan"] = {"files": files, "diagnostics": sum(found.values()),
                                    "elapsed_s": round(time.monotonic() - started, 1)}
        print(f"== {prefix}scan: {files} files, {sum(found.values())} diagnostics", flush=True)
        return found

    try:
        receipt["base"] = git(host, "rev-parse", "--verify", f"{args.base}^{{commit}}")
        changed = set(git(host, "diff", "--name-only", "--no-renames", receipt["base"], "HEAD", "--", "src").splitlines())
        head = prepare_and_scan(host, "head-", 47123)
        baseline = JOB_ROOT / f"warning-base-{receipt['base'][:12]}" / "Minerva"
        subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", str(host), str(baseline)], check=True)
        subprocess.run(["git", "-C", str(baseline), "checkout", "-q", "--detach", receipt["base"]], check=True)
        base = prepare_and_scan(baseline, "base-", 47124)
        risen = regressions(base, head, changed, args.refactor)
        receipt["regressions"] = risen
        by_code = Counter()
        for (_, code, _), count in head.items():
            by_code[code] += count
        receipt["head_by_code"] = dict(by_code.most_common())
        for item in risen:
            print(f"RISEN {item.get('file') or item['files']} {item['code']}: {item['base']} -> {item['head']}"
                  + (f"  {item['message']}" if "message" in item else ""), flush=True)
        receipt["status"] = "failed" if risen else "passed"
    except (ValueError, OSError, subprocess.CalledProcessError, TimeoutError) as error:
        receipt["error"] = str(error)
        print(f"FAIL: {error}", flush=True)
    finally:
        (logs / "warning-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"GATE-W {receipt['status']}", flush=True)
    return 0 if receipt["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="commit before the batch")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--refactor", action="store_true",
                        help="compare the changed files by per-code totals (R5 refactor commits)")
    return run_gate(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
