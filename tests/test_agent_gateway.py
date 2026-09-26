#!/usr/bin/env python3
"""Agent-container gateway policy against instrumented stub upstreams: the tool
allowlist, Docket item types and references, the Docket scope (assigned work
and the claim), response shaping, logging, and Minerva notify/list with the
launcher's binding, and the session's live grants (fixtures in
agent_gateway_fixtures.py).
"""
import io
import json
import os
import socket
import subprocess
import sys
import time
import unittest
from unittest import mock

from agent_gateway_fixtures import (  # noqa: E402
    ATTEMPT, BUG, DCR, FOREIGN, GATEWAY, GatewayCase, IDENT, KB, NOTE, OBJECTIVE, OTHER, PLUGIN_BUG,
    ROLE, TASK, TERMINALS,
    NOTE_A, NOTE_B, NOTE_IMG, POLICY, SECRET, SENTINEL, SESSION, TARGET, TERMINAL,
    text_result)

sys.path.insert(0, str(GATEWAY.parent))
import agent  # noqa: E402  the launcher Minerva drives grant/revoke through


class Test(GatewayCase):
    def test_dangerous_tools_never_reach_upstream(self):
        cases = [
            ("minerva", "minerva_terminal_create", {"background": True}),
            ("minerva", "minerva_terminal_write", {"text": "id\r"}),
            ("minerva", "minerva_terminal_read", {}),
            ("minerva", "minerva_disk_write", {"path": "/tmp/x", "content": "x"}),
            ("minerva", "minerva_plugin_install", {"path": "/tmp/x"}),
            ("minerva", "minerva_container_build", {"name": "x"}),
            ("minerva", "minerva_enable_tool_sets", {"sets": ["all"]}),
            ("minerva", "minerva_policy_reload", {}),
            ("docket", "docket_delete", {"id": BUG, "project": "minerva"}),
            ("docket", "docket_secret_get", {"key": "k"}),
            ("docket", "docket_project_add", {"path": "/tmp/x.dct", "create": True}),
            ("docket", "docket_link", {"id": BUG, "project": "minerva"}),
            ("docket", "docket_context", {"project": "minerva"}),
            ("nudge", "nudge_import", {"payload": {}, "mode": "replace"}),
            ("nudge", "nudge_delete_hint", {"component": "c", "key": "k"}),
            ("nudge", "nudge_export", {}),
        ]
        for service, tool, args in cases:
            with self.subTest(tool):
                self.assertDenied(self.call(service, tool, args))
        for stub in self.stubs.values():
            self.assertEqual(stub.records, [], stub.name)

    def test_tools_list_is_filtered_and_pruned(self):
        _, body, _ = self.post("minerva", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = {t["name"]: t for t in body["result"]["tools"]}
        self.assertEqual(set(tools), {"minerva_terminal_notify"})
        schema = tools["minerva_terminal_notify"]["inputSchema"]
        self.assertNotIn("sneaky", schema["properties"])
        _, body, _ = self.post("docket", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = {t["name"]: t for t in body["result"]["tools"]}
        self.assertEqual(set(tools), {"docket_get"})
        schema = tools["docket_get"]["inputSchema"]
        self.assertEqual(schema["required"], ["id", "project"])
        self.assertEqual(set(schema["properties"]), {"id", "project", "include"})
        self.assertFalse(schema["additionalProperties"])

    def test_unknown_arguments_and_values_denied(self):
        cases = [
            ("nudge", "nudge_get_hint", {"component": "c", "key": "k", "path": "/etc"}),
            ("nudge", "nudge_set_hint", {"component": "c\nx", "key": "k", "value": 1}),
            ("nudge", "nudge_bump", {"component": "c", "key": "k", "delta": True}),
            ("docket", "docket_query", {"project": "minerva", "detail": "lean"}),
            ("docket", "docket_query", {"project": "minerva", "limit": 100000}),
            ("nudge", "nudge_query", {"regex": "(a+)+$"}),
        ]
        for service, tool, args in cases:
            with self.subTest(tool=tool, args=args):
                self.assertDenied(self.call(service, tool, args))
        self.assertEqual(self.stubs["nudge"].records + self.stubs["docket"].records, [])

    def test_allowed_nudge_call_forwards_unchanged(self):
        args = {"component": "c", "key": "k", "value": {"nested": [1, 2]}}
        body = self.call("nudge", "nudge_set_hint", args)
        self.assertTrue(self.result_value(body)["success"])
        self.assertEqual(self.stubs["nudge"].calls("nudge_set_hint"), [args])

    def test_docket_project_and_id_shape(self):
        cases = [
            {"id": BUG},                                         # no project: no silent default
            {"id": BUG, "project": "Master-Private"},            # not in session scope
            {"id": "aaaa", "project": "minerva"},                # prefix id
            {"id": BUG.upper(), "project": "minerva"},           # not canonical hex
            {"id": f"plugins.dct:{PLUGIN_BUG}", "project": "minerva"},  # cross-project primary id
        ]
        for args in cases:
            with self.subTest(args=args):
                self.assertDenied(self.call("docket", "docket_get", args))
        self.assertEqual(self.stubs["docket"].records, [])

    def test_docket_get_discloses_nothing_for_denied_types(self):
        for item in (POLICY, SECRET, NOTE):
            with self.subTest(item=item):
                body = self.call("docket", "docket_get", {"id": item, "project": "minerva"})
                self.assertDenied(body)
                self.assertNotIn("SENTINEL", json.dumps(body))
        body = self.call("docket", "docket_get", {"id": BUG, "project": "minerva"})
        self.assertEqual(self.result_value(body)["type"], "bug")

    def test_docket_query_drops_denied_types_and_forces_full(self):
        body = self.call("docket", "docket_query", {"project": "minerva", "filter": {"status": "new"}})
        value = self.result_value(body)
        self.assertEqual([i["id"] for i in value["items"]], [BUG])
        self.assertEqual(value["count"], 1)
        self.assertNotIn("SENTINEL", json.dumps(body))
        self.assertEqual(self.stubs["docket"].calls("docket_query")[0]["detail"], "full")

    def test_docket_mutations_on_denied_types_fail_closed(self):
        cases = [
            ("docket_update", {"id": POLICY, "project": "minerva", "description": "x"}),
            ("docket_update", {"id": SECRET, "project": "minerva", "title": "x"}),
            ("docket_transition", {"id": POLICY, "project": "minerva", "to": "active"}),
            ("docket_transition", {"id": NOTE, "project": "minerva", "to": "sealed"}),
            ("docket_comment", {"action": "add", "item_id": POLICY, "project": "minerva", "text": "x"}),
            ("docket_create", {"type": "policy", "title": "x", "project": "minerva"}),
            ("docket_create", {"type": "bug", "title": "x", "project": "minerva", "parent": POLICY}),
            ("docket_update", {"id": BUG, "project": "minerva", "blocked_by": SECRET}),
            ("docket_update", {"id": BUG, "project": "minerva", "parent": f"Master:{BUG}"}),
            ("docket_update", {"id": BUG, "project": "minerva", "type": "policy"}),
            ("docket_comment", {"action": "accept", "item_id": BUG, "project": "minerva", "comment_id": 1}),
            # A reply names a comment the gateway cannot tie to the vetted item.
            ("docket_comment", {"action": "reply", "item_id": BUG, "project": "minerva",
                                "comment_id": 5, "text": "x"}),
            ("docket_comment", {"action": "reply", "item_id": BUG, "project": "minerva", "text": "x"}),
            ("docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                "comment_id": 5, "text": "x"}),
            ("docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                "text": "x", "author": "codex@codex-1"}),
        ]
        for tool, args in cases:
            with self.subTest(tool=tool, args=args):
                self.assertDenied(self.call("docket", tool, args))
        mutations = {"docket_update", "docket_transition", "docket_comment", "docket_create"}
        self.assertFalse(mutations & set(self.stubs["docket"].tools_called()),
                         self.stubs["docket"].tools_called())

    def test_docket_lookup_failures_deny(self):
        for mode in ("error", "malformed"):
            with self.subTest(mode):
                self.stubs["docket"].lookup_mode = mode
                self.assertDenied(self.call("docket", "docket_update",
                                            {"id": BUG, "project": "minerva", "title": "x"}))
        self.assertNotIn("docket_update", self.stubs["docket"].tools_called())

    def test_docket_allowed_mutations_forward_with_canonical_refs(self):
        body = self.call("docket", "docket_update", {"id": BUG, "project": "minerva", "title": "t",
                                                     "parent": f"plugins.dct:{PLUGIN_BUG}"})
        self.assertIn("result", body, body)
        self.assertEqual(self.stubs["docket"].calls("docket_update"),
                         [{"id": BUG, "project": "minerva", "title": "t",
                           "parent": f"plugins.dct:{PLUGIN_BUG}", "holder": IDENT}])
        self.call("docket", "docket_comment", {"action": "add", "item_id": BUG, "project": "minerva",
                                               "text": "hello"})
        self.assertEqual(self.stubs["docket"].calls("docket_comment")[0]["author"],
                         f"container:claude@{SESSION}")
        body = self.call("docket", "docket_create", {"type": "bug", "title": "t", "project": "minerva",
                                                     "parent": BUG})
        self.assertIn("result", body, body)

    def test_readable_types_are_not_all_mutable(self):
        for item in (DCR, KB):
            with self.subTest(item=item):
                body = self.call("docket", "docket_get", {"id": item, "project": "minerva"})
                self.assertIn("result", body, body)
        body = self.call("docket", "docket_comment", {"action": "list", "item_id": DCR, "project": "minerva"})
        self.assertIn("result", body, body)
        for tool, args in (
                ("docket_update", {"id": KB, "project": "minerva", "article": "x"}),
                ("docket_transition", {"id": DCR, "project": "minerva", "to": "approved"}),
                ("docket_comment", {"action": "add", "item_id": DCR, "project": "minerva", "text": "x"}),
                ("docket_create", {"type": "dcr", "title": "x", "project": "minerva"})):
            with self.subTest(tool=tool):
                self.assertDenied(self.call("docket", tool, args))
        called = self.stubs["docket"].tools_called()
        self.assertFalse({"docket_update", "docket_transition", "docket_create"} & set(called), called)
        self.assertEqual(len(self.stubs["docket"].calls("docket_comment")), 1)  # the list

    def test_docket_scope_is_the_assigned_work_and_the_claim(self):
        # Oracle: the gateway's decision and its refusal text. The session's
        # identity (grants.json) is IDENT; ATTEMPT is assigned to it and
        # claimed by it, TASK and OBJECTIVE are its parents, FOREIGN is a
        # sibling task assigned to someone else.
        docket = self.stubs["docket"]
        for item in (ATTEMPT, TASK, OBJECTIVE):
            with self.subTest(read=item):
                body = self.call("docket", "docket_get", {"id": item, "project": "minerva"})
                self.assertEqual(self.result_value(body)["id"], item)
        body = self.call("docket", "docket_get", {"id": FOREIGN, "project": "minerva"})
        self.assertDenied(body)
        self.assertIn(f"docket_out_of_scope: item {FOREIGN} is not assigned to {IDENT}",
                      body["error"]["message"])
        self.assertNotIn("FOREIGN-SENTINEL", json.dumps(body))

        # Evidence on the chain: an attachment on the parent task.
        attach = {"item_id": TASK, "project": "minerva", "filename": "log.txt", "data": "aGVsbG8="}
        self.assertIn("result", self.call("docket", "docket_attach", attach))
        self.assertEqual(docket.calls("docket_attach"), [attach])
        self.assertDenied(self.call("docket", "docket_attach", {**attach, "item_id": FOREIGN}))

        # A protected write while the session holds the claim: forwarded,
        # with the gateway's holder whatever the container sent.
        move = {"id": ATTEMPT, "project": "minerva", "to": "in_progress"}
        self.assertIn("result", self.call("docket", "docket_transition", move))
        self.assertDenied(self.call("docket", "docket_transition", {**move, "holder": "worker-b"}))
        self.assertEqual(docket.calls("docket_transition"), [{**move, "holder": IDENT}])

        # A fact tag is recorded on the task it is about, which is only on the
        # chain: review:/test:/integrated:/released: tags go through as IDENT;
        # any other change to a chain item is refused.
        facts = {"id": TASK, "project": "minerva", "tags": ["wr:task", "test:passed"]}
        self.assertIn("result", self.call("docket", "docket_update", facts))
        self.assertEqual(docket.calls("docket_update"), [{**facts, "holder": IDENT}])
        body = self.call("docket", "docket_update",
                         {"id": TASK, "project": "minerva", "tags": ["wr:task", "requires:review"]})
        self.assertDenied(body)
        self.assertIn(f"docket_out_of_scope: item {TASK} is not assigned to {IDENT}", body["error"]["message"])
        self.assertEqual(len(docket.calls("docket_update")), 1)

        # The host reassigns the claim: the next protected write is refused,
        # evidence on the item still goes through.
        docket.items[("minerva", ATTEMPT)]["claim_holder"] = "worker-b"
        body = self.call("docket", "docket_transition", move)
        self.assertDenied(body)
        self.assertIn(f"docket_not_holder: item {ATTEMPT} is not claimed by {IDENT}", body["error"]["message"])
        self.assertIn("result", self.call("docket", "docket_comment", {
            "action": "add", "item_id": ATTEMPT, "project": "minerva", "text": "what I did"}))
        # ...and once assigned_to moves too, the item leaves the scope.
        docket.items[("minerva", ATTEMPT)]["assigned_to"] = "worker-b"
        body = self.call("docket", "docket_update", {"id": ATTEMPT, "project": "minerva", "priority": 2})
        self.assertIn(f"docket_out_of_scope: item {ATTEMPT} is not assigned to {IDENT}", body["error"]["message"])
        self.assertEqual(len(docket.calls("docket_transition")), 1)
        self.assertEqual(len(docket.calls("docket_update")), 1)

    def test_upstream_payloads_are_rebuilt_not_relayed(self):
        nudge, docket = self.stubs["nudge"], self.stubs["docket"]

        def decorate(tool, result):
            if tool == "nudge_set_hint":
                return {"content": [{"type": "text", "text": json.dumps(
                    {"error": "version conflict", "data": SENTINEL})}], "isError": True}
            return {**result, "structuredContent": {"s": SENTINEL}, "_meta": {"s": SENTINEL}}
        nudge.decorate = decorate
        body = self.call("nudge", "nudge_list_components", {})
        self.assertEqual(set(body["result"]), {"content"})
        body = self.call("nudge", "nudge_set_hint", {"component": "c", "key": "k", "value": 1})
        self.assertTrue(body["result"]["isError"])
        self.assertEqual(self.result_value(body), {"error": "version conflict"})

        docket.decorate = lambda tool, result: {**result, "structuredContent": {"s": SENTINEL}}
        body = self.call("docket", "docket_get", {"id": BUG, "project": "minerva"})
        self.assertEqual(self.result_value(body)["id"], BUG)
        docket.decorate = lambda tool, result: text_result({"error": SENTINEL}, is_error=True)
        self.assertDenied(self.call("docket", "docket_get", {"id": BUG, "project": "minerva"}))
        self.assertDenied(self.call("docket", "docket_query", {"project": "minerva"}))

        def rpc_error(handler, body):
            if body.get("method") != "tools/call":
                return False
            data = json.dumps({"jsonrpc": "2.0", "id": body["id"],
                               "error": {"code": -32000, "message": SENTINEL, "data": SENTINEL}}).encode()
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(data)))
            handler.end_headers()
            handler.wfile.write(data)
            return True
        nudge.decorate, nudge.custom = None, rpc_error
        errors = [self.call("nudge", "nudge_list_components", {})]

        def init_extra(handler, body):
            if body.get("method") != "initialize":
                return False
            data = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": {
                "protocolVersion": "2025-06-18", "instructions": SENTINEL,
                "capabilities": {"tools": {}, "resources": {"s": SENTINEL}},
                "serverInfo": {"name": "n", "extra": SENTINEL}}}).encode()
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(data)))
            handler.end_headers()
            handler.wfile.write(data)
            return True
        nudge.custom = init_extra
        _, init, _ = self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}}})
        self.assertEqual(init["result"]["capabilities"], {"tools": {}})
        self.assertEqual(errors[0]["error"]["code"], -32002)
        everything = json.dumps([body, errors, init])
        self.assertNotIn(SENTINEL, everything)

    def test_logs_carry_codes_not_client_or_upstream_strings(self):
        captured, saved = io.StringIO(), sys.stderr
        sys.stderr = captured
        try:
            self.call("nudge", "leak_sentinel_tool", {})
            self.call("nudge", "nudge_get_hint", {"component": "c", "key": "k", "leak_sentinel_arg": 1})
            self.post("nudge", None, raw=b'{"jsonrpc":"2.0","id":1,"leak_sentinel_key":1,"leak_sentinel_key":2}')
            self.post("nudge", {"jsonrpc": "2.0", "id": 1, "method": "leak_sentinel/x"})
            self.stubs["nudge"].mode = "badjson"
            self.call("nudge", "nudge_list_components", {})
        finally:
            sys.stderr = saved
        log = captured.getvalue()
        self.assertIn('"tool": "(unlisted)"', log)
        self.assertIn('"code": "argument_not_allowed"', log)
        self.assertNotIn("leak_sentinel", log)

    def test_notify_targets_and_identity(self):
        # No target list: Minerva judges whether `to` has a harness in front.
        # The gateway refuses its own terminal and bad text itself.
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": TERMINAL, "text": "see item"}))
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": TARGET, "text": "line one\nline two"}))
        self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                    {"to": TARGET, "text": "x" * 401}))
        self.assertEqual(self.stubs["minerva"].records, [])
        self.stubs["minerva"].mode = "sse"
        body = self.call("minerva", "minerva_terminal_notify",
                         {"to": TARGET, "text": "see item", "from": "codex@codex-1", "reply_to": OTHER})
        self.assertTrue(self.result_value(body)["success"])
        self.assertEqual(self.stubs["minerva"].calls("minerva_terminal_notify"),
                         [{"to": TARGET, "text": "see item", "from": f"container:claude@{SESSION}",
                           "reply_to": TERMINAL}])

    def test_notify_and_list_follow_the_binding(self):
        # A restarted Minerva attaches with a new terminal id; that id becomes
        # the reply address and the one terminal notify refuses.
        self.bind("4444", [])
        self.assertDenied(self.call("minerva", "minerva_terminal_notify", {"to": "4444", "text": "x"}))
        body = self.call("minerva", "minerva_terminal_notify", {"to": "5555", "text": "see item"})
        self.assertIn("result", body, body)
        self.assertEqual(self.stubs["minerva"].calls("minerva_terminal_notify")[-1]["reply_to"], "4444")
        # Detached (or a broken binding file): notify is refused, list shows nobody.
        for content in ("{}", "not json", json.dumps({"terminal_id": "x y", "notify_targets": []}),
                        json.dumps({"terminal_id": "4444", "notify_targets": ["5555"]})):
            with self.subTest(content=content):
                self.binding_file.write_text(content)
                self.assertDenied(self.call("minerva", "minerva_terminal_notify",
                                            {"to": "5555", "text": "see item"}))
                self.assertEqual(self.result_value(self.call("minerva", "minerva_terminal_list", {}))
                                 ["terminals"], [])
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_terminal_notify")), 1)

    def test_an_expired_lease_is_unattached(self):
        self.bind(TERMINAL, [TARGET], lease_s=-1)   # the attach died without cleaning up
        self.assertDenied(self.call("minerva", "minerva_terminal_notify", {"to": TARGET, "text": "x"}))
        self.assertEqual(self.result_value(self.call("minerva", "minerva_terminal_list", {}))["terminals"], [])
        self.bind(TERMINAL, [TARGET], lease_s=60)   # renewed by a live attach
        self.assertIn("result", self.call("minerva", "minerva_terminal_notify", {"to": TARGET, "text": "x"}))

    def test_notes_only_as_granted(self):
        self.grant(read=[NOTE_A, NOTE_IMG], write=[NOTE_B])
        body = self.call("minerva", "minerva_get_note", {"note_id": NOTE_A})
        self.assertEqual(self.result_value(body), {"success": True, "note_id": NOTE_A, "title": "board",
                                                   "content": "hello"})
        self.assertDenied(self.call("minerva", "minerva_get_note", {"note_id": NOTE_IMG}))  # not a text note
        self.assertNotIn("secret.png", json.dumps(body))
        self.assertDenied(self.call("minerva", "minerva_get_note", {"note_id": "4" * 64}))  # not granted
        self.assertDenied(self.call("minerva", "minerva_update_note", {"note_id": NOTE_A, "content": "x"}))
        body = self.call("minerva", "minerva_update_note", {"note_id": NOTE_B, "content": "handoff"})
        self.assertIn("result", body, body)
        # append needs note-write; read_since needs note-read (write implies read).
        # Refusals name the grant; the gateway stamps the append's author.
        append = {"text": "entry", "request_id": "r1"}
        body = self.call("minerva", "minerva_append_note", {"note_id": NOTE_B, **append})
        self.assertEqual(self.result_value(body)["echo"], {"note_id": NOTE_B, **append,
                                                           "author": f"container:claude@{SESSION}"})
        for note, grant in ((NOTE_A, "note-write"), ("4" * 64, "note-write")):
            body = self.call("minerva", "minerva_append_note", {"note_id": note, **append})
            self.assertDenied(body)
            self.assertIn(f"needs the {grant} grant", body["error"]["message"])
        for note in (NOTE_A, NOTE_B):
            self.assertIn("result", self.call("minerva", "minerva_read_note_since",
                                              {"note_id": note, "cursor": ""}))
        body = self.call("minerva", "minerva_read_note_since", {"note_id": "4" * 64, "cursor": ""})
        self.assertDenied(body)
        self.assertIn("needs the note-read grant", body["error"]["message"])
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_append_note")), 1)
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_read_note_since")), 2)
        for tool, args in (("minerva_list_notes", {}), ("minerva_create_note", {"title": "t", "content": "c"}),
                           ("minerva_delete_note", {"note_id": NOTE_B})):
            with self.subTest(tool):
                self.assertDenied(self.call("minerva", tool, args))
        self.grants_file.write_text("not json")               # a broken grant record grants nothing
        self.assertDenied(self.call("minerva", "minerva_update_note", {"note_id": NOTE_B, "content": "x"}))
        self.assertEqual(self.stubs["minerva"].calls("minerva_update_note"), [{"note_id": NOTE_B,
                                                                              "content": "handoff"}])
        called = set(self.stubs["minerva"].tools_called())
        self.assertFalse({"minerva_list_notes", "minerva_create_note", "minerva_delete_note"} & called)

    def test_container_smoke_probes_pass_through_forwarder_and_gateway(self):
        # The same probes agent-container/smoke.py runs inside a dev container,
        # here through the real forwarder to this gateway and its stubs.
        agent_dir = GATEWAY.parent
        ports = {}
        for name in ("minerva", "docket", "nudge"):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                ports[name] = probe.getsockname()[1]
        ready = self.scratch / f"smoke-ready-{time.monotonic_ns()}"
        forwarder = subprocess.Popen([sys.executable, "-B", str(agent_dir / "forwarder.py"), "--ready", str(ready),
                                      str(self.sock_dir)] + [f"{p}={n}" for n, p in ports.items()])
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            result = subprocess.run([sys.executable, "-B", str(agent_dir / "smoke.py"), "--no-egress",
                                     "--docket-item", BUG, "--docket-project", "minerva",
                                     "--ports", ",".join(f"{n}={p}" for n, p in ports.items())],
                                    capture_output=True, text=True, timeout=60)
        finally:
            forwarder.terminate()
            forwarder.wait(5)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(set(report), {"minerva_tools_list", "docket_tools_list", "nudge_tools_list",
                                       "minerva_clock_denied", "docket_project_list_denied", "docket_get",
                                       "nudge_list_components"})
        self.assertNotIn("minerva_clock", self.stubs["minerva"].tools_called())
        self.assertNotIn("docket_project_list", self.stubs["docket"].tools_called())

    def test_grants_changed_mid_session_apply_on_the_next_call(self):
        # A target list frozen at attach can name a terminal that no longer
        # exists. Grants change while the session runs, through the same
        # agent.py writer Minerva calls, and the very next call follows them.
        # Oracle: the gateway's decision on that call.
        def change(add, session=SESSION, **grants):
            with mock.patch.dict(os.environ, {"MINERVA_AGENT_STATE": str(self.state)}):
                agent.change_grants(session, add, grants.get("read"), grants.get("write"),
                                    grants.get("notify", False))

        def update(note):
            return self.call("minerva", "minerva_update_note", {"note_id": note, "content": "x"})
        change(False, notify=True)
        self.assertFalse(json.loads(self.grants_file.read_text())["notify"])
        body = update(NOTE_B)                                     # refused -> allowed
        self.assertIn("needs the note-write grant", body["error"]["message"])
        change(True, write=[NOTE_B])
        self.assertIn("result", update(NOTE_B))
        change(False, write=[NOTE_B])                             # allowed -> refused
        body = update(NOTE_B)
        self.assertIn("needs the note-write grant", body["error"]["message"])
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_update_note")), 1)

        # A harness tab opened after the session started (and after attach):
        # no re-attach, no target list to extend.
        late = {"id": "4444", "name": "claude-2", "harness": "claude"}
        self.stubs["minerva"].terminals = TERMINALS + [late]
        notify = {"to": "4444", "text": "see note"}
        body = self.call("minerva", "minerva_terminal_notify", notify)
        self.assertIn("notify_not_granted", body["error"]["message"])   # notify was revoked above
        change(True, notify=True)
        body = self.call("minerva", "minerva_terminal_notify", notify)
        self.assertIn("result", body, body)
        self.assertEqual(self.stubs["minerva"].calls("minerva_terminal_notify"),
                         [{**notify, "from": f"container:claude@{SESSION}", "reply_to": TERMINAL}])
        listed = self.result_value(self.call("minerva", "minerva_terminal_list", {}))["terminals"]
        self.assertIn("4444", [t["id"] for t in listed])
        self.assertNotIn(OTHER, [t["id"] for t in listed])     # no harness in front
        # Its own terminal stays refused, however the grants change.
        body = self.call("minerva", "minerva_terminal_notify", {"to": TERMINAL, "text": "me"})
        self.assertIn("notify_self", body["error"]["message"])
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_terminal_notify")), 1)
        # A session started by an earlier agent.py has notes.json and no
        # grants.json: notes.json is its initial record, notify on, and every
        # change keeps notes.json in step for the gateway it still runs.
        legacy = self.state / "sessions" / "legacy-a" / "control"
        for private in (legacy.parent, legacy):
            private.mkdir(mode=0o700)
        (legacy / "notes.json").write_text(json.dumps({"read": [NOTE_A], "write": []}))
        change(True, session="legacy-a", write=[NOTE_B])
        self.assertEqual(json.loads((legacy / "grants.json").read_text()),
                         {"version": 1, "note_read": [NOTE_A], "note_write": [NOTE_B], "notify": True})
        self.assertEqual(json.loads((legacy / "notes.json").read_text()),
                         {"read": [NOTE_A], "write": [NOTE_B]})

    def test_orchview_verbs_are_evaluated_for_the_session_identity(self):
        # The container cannot name a caller; the gateway stamps the registered
        # identity and role, and refuses an answer cut for anyone else.
        # Oracle: what reaches the upstream and what the container receives.
        self.assertDenied(self.call("minerva", "minerva_orchview_tree", {"caller": "owner"}))
        self.assertEqual(self.stubs["minerva"].records, [])
        reply = {"identity": {"principal": IDENT, "source": "caller_argument"}, "scope": "restricted",
                 "tree": []}
        self.stubs["minerva"].decorate = lambda tool, result: text_result(reply)
        body = self.call("minerva", "minerva_orchview_tree", {"depth": 2})
        self.assertEqual(self.result_value(body), reply)
        body = self.call("minerva", "minerva_orchview_changes", {"cursor": "r1:abc"})
        self.assertIn("result", body, body)
        self.assertEqual(self.stubs["minerva"].calls("minerva_orchview_tree"),
                         [{"depth": 2, "caller": IDENT, "caller_role": ROLE}])
        self.assertEqual(self.stubs["minerva"].calls("minerva_orchview_changes"),
                         [{"cursor": "r1:abc", "caller": IDENT, "caller_role": ROLE}])
        for wrong in ({**reply, "scope": "full"}, {**reply, "identity": {"principal": "owner"}}):
            with self.subTest(wrong=wrong):
                self.stubs["minerva"].decorate = lambda tool, result, wrong=wrong: text_result(wrong)
                self.assertDenied(self.call("minerva", "minerva_orchview_tree", {}))
        self.grant(identity="")
        self.assertDenied(self.call("minerva", "minerva_orchview_tree", {}))
        self.assertEqual(len(self.stubs["minerva"].calls("minerva_orchview_tree")), 3)

    def test_terminal_list_is_filtered_and_projected(self):
        body = self.call("minerva", "minerva_terminal_list", {})
        value = self.result_value(body)
        self.assertEqual(value["terminals"], [
            {"id": TERMINAL, "name": "me", "harness": "claude"},
            {"id": TARGET, "name": "codex-1", "harness": "codex"}])
        self.assertNotIn("private tab", json.dumps(body))
        self.assertNotIn("/home/", json.dumps(body))


if __name__ == "__main__":
    unittest.main()
