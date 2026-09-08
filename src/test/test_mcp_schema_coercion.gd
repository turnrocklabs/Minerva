extends SceneTree
## Exercise discovered schemas through HTTP dispatch, the plugin registry and
## scene-panel broker. The panel observes native types before JSON encoding.

class EchoPanel extends Control:
	func handle_tool(_name: String, args: Dictionary) -> Dictionary:
		return {"success": true, "integer": args.wait_ms is int,
			"number": args.clearance is float, "boolean": args.enabled is bool,
			"object": args.options is Dictionary, "wire": JSON.stringify(args)}

var passed := 0
var failed := 0

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _init() -> void:
	await process_frame
	var panel := EchoPanel.new()
	root.add_child(panel)
	var driver = load("res://test/helpers/panel_tool_registry_driver.gd").new()
	var tool := "minerva_coercion_echo"
	var registry = driver.build(panel, "coercion", "coercion-fixture", [tool])
	var host = root.get_node("SingletonObject")
	var previous = host.plugin_tool_registry
	host.plugin_tool_registry = registry
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	var definition := {"name": tool, "description": "coercion fixture", "input_schema": {
		"type": "object", "properties": {"wait_ms": {"type": "integer"},
		"clearance": {"type": "number"}, "enabled": {"type": "boolean"},
		"options": {"type": "object"}}}}
	server.tool_budget_manager.activate_tool(tool, definition)
	var args: Dictionary = JSON.parse_string('{"editor_name":"coercion-fixture","wait_ms":0,"clearance":0.27,"enabled":"true","options":"{\\"fit\\":true}"}')
	var reply: Dictionary = await server.execute_tool_for_http(tool, args)
	check("host/plugin boundary receives declared types", reply.get("integer", false)
		and reply.get("number", false) and reply.get("boolean", false) and reply.get("object", false))
	check("integer is serialized without a fractional suffix", str(reply.get("wire", "")).contains('"wait_ms":0,')
		or str(reply.get("wire", "")).contains('"wait_ms":0}'))
	var utils = load("res://Scripts/Services/MCP/Modules/MCPToolUtils.gd")
	var invalid := {"wait_ms": 0.5, "clearance": "unknown", "enabled": "perhaps", "options": "[]"}
	var kept: Dictionary = utils.coerce_args_to_schema(invalid.duplicate(true), definition)
	check("invalid values remain available for validation", kept == invalid)
	var bare: Dictionary = utils.coerce_args_to_schema({"wait_ms": 7.0, "clearance": 0.42}, definition.input_schema)
	check("bare schemas work and real dimensions keep their fraction", bare.wait_ms is int and bare.clearance == 0.42)
	host.plugin_tool_registry = previous
	panel.queue_free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
