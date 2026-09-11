extends SceneTree
## Real stdio roundtrip, host save/load hooks, bounds and registration lifecycle.

var _failures: int = 0
var _completed: bool = false
var _control_completed: bool = false
var _closed_result: Dictionary = {}


class SnapshotPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var snapshot: Dictionary = {}
	var pushes: int = 0
	var delivery_errors: int = 0

	func receive(channel: String, payload: Dictionary) -> void:
		pushes += 1
		if channel == "host_owned_save.get_request":
			request.emit.call_deferred("host_owned_save.response", {"request_id": payload.request_id,
				"success": true, "state": snapshot}, "")
		elif channel == "host_owned_save.set_request":
			snapshot = payload.state
			request.emit.call_deferred("host_owned_save.response", {"request_id": payload.request_id,
				"success": true}, "")

	func on_ipc_error(_channel: String, _error: Dictionary) -> void:
		delivery_errors += 1

	func _on_panel_save_request() -> Dictionary:
		return snapshot.duplicate(true)

	func _on_panel_load_request(document: Dictionary) -> void:
		snapshot = document.duplicate(true)


class HTTPReply extends RefCounted:
	var body: Dictionary = {}
	func is_browser_control() -> bool:
		return true
	func send_response(_status: int, _headers: Dictionary, text: String) -> void:
		body = JSON.parse_string(text)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	await _scenario()
	_check(_completed, "whole bulk scenario completed")
	print("Bulk snapshot failures: %d" % _failures)
	quit(1 if _failures else 0)


func _scenario() -> void:
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	var db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd").from_dict({
		"id": "bulk_probe", "name": "bulk_probe", "version": "1.0.0", "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "bulk_snapshot_probe.py", "args": []},
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"ui": {"panels": [{"name": "snapshot", "kind": "godot_scene", "entry_scene": "snapshot.tscn",
			"scripts": ["snapshot.gd"], "ipc_channels": ["echo", "expand", "wait", "capability:host.documents.get_blob"]}],
			"ipc_messages": ["echo", "expand", "wait", "capability:host.documents.get_blob"]},
	})
	definition.state = 2 # PluginDefinition.State.RUNNING
	db._plugins["bulk_probe"] = definition
	manager._db = db
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("bulk_probe")
	connection.configure_stdio("python3", [ProjectSettings.globalize_path("res://test/fixtures/bulk_snapshot_probe.py")])
	_check(await connection.connect_to_server() == OK, "real stdio connection initialized")
	manager._runtime["bulk_probe"] = {"connection": connection}
	var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new()
	var capabilities = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(policy)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new(manager, policy, capabilities)
	var panel := SnapshotPanel.new()
	root.add_child(panel)
	broker.register_panel(panel, "bulk_probe", "bulk-tab", ["echo", "expand", "wait", "capability:host.documents.get_blob"], "snapshot")
	var helper = panel.get_node("_MinervaIPC")
	_check(helper.get_bulk_payload_limit() == 8 * 1024 * 1024, "host advertises bounded bulk route")
	await _control_boundaries(manager, broker, panel, helper)
	_check(_control_completed, "whole control boundary scenario completed")
	var snapshot := {"id": "document-a", "revision": 7, "body": "界🙂é\n".repeat(18000)}
	var encoded := JSON.stringify(snapshot)
	_check(encoded.to_utf8_buffer().size() > 70000, "fixture exceeds 70 KB UTF-8")
	var reply: Dictionary = await helper.request_bulk("echo", {"snapshot": snapshot}, 5000)
	_check(reply.get("success", false), "bulk backend reply succeeded")
	var received: Dictionary = reply.get("snapshot", {})
	_check(_same_snapshot(received, snapshot), "unescaped Unicode survives real subprocess read boundaries")
	_check(helper._pending.is_empty(), "success releases reply observer")
	# Page bridges use JSON, while durable save/load uses the existing native hooks.
	panel.snapshot = JSON.parse_string(JSON.stringify(reply.get("snapshot", {})))
	var host = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
	var saved: Dictionary = host.invoke_save(panel, {})
	var path := "user://bulk-snapshot-test.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	panel.snapshot.clear()
	_check(host.invoke_load(panel, JSON.parse_string(FileAccess.get_file_as_string(path))), "native restore hook accepts snapshot")
	_check(_same_snapshot(panel.snapshot, snapshot), "save/restore and page JSON preserve complete document")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	panel.request.emit("echo", {"snapshot": snapshot}, "control-large")
	var control: Dictionary = await helper.await_reply("control-large", 1000)
	_check(control.get("error_code") == "payload_too_large", "ordinary request still has its control limit")
	var denied: Dictionary = await helper.request_bulk("undeclared", {}, 1000)
	_check(denied.get("error_code") == "permission_denied", "bulk keeps channel allowlists")
	denied = await helper.request_bulk("capability:host.documents.get_blob", {}, 1000)
	_check(denied.get("error_code") == "capability_not_granted", "bulk keeps host capability grants")
	var wide_capability: Dictionary = await helper.request_bulk("capability:host.documents.get_blob", {"text": "界".repeat(24000)}, 1000)
	_check(wide_capability.get("error_code") == "payload_too_large", "bulk cannot widen control capability envelope")
	var state_refusal: Dictionary = await capabilities._handle_host_documents_set_state("bulk_probe", {"editor_name": "absent", "panel_state": {"text": "界".repeat(3000000)}})
	_check(state_refusal.get("error_code") == "payload_too_large", "panel state is capped in UTF-8 before editor lookup")
	var too_large: Dictionary = await helper.request_bulk("echo", {"snapshot": "x".repeat(8 * 1024 * 1024)}, 1000)
	_check(too_large.get("error_code") == "payload_too_large", "oversize request explicitly rejected")
	too_large = await helper.request_bulk("expand", {}, 5000)
	_check(too_large.get("error_code") == "payload_too_large", "oversize reply explicitly rejected")
	var timed_out: Dictionary = await helper.request_bulk("wait", {}, 10)
	_check(timed_out.get("error_code") == "timeout", "timeout resolves caller")
	await create_timer(0.15).timeout
	_check(helper._pending.is_empty(), "late reply leaves no observer")
	_wait_for_close(helper)
	_check(not helper._pending.is_empty(), "close test has an outstanding request")
	broker.unregister_panel("bulk_probe", "bulk-tab")
	_check(_closed_result.get("error_code") == "panel_unloading", "closing panel resolves outstanding await")
	var replacement := SnapshotPanel.new()
	root.add_child(replacement)
	broker.register_panel(replacement, "bulk_probe", "bulk-tab", ["echo"], "snapshot")
	var fresh = replacement.get_node("_MinervaIPC")
	var fresh_reply: Dictionary = await fresh.request_bulk("echo", {"snapshot": {"id": "replacement"}}, 5000)
	_check(fresh_reply.get("snapshot") == {"id": "replacement"}, "late old reply cannot land in replacement panel")
	broker.unregister_panel("bulk_probe", "bulk-tab")
	connection.disconnect_from_server()
	panel.free()
	replacement.free()
	manager._runtime.clear()
	manager.free()
	_completed = true


func _wait_for_close(helper: Node) -> void:
	_closed_result = await helper.request_bulk("wait", {}, 5000)


func _same_snapshot(actual: Dictionary, expected: Dictionary) -> bool:
	# JSON numbers decode as floats; compare their value and all text bytes.
	return actual.size() == expected.size() and actual.get("id") == expected["id"] \
		and actual.get("revision") == expected["revision"] \
		and str(actual.get("body", "")).to_utf8_buffer() == str(expected["body"]).to_utf8_buffer()


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failures += 1
	print("%s: %s" % ["PASS" if ok else "FAIL", label])


func _control_boundaries(manager: Node, broker: RefCounted, panel: Control, helper: Node) -> void:
	var limits = load("res://Scripts/Services/Plugins/PluginPayloadLimits.gd")
	var web = load("res://Scripts/Services/Plugins/PluginWebviewBroker.gd").new(manager)
	web.register_plugin_panel("bulk_probe", "snapshot")
	for character in ["x", "🙂"]:
		var empty_size: int = limits.size_bytes({"ignored": ""})
		var byte_count := 65536 - empty_size
		var text: String = character.repeat(byte_count / character.to_utf8_buffer().size())
		text += "x".repeat(byte_count - text.to_utf8_buffer().size())
		var boundary := {"ignored": text}
		_check(limits.size_bytes(boundary) == 65536, "exact serialized UTF-8 control boundary")
		panel.request.emit("echo", boundary, "boundary")
		var reply: Dictionary = await helper.await_reply("boundary", 5000)
		_check(reply.get("success", false), "scene accepts exact boundary " + character)
		reply = await web.handle_ipc_message("snapshot", "echo", boundary)
		_check(reply.get("success", false), "webview accepts exact boundary " + character)
		boundary.ignored += "x"
		panel.request.emit("echo", boundary, "over-boundary")
		reply = await helper.await_reply("over-boundary", 1000)
		_check(reply.get("error_code") == "payload_too_large", "scene rejects one UTF-8 byte over " + character)
		reply = await web.handle_ipc_message("snapshot", "echo", boundary)
		_check(reply.get("error_code") == "payload_too_large", "webview rejects one UTF-8 byte over " + character)
	var large := {"body": "🙂".repeat(20000)}
	_check(not broker.push_to_panel("bulk_probe", "bulk-tab", "event", large), "scene rejects oversized control push")
	_check(panel.pushes == 0 and panel.delivery_errors == 1, "push failure preserves state and notifies error hook")
	_check(broker.push_to_panel("bulk_probe", "bulk-tab", "text_changed", large), "existing document push uses bulk budget")
	var event_broker = load("res://Scripts/Services/Plugins/PluginEventBroker.gd").new()
	event_broker.handle_plugin_state("bulk_probe", {"revision": 1})
	var rejected: Dictionary = event_broker.handle_plugin_state("bulk_probe", large)
	_check(rejected.get("error_code") == "payload_too_large", "oversized state rejects before storage")
	_check(event_broker.get_plugin_state("bulk_probe") == {"revision": 1}, "last accepted state survives rejected update")
	rejected = event_broker.handle_plugin_event("bulk_probe", "event", large)
	_check(rejected.get("error_code") == "payload_too_large", "oversized event explicitly rejects")
	rejected = event_broker.handle_plugin_event("bulk_probe", "x".repeat(5000), {})
	_check(rejected.get("error_code") == "payload_too_large", "oversized event routing rejects even with small payload")
	_check(not broker.push_to_panel("bulk_probe", "bulk-tab", "x".repeat(5000), {}), "oversized scene push routing rejects")
	panel.request.emit("expand", {}, "large-reply")
	var reply: Dictionary = await helper.await_reply("large-reply", 5000)
	_check(reply.get("error_code") == "payload_too_large", "ordinary scene reply is bounded")
	reply = await web.handle_ipc_message("snapshot", "expand", {})
	_check(reply.get("error_code") == "payload_too_large", "webview reply is bounded")
	panel.request.emit("host.fs.watch", large, "large-reserved")
	reply = await helper.await_reply("large-reserved", 1000)
	_check(reply.get("error_code") == "payload_too_large", "reserved requests validate size before dispatch")
	panel.snapshot = large.duplicate(true)
	var state_reply: Dictionary = await broker.request_panel_state("bulk_probe", "bulk-tab")
	_check(state_reply.get("state") == large, "reserved state response preserves more than 64 KiB")
	state_reply = await broker.apply_panel_state("bulk_probe", "bulk-tab", large)
	_check(state_reply.get("success", false) and panel.snapshot == large, "reserved state apply preserves more than 64 KiB")
	panel.snapshot = {"body": "x".repeat(8 * 1024 * 1024)}
	state_reply = await broker.request_panel_state("bulk_probe", "bulk-tab")
	_check(state_reply.get("error_code") == "payload_too_large", "oversized reserved response resolves original waiter")
	_check(broker._pending_panel_state.is_empty(), "reserved response releases state waiter")
	var http = load("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd").new()
	var capture := HTTPReply.new()
	await http._handle_request(capture, {"method": "POST", "path": "/mcp",
		"headers": {"x-minerva-control": "1"}, "body": JSON.stringify(large)})
	_check(str(capture.body.get("error", {}).get("message", "")).begins_with("payload_too_large"), "direct HTTP rejects before tool dispatch")
	http._send_jsonrpc_result(capture, "request-7", large)
	_check(capture.body.get("id") == "request-7" and capture.body.has("error"), "direct HTTP oversized reply preserves request correlation")
	http.free()
	var too_large := {"state": {"body": "x".repeat(8 * 1024 * 1024)}}
	var apply_result: Dictionary = await broker.apply_panel_state("bulk_probe", "bulk-tab", too_large.state)
	_check(apply_result.get("error_code") == "payload_too_large", "oversize state apply fails immediately")
	_check(broker._pending_panel_state.is_empty(), "oversize state apply releases waiter")

	_control_completed = true
