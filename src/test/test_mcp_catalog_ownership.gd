extends SceneTree
## Catalog entries belong to an exact connection. A stale disconnect or a
## colliding later server cannot remove or silently retarget that definition.

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var Manager = load("res://Scripts/Services/MCP/MCPManager.gd")
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var manager = Manager.new()
	var first = Connection.new("first")
	first.tools = [Definition.from_dict({"name": "shared", "inputSchema": {"type": "object"}}, "first")]
	manager.servers["first"] = first
	manager._register_server_tools(first)
	var replacement = Connection.new("first")
	manager.servers["first"] = replacement
	manager._on_server_disconnected("first", first)
	check("stale disconnect cannot erase a replacement owner or its prior catalog",
		manager.servers.get("first") == replacement
		and manager.tool_registry.get("shared").server_name == "first")
	var stale_dispatch: Dictionary = await manager.execute_tool("shared", {})
	check("a stale catalog owner cannot dispatch through the replacement connection",
		stale_dispatch.get("error", "").contains("catalog owner"))

	var second = Connection.new("second")
	second.tools = [Definition.from_dict({"name": "shared", "inputSchema": {"type": "object"}}, "second")]
	manager.servers["second"] = second
	manager._register_server_tools(second)
	check("tool collisions retain the established owner",
		manager.tool_registry.get("shared").server_name == "first"
		and manager._tool_connection_owners.get("shared") == first)
	manager._unregister_server_tools("first", replacement)
	check("unregister requires exact connection ownership",
		manager.tool_registry.has("shared"))
	manager._unregister_server_tools("first", first)
	check("exact owner unregister removes its catalog entry",
		not manager.tool_registry.has("shared"))
	replacement.tools = [Definition.from_dict(
		{"name": "shared", "description": "replacement", "inputSchema": {"type": "object"}},
		"first")]
	manager._replace_server_tools(replacement)
	check("the published replacement can atomically reclaim its server catalog",
		manager.tool_registry.get("shared").description == "replacement"
		and manager._tool_connection_owners.get("shared") == replacement)
	replacement.tools = [Definition.from_dict(
		{"name": "refreshed", "inputSchema": {"type": "object"}}, "first")]
	manager._on_catalog_committed("first", replacement)
	check("committed catalog signal publishes only the exact live owner",
		manager.tool_registry.has("refreshed") and not manager.tool_registry.has("shared")
		and manager._tool_connection_owners.get("refreshed") == replacement)
	first.tools = [Definition.from_dict(
		{"name": "stale", "inputSchema": {"type": "object"}}, "first")]
	manager._on_catalog_committed("first", first)
	check("stale committed signal cannot replace the live owner catalog",
		manager.tool_registry.has("refreshed") and not manager.tool_registry.has("stale"))
	manager.disconnect_all()
	manager.free()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)
