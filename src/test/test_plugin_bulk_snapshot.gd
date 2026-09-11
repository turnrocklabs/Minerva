extends SceneTree
## Real stdio roundtrip, host save/load hooks, bounds and registration lifecycle.

var _failures: int = 0
var _completed: bool = false
var _closed_result: Dictionary = {}


class SnapshotPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var snapshot: Dictionary = {}

	func _on_panel_save_request() -> Dictionary:
		return snapshot.duplicate(true)

	func _on_panel_load_request(document: Dictionary) -> void:
		snapshot = document.duplicate(true)


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
	var too_large: Dictionary = await helper.request_bulk("echo", {"snapshot": "x".repeat(8 * 1024 * 1024)}, 1000)
	_check(too_large.get("error_code") == "payload_too_large", "oversize request explicitly rejected")
	too_large = await helper.request_bulk("expand", {}, 5000)
	_check(too_large.get("error_code") == "payload_too_large", "oversize reply explicitly rejected")
	var timed_out: Dictionary = await helper.request_bulk("wait", {}, 10)
	_check(timed_out.get("error_code") == "timeout", "timeout resolves caller")
	await create_timer(0.15).timeout
	_check(helper._pending.is_empty(), "late reply leaves no observer")
	_wait_for_close(helper)
	await process_frame
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
