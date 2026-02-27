#!/usr/bin/env python3
"""
TDD test script for Minerva MCP Tool Sets + Autocoder Tools.

Targets the MCP HTTP server at localhost:9315/mcp.
Tests: tool set management, filtering, autocoder tool schemas, and end-to-end workflows.

Usage:
    python3 tests/test_autocoder_mcp_tools.py [--host HOST] [--port PORT] [--verbose]
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
import uuid


class MCPClient:
    """Minimal MCP JSON-RPC 2.0 client over HTTP."""

    def __init__(self, host: str = "localhost", port: int = 9315):
        self.base_url = f"http://{host}:{port}/mcp"
        self.session_id = None

    def _request(self, method: str, params: dict = None) -> dict:
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": str(uuid.uuid4()),
        }
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id

        req = urllib.request.Request(self.base_url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = resp.read().decode("utf-8")
                result = json.loads(body)
                # Capture session id from initialize
                if method == "initialize":
                    for key in ("mcp-session-id", "MCP-Session-Id"):
                        val = resp.headers.get(key)
                        if val:
                            self.session_id = val
                            break
                return result
        except urllib.error.URLError as e:
            return {"error": {"code": -1, "message": str(e)}}

    def initialize(self) -> dict:
        return self._request("initialize", {
            "protocolVersion": "2024-11-05",
            "clientInfo": {"name": "test-autocoder", "version": "1.0.0"},
            "capabilities": {},
        })

    def list_tools(self) -> list:
        resp = self._request("tools/list")
        result = resp.get("result", {})
        return result.get("tools", [])

    def call_tool(self, name: str, arguments: dict = None) -> dict:
        resp = self._request("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in resp and "result" not in resp:
            return resp
        content = resp.get("result", {}).get("content", [])
        if content and content[0].get("type") == "text":
            try:
                return json.loads(content[0]["text"])
            except (json.JSONDecodeError, KeyError):
                return {"raw": content[0].get("text", "")}
        return resp.get("result", {})


# ── Test runner ────────────────────────────────────────────────────────────────

class TestRunner:
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.errors = []

    def log(self, msg: str):
        if self.verbose:
            print(f"  {msg}")

    def assert_true(self, condition: bool, msg: str):
        if not condition:
            raise AssertionError(msg)

    def assert_eq(self, actual, expected, msg: str = ""):
        if actual != expected:
            raise AssertionError(f"{msg}: expected {expected!r}, got {actual!r}")

    def assert_in(self, item, container, msg: str = ""):
        if item not in container:
            raise AssertionError(f"{msg}: {item!r} not in {container!r}")

    def run(self, test_func, name: str):
        print(f"  [{name}] ", end="", flush=True)
        try:
            test_func()
            self.passed += 1
            print("PASS")
        except AssertionError as e:
            self.failed += 1
            self.errors.append((name, str(e)))
            print(f"FAIL: {e}")
        except Exception as e:
            self.failed += 1
            self.errors.append((name, f"ERROR: {e}"))
            print(f"ERROR: {e}")

    def skip(self, name: str, reason: str):
        self.skipped += 1
        print(f"  [{name}] SKIP: {reason}")

    def summary(self):
        total = self.passed + self.failed + self.skipped
        print(f"\n{'='*60}")
        print(f"Results: {self.passed} passed, {self.failed} failed, {self.skipped} skipped (total {total})")
        if self.errors:
            print("\nFailures:")
            for name, err in self.errors:
                print(f"  - {name}: {err}")
        print(f"{'='*60}")
        return self.failed == 0


# ── Tests ──────────────────────────────────────────────────────────────────────

def run_tests(host: str, port: int, verbose: bool):
    client = MCPClient(host, port)
    t = TestRunner(verbose)

    # ── Phase 1: Connection ────────────────────────────────────────────────

    print("\n--- Phase 1: Connection ---")

    def test_initialize():
        resp = client.initialize()
        t.assert_true("result" in resp, "initialize should return result")
        t.assert_true(client.session_id is not None, "Should receive session ID")
        result = resp["result"]
        t.assert_eq(result["serverInfo"]["name"], "minerva")
        t.log(f"Session: {client.session_id}")

    t.run(test_initialize, "initialize")

    # ── Phase 2: Tool Sets Management ──────────────────────────────────────

    print("\n--- Phase 2: Tool Sets ---")

    all_tools_before_filter = []

    def test_list_tools_initial():
        nonlocal all_tools_before_filter
        tools = client.list_tools()
        all_tools_before_filter = tools
        t.assert_true(len(tools) > 0, "Should have tools registered")
        t.log(f"Total tools: {len(tools)}")
        # Verify autocoder tools are present
        autocoder_tools = [tool for tool in tools if tool["name"].startswith("minerva_autocoder_")]
        t.assert_eq(len(autocoder_tools), 10, f"Should have 10 autocoder tools")
        # Verify meta tools are present
        meta_tools = [tool for tool in tools if tool["name"] in (
            "minerva_list_tool_sets", "minerva_enable_tool_sets", "minerva_disable_tool_sets")]
        t.assert_eq(len(meta_tools), 3, "Should have 3 meta tools")

    t.run(test_list_tools_initial, "list_tools_initial")

    def test_list_tool_sets():
        result = client.call_tool("minerva_list_tool_sets")
        t.assert_true(result.get("success", False), f"Should succeed: {result}")
        sets = result.get("tool_sets", {})
        t.assert_in("chat", sets, "Should have chat set")
        t.assert_in("autocoder", sets, "Should have autocoder set")
        t.assert_in("meta", sets, "Should have meta set")
        t.assert_in("spreadsheet", sets, "Should have spreadsheet set")
        t.assert_true(result.get("all_enabled", False), "All sets should be enabled initially")
        t.log(f"Sets: {sets}")

    t.run(test_list_tool_sets, "list_tool_sets")

    def test_enable_autocoder_only():
        result = client.call_tool("minerva_enable_tool_sets", {"sets": ["autocoder"]})
        t.assert_true(result.get("success", False), f"Should succeed: {result}")
        t.assert_eq(result.get("all_enabled"), False, "Should not be all-enabled")
        t.assert_in("autocoder", result.get("enabled_sets", []))

    t.run(test_enable_autocoder_only, "enable_autocoder_set")

    def test_filtered_tools_list():
        tools = client.list_tools()
        tool_names = [tool["name"] for tool in tools]
        t.log(f"Filtered tool count: {len(tools)}")
        # Should have autocoder tools + meta tools only
        for tool in tools:
            name = tool["name"]
            is_autocoder = name.startswith("minerva_autocoder_")
            is_meta = name in ("minerva_list_tool_sets", "minerva_enable_tool_sets", "minerva_disable_tool_sets")
            t.assert_true(is_autocoder or is_meta,
                          f"Tool '{name}' should be autocoder or meta, but wasn't")
        autocoder_count = sum(1 for n in tool_names if n.startswith("minerva_autocoder_"))
        meta_count = sum(1 for n in tool_names if n.startswith("minerva_list_tool_sets") or
                         n.startswith("minerva_enable_tool_sets") or n.startswith("minerva_disable_tool_sets"))
        t.assert_eq(autocoder_count, 10, "Should have 10 autocoder tools after filtering")
        t.assert_eq(meta_count, 3, "Should have 3 meta tools after filtering")
        t.assert_eq(len(tools), 13, f"Should have exactly 13 tools (10 autocoder + 3 meta)")

    t.run(test_filtered_tools_list, "filtered_tools_list")

    def test_reenable_all():
        result = client.call_tool("minerva_enable_tool_sets", {"sets": []})
        t.assert_true(result.get("success", False), f"Should succeed: {result}")
        t.assert_true(result.get("all_enabled", False), "Should be all-enabled")
        tools = client.list_tools()
        t.assert_eq(len(tools), len(all_tools_before_filter),
                     f"Should have all tools back ({len(all_tools_before_filter)})")

    t.run(test_reenable_all, "reenable_all_sets")

    def test_disable_sets():
        result = client.call_tool("minerva_disable_tool_sets", {"sets": ["pcb", "video"]})
        t.assert_true(result.get("success", False), f"Should succeed: {result}")
        tools = client.list_tools()
        tool_names = [tool["name"] for tool in tools]
        # Should NOT have pcb or video tools
        pcb_tools = [n for n in tool_names if n.startswith("minerva_pcb_") or n == "minerva_create_pcb_editor"]
        video_tools = [n for n in tool_names if n.startswith("minerva_video_") or n == "minerva_create_video_editor"]
        t.assert_eq(len(pcb_tools), 0, f"PCB tools should be filtered out, found: {pcb_tools}")
        t.assert_eq(len(video_tools), 0, f"Video tools should be filtered out, found: {video_tools}")
        t.log(f"After disable pcb+video: {len(tools)} tools")

    t.run(test_disable_sets, "disable_sets")

    # Re-enable all for subsequent tests
    client.call_tool("minerva_enable_tool_sets", {"sets": []})

    # ── Phase 3: Schema Validation ─────────────────────────────────────────

    print("\n--- Phase 3: Schema Validation ---")

    EXPECTED_AUTOCODER_TOOLS = {
        "minerva_autocoder_plan": {"required": ["prompt"]},
        "minerva_autocoder_generate": {"required": ["prompt"]},
        "minerva_autocoder_status": {"required": ["session_id"]},
        "minerva_autocoder_review": {"required": ["session_id"]},
        "minerva_autocoder_approve": {"required": ["session_id"]},
        "minerva_autocoder_answer_question": {"required": ["session_id", "question_id", "answer"]},
        "minerva_autocoder_create_review_agent": {"required": ["name", "prompt"]},
        "minerva_autocoder_list_review_agents": {"required": []},
        "minerva_autocoder_list_sessions": {"required": []},
        "minerva_autocoder_download": {"required": []},
    }

    def test_autocoder_schemas():
        tools = client.list_tools()
        tool_map = {tool["name"]: tool for tool in tools}
        for name, spec in EXPECTED_AUTOCODER_TOOLS.items():
            t.assert_in(name, tool_map, f"Tool {name} should exist")
            schema = tool_map[name].get("inputSchema", {})
            actual_required = schema.get("required", [])
            t.assert_eq(sorted(actual_required), sorted(spec["required"]),
                         f"Schema mismatch for {name}")
            t.log(f"  {name}: schema OK (required={actual_required})")

    t.run(test_autocoder_schemas, "autocoder_schemas")

    # ── Phase 4: Error Handling ────────────────────────────────────────────

    print("\n--- Phase 4: Error Handling ---")

    def test_plan_missing_prompt():
        result = client.call_tool("minerva_autocoder_plan", {})
        t.assert_true(not result.get("success", True), "Should fail without prompt")
        t.assert_in("prompt", result.get("error", "").lower(), "Error should mention prompt")

    t.run(test_plan_missing_prompt, "plan_missing_prompt")

    def test_status_missing_session():
        result = client.call_tool("minerva_autocoder_status", {})
        t.assert_true(not result.get("success", True), "Should fail without session_id")

    t.run(test_status_missing_session, "status_missing_session")

    def test_answer_missing_fields():
        result = client.call_tool("minerva_autocoder_answer_question", {"session_id": "x"})
        t.assert_true(not result.get("success", True), "Should fail without question_id")

    t.run(test_answer_missing_fields, "answer_missing_fields")

    def test_download_missing_both():
        result = client.call_tool("minerva_autocoder_download", {})
        t.assert_true(not result.get("success", True), "Should fail without session_id or artifact_uri")

    t.run(test_download_missing_both, "download_missing_both")

    def test_create_agent_missing_name():
        result = client.call_tool("minerva_autocoder_create_review_agent", {"prompt": "review"})
        t.assert_true(not result.get("success", True), "Should fail without name")

    t.run(test_create_agent_missing_name, "create_agent_missing_name")

    def test_blocked_tool_when_filtered():
        # Enable only autocoder, then try to call a chat tool
        client.call_tool("minerva_enable_tool_sets", {"sets": ["autocoder"]})
        resp = client._request("tools/call", {
            "name": "minerva_create_chat",
            "arguments": {"name": "test"}
        })
        # Should be a JSON-RPC error (tool set not enabled)
        t.assert_true("error" in resp, "Should get error for blocked tool")
        if "error" in resp:
            t.assert_in("not enabled", resp["error"].get("message", "").lower(),
                         "Error should mention set not enabled")
        # Re-enable all
        client.call_tool("minerva_enable_tool_sets", {"sets": []})

    t.run(test_blocked_tool_when_filtered, "blocked_tool_when_filtered")

    # ── Phase 5: Autocoder Listing Tools ───────────────────────────────────

    print("\n--- Phase 5: Autocoder Listings ---")

    def test_list_sessions():
        result = client.call_tool("minerva_autocoder_list_sessions")
        # May succeed or fail depending on whether autocoder is connected
        if result.get("success"):
            t.assert_true("sessions" in result, "Should have sessions key")
            t.assert_true("count" in result, "Should have count key")
            t.log(f"Sessions: {result['count']}")
        else:
            t.log(f"AutoCoder not connected (expected in test env): {result.get('error')}")
            # This is acceptable - the tool responded correctly
            t.assert_in("error", result, "Should have error message")

    t.run(test_list_sessions, "list_sessions")

    def test_list_review_agents():
        result = client.call_tool("minerva_autocoder_list_review_agents")
        if result.get("success"):
            t.assert_true("agents" in result, "Should have agents key")
            t.assert_true("count" in result, "Should have count key")
            t.log(f"Review agents: {result['count']}")
        else:
            t.log(f"AutoCoder not connected: {result.get('error')}")
            t.assert_in("error", result, "Should have error message")

    t.run(test_list_review_agents, "list_review_agents")

    # ── Phase 6: End-to-End (requires running AutoCoder) ──────────────────

    print("\n--- Phase 6: End-to-End (requires AutoCoder) ---")

    # Check if autocoder is available
    list_result = client.call_tool("minerva_autocoder_list_sessions")
    autocoder_available = list_result.get("success", False)

    if not autocoder_available:
        for test_name in ["plan", "generate_and_poll", "review", "approve", "download"]:
            t.skip(f"e2e_{test_name}", "AutoCoder service not connected")
    else:
        session_id = None

        def test_e2e_plan():
            nonlocal session_id
            result = client.call_tool("minerva_autocoder_plan", {
                "prompt": "Create a simple hello world Python script that prints 'Hello from Minerva AutoCoder'"
            })
            t.assert_true(result.get("success", False), f"Plan should succeed: {result}")
            session_id = result.get("session_id", "")
            t.assert_true(len(session_id) > 0, "Should return a session_id")
            t.log(f"Plan session: {session_id}, status: {result.get('status')}")

        t.run(test_e2e_plan, "e2e_plan")

        if session_id:
            def test_e2e_status_after_plan():
                result = client.call_tool("minerva_autocoder_status", {"session_id": session_id})
                t.assert_true(result.get("success", False), f"Status should succeed: {result}")
                t.log(f"Status: {json.dumps(result, indent=2)[:200]}")

            t.run(test_e2e_status_after_plan, "e2e_status_after_plan")

            def test_e2e_generate():
                result = client.call_tool("minerva_autocoder_generate", {
                    "prompt": "Create a simple hello world Python script",
                    "session_id": session_id,
                    "use_plan_tasks": True,
                })
                t.assert_true(result.get("success", False), f"Generate should succeed: {result}")
                t.log(f"Generate started: status={result.get('status')}")

            t.run(test_e2e_generate, "e2e_generate")

            def test_e2e_poll_generation():
                """Poll status until generation completes (max 5 min)."""
                max_polls = 60
                poll_interval = 5
                for i in range(max_polls):
                    result = client.call_tool("minerva_autocoder_status", {"session_id": session_id})
                    status = result.get("status", "")
                    t.log(f"  Poll {i+1}: status={status}")
                    if status in ("completed", "done", "ready_for_review", "approved"):
                        return
                    if "error" in status.lower() or "fail" in status.lower():
                        raise AssertionError(f"Generation failed with status: {status}")
                    time.sleep(poll_interval)
                raise AssertionError(f"Generation did not complete within {max_polls * poll_interval}s")

            t.run(test_e2e_poll_generation, "e2e_poll_generation")

            def test_e2e_review():
                result = client.call_tool("minerva_autocoder_review", {"session_id": session_id})
                t.assert_true(result.get("success", False), f"Review should succeed: {result}")

            t.run(test_e2e_review, "e2e_review")

            def test_e2e_approve():
                result = client.call_tool("minerva_autocoder_approve", {"session_id": session_id})
                t.assert_true(result.get("success", False), f"Approve should succeed: {result}")

            t.run(test_e2e_approve, "e2e_approve")

            def test_e2e_download():
                result = client.call_tool("minerva_autocoder_download", {"session_id": session_id})
                if result.get("success"):
                    t.assert_true("filename" in result, "Should have filename")
                    t.assert_true("content" in result, "Should have content")
                    t.assert_true(result.get("size", 0) > 0, "Should have non-zero size")
                    t.log(f"Downloaded: {result.get('filename')}, size={result.get('size')}")
                else:
                    t.log(f"Download not available (may need artifact): {result.get('error')}")

            t.run(test_e2e_download, "e2e_download")

    # ── Summary ────────────────────────────────────────────────────────────

    return t.summary()


def main():
    parser = argparse.ArgumentParser(description="Test Minerva MCP Autocoder Tools")
    parser.add_argument("--host", default="localhost", help="MCP server host")
    parser.add_argument("--port", type=int, default=9315, help="MCP server port")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    print(f"Minerva MCP Autocoder Tools Test Suite")
    print(f"Target: {args.host}:{args.port}")
    print(f"{'='*60}")

    success = run_tests(args.host, args.port, args.verbose)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
