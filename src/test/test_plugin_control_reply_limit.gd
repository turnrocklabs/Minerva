extends SceneTree
## Historical-compatible real-broker guard for control reply byte bounds.

var failures := 0


class ReplyPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)


func _init() -> void:
	_run.call_deferred()


func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
	printerr("%s: %s" % ["PASS" if condition else "FAIL", label])


func _run() -> void:
	await process_frame
	await process_frame
	var limits = load("res://Scripts/Services/Plugins/PluginPayloadLimits.gd")
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	var db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd").from_dict({
		"id": "reply_limit_probe", "name": "reply_limit_probe", "version": "1.0.0",
		"host_api_version": "1", "backend": {"transport": "stdio",
			"entrypoint": "bulk_snapshot_probe.py", "args": []},
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"ui": {"panels": [{"name": "reply_limit", "kind": "godot_scene",
			"entry_scene": "reply_limit.tscn", "scripts": ["reply_limit.gd"],
			"ipc_channels": ["sized_reply"]}], "ipc_messages": ["sized_reply"]},
	})
	definition.state = 2
	db._plugins["reply_limit_probe"] = definition
	manager._db = db
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new(
		"reply_limit_probe")
	connection.configure_stdio("python3", [ProjectSettings.globalize_path(
		"res://test/fixtures/bulk_snapshot_probe.py")])
	check(await connection.connect_to_server() == OK, "real backend connects")
	manager._runtime["reply_limit_probe"] = {"connection": connection}
	var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new()
	var capabilities = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(policy)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new(
		manager, policy, capabilities)
	var panel := ReplyPanel.new()
	root.add_child(panel)
	broker.register_panel(panel, "reply_limit_probe", "reply-limit-tab",
		["sized_reply"], "reply_limit")
	var helper = panel.get_node("_MinervaIPC")

	var below_bytes: int = limits.CONTROL_BYTES - 4096
	var over_bytes: int = limits.CONTROL_BYTES + 1024
	var below_reply := {"success": true, "snapshot": "x".repeat(below_bytes)}
	var over_reply := {"success": true, "snapshot": "x".repeat(over_bytes)}
	check(limits.size_bytes(below_reply) < limits.CONTROL_BYTES,
		"below-control fixture is measured under the limit")
	check(limits.size_bytes(over_reply) > limits.CONTROL_BYTES \
		and limits.size_bytes(over_reply) < limits.BULK_BYTES,
		"regression fixture is measured between control and bulk limits")

	panel.request.emit("sized_reply", {"bytes": below_bytes}, "below-control")
	var reply: Dictionary = await helper.await_reply("below-control", 5000)
	check(reply.get("snapshot", "").length() == below_bytes,
		"control reply below the limit succeeds")
	panel.request.emit("sized_reply", {"bytes": over_bytes}, "over-control")
	reply = await helper.await_reply("over-control", 5000)
	check(reply.get("error_code") == "payload_too_large",
		"control reply above the limit is rejected")
	reply = await helper.request_bulk("sized_reply", {"bytes": over_bytes}, 5000)
	check(reply.get("snapshot", "").length() == over_bytes,
		"the same reply succeeds through the bulk lane")

	broker.unregister_panel("reply_limit_probe", "reply-limit-tab")
	connection.disconnect_from_server()
	panel.free()
	manager._runtime.clear()
	manager.free()
	print("Control reply limit failures: %d" % failures)
	quit(1 if failures else 0)
