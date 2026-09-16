extends RefCounted
## Runtime-loaded host seam for the real loopback public-server integration.

signal changed

var tool_registry: Dictionary = {}
var minerva_server


class FixtureServer extends RefCounted:
	signal changed
	var _enabled_tool_sets: Array = []
	var calls := 0
	var holds_started := 0
	var release_holds := false

	func execute_tool_for_http(tool_name: String, arguments: Dictionary,
			_agent_id: String = "", context = null) -> Dictionary:
		calls += 1
		if tool_name == "minerva_hold":
			holds_started += 1
			changed.emit()
			while not release_holds and (context == null or not context.is_stopped()):
				await Engine.get_main_loop().process_frame
			return {"success": context == null or not context.is_stopped(), "held": true}
		if tool_name == "native_dot":
			var native := {}
			native.native_dot_field = StringName("native-value")
			return native
		return {"success": true, "echo": arguments.duplicate(true)}

	func execute_tool_for_http_outcome(tool_name: String, arguments: Dictionary,
			agent_id: String = "", context = null):
		var Outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd")
		var outcome = Outcome.new()
		outcome.application = await execute_tool_for_http(
			tool_name, arguments, agent_id, context)
		if tool_name == "plugin_rich":
			var Result = load("res://Scripts/Services/MCP/MCPToolResult.gd")
			outcome.envelope = Result.from_mcp({
				"resultType": "complete",
				"content": [{"type": "text", "text": "rich"}],
				"structuredContent": {"scalar": 3, "nullable": null},
				"isError": false, "_meta": {"kept": true},
				"futureResultField": {"preserved": true}}, true)
		return outcome


func _init() -> void:
	minerva_server = FixtureServer.new()
	_add_tool("minerva_echo", {"type": "object", "properties": {
		"value": {"type": "integer"}}, "required": ["value"]})
	_add_tool("minerva_hold", {"type": "object", "properties": {}})
	_add_tool("minerva_external", {"type": "object", "properties": {}}, "external")
	_add_tool("plugin_widget", {"type": "object", "properties": {
		"token": {"type": "string", "x-mcp-header": "Widget"}}}, "minerva", true)
	_add_tool("plugin_rich", {"type": "object", "properties": {}}, "minerva", true)
	_add_tool("native_dot", {"type": "object", "properties": {}})


func _add_tool(tool_name: String, schema: Dictionary, owner := "minerva",
		preserve_wire := false) -> void:
	var definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd").new()
	definition.name = tool_name
	definition.description = "C1 public server fixture"
	definition.input_schema = schema
	definition.server_name = owner
	definition.tool_set = "plugin" if tool_name == "plugin_widget" else ""
	if preserve_wire:
		definition.original_definition = {"name": tool_name,
			"description": definition.description, "inputSchema": schema.duplicate(true),
			"annotations": {"readOnlyHint": true}, "futureField": {"kept": true}}
	tool_registry[tool_name] = definition
