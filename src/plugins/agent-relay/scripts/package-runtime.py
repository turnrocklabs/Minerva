#!/usr/bin/env python3
"""Package or verify a source-built Agent Relay runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import tarfile
import tempfile
import threading
import time


def binary_name(target: str) -> str:
    return "agent-relay-plugin.exe" if target.startswith("windows-") else "agent-relay-plugin"


def verify(target: str, root: Path) -> None:
    worker = root / binary_name(target)
    marker = root / "target-triple.txt"
    if not worker.is_file() or not marker.is_file():
        raise SystemExit(f"Agent Relay runtime is incomplete at {root}")
    if marker.read_text(encoding="utf-8").strip() != target:
        raise SystemExit(f"Agent Relay target marker does not match {target}")

    env = os.environ.copy()
    env.pop("AGENT_RELAY_STATE_FILE", None)
    with tempfile.TemporaryDirectory() as state_directory, tempfile.TemporaryFile() as stderr_sink:
        state_file = Path(state_directory) / "agent_relay_state.json"
        process = subprocess.Popen(
            [str(worker), "--state-file", str(state_file)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr_sink, text=True, encoding="utf-8", env=env,
        )
        assert process.stdin is not None and process.stdout is not None
        replies: queue.Queue[str] = queue.Queue(maxsize=16)

        def read_stdout() -> None:
            for line in process.stdout:
                replies.put(line)

        threading.Thread(target=read_stdout, daemon=True).start()
        deadline = time.monotonic() + 10.0

        def send(message: dict) -> None:
            process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            process.stdin.flush()

        def request(message: dict) -> dict:
            send(message)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SystemExit("Agent Relay protocol probe timed out")
                try:
                    response = json.loads(replies.get(timeout=remaining))
                except queue.Empty as error:
                    raise SystemExit("Agent Relay protocol probe timed out") from error
                if response.get("id") == message["id"]:
                    return response

        try:
            responses = {1: request({
                "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "packaged-agent-relay-check", "version": "1"},
                },
            })}
            send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
            responses[2] = request(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            responses[3] = request({
                "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                    "name": "minerva_agent_relay_profiles_list", "arguments": {},
                },
            })
            responses[4] = request({
                "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                    "name": "minerva_agent_relay_filter_set", "arguments": {
                        "name": "packaged-probe", "pattern": "^never$", "action": "drop_line",
                    },
                },
            })
        finally:
            process.terminate()
            try:
                process.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3.0)
        persisted = json.loads(state_file.read_text(encoding="utf-8"))
    initialized = responses[1].get("result", {})
    if (initialized.get("protocolVersion") != "2024-11-05"
            or initialized.get("serverName") != "agent_relay"):
        raise SystemExit("Agent Relay initialize failed")
    tools = responses[2].get("result", {}).get("tools", [])
    names = {tool.get("name") for tool in tools if isinstance(tool, dict)}
    required = {"minerva_agent_relay_watch_start", "minerva_agent_relay_relay_ask"}
    if not required.issubset(names):
        raise SystemExit("Agent Relay tools/list omitted required tools")
    profile_call = responses[3].get("result", {})
    if profile_call.get("isError", False) or not profile_call.get("content"):
        raise SystemExit("Agent Relay profiles_list protocol probe failed")
    try:
        profiles = json.loads(profile_call["content"][0]["text"])["profiles"]
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit("Agent Relay profiles_list returned an invalid result") from error
    if not isinstance(profiles, list):
        raise SystemExit("Agent Relay profiles_list did not return a profile list")
    mutation = responses[4].get("result", {})
    if mutation.get("isError", False) or not mutation.get("content"):
        raise SystemExit("Agent Relay state mutation probe failed")
    if not any(rule.get("name") == "packaged-probe"
               for rule in persisted.get("filter_rules", [])):
        raise SystemExit("Agent Relay --state-file did not persist a mutation")


def package(target: str, stage: Path, output: Path) -> None:
    verify(target, stage)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w:gz") as archive:
        for name in (binary_name(target), "target-triple.txt"):
            archive.add(stage / name, arcname=name)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(digest + "\n", encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("package", "verify"))
    parser.add_argument("target")
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    if args.command == "verify":
        verify(args.target, args.root)
    elif args.output is None:
        parser.error("package requires an output archive")
    else:
        package(args.target, args.root, args.output)


if __name__ == "__main__":
    main()
