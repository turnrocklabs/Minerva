extends SceneTree

var passed := 0
var failed := 0

class ResultProcess extends Node:
	signal output_ready
	var output: Array[String] = []
	func is_running() -> bool: return true
	func write_data(line: String) -> bool:
		var request: Dictionary = JSON.parse_string(line)
		var response := {"jsonrpc": "2.0", "id": request.id, "result": {
			"content": [{"type": "text", "text": "ok"}],
			"structuredContent": {"precise": 0.1}, "future": {"opaque": true}}}
		output.append(JSON.stringify(response))
		output_ready.emit()
		return true
	func has_output() -> bool: return not output.is_empty()
	func read_line() -> String: return output.pop_front()

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _run() -> void:
	var Registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd")
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var Connection = load("res://test/helpers/mcp_definition_connection_fixture.gd")
	var registry = Registry.new()
	var connection = Connection.new()
	var original := {
		"name": "inspect", "description": "Inspect", "inputSchema": {"type": "object",
			"properties": {"tags": {"type": "array"}, "flag": false}},
		"outputSchema": {"type": "object", "required": ["ok"]},
		"annotations": {"readOnlyHint": true}, "icons": [{"src": "data:image/svg+xml;base64,AA=="}],
		"execution": {"taskSupport": "forbidden"}, "futureExtension": {"opaque": [1, 2]},
	}
	connection.tools = [Definition.from_dict(original, "fixture")]
	var registered: Dictionary = await registry.register_backend_tools("probe", connection)
	var entry: Dictionary = registry.find_tool("minerva_probe_inspect")
	var preserved: Dictionary = entry.get("mcp_definition", {})
	check("real backend registration preserves every definition field while rewriting only name",
		registered.get("ok", false) and preserved.name == "minerva_probe_inspect"
		and preserved.inputSchema == original.inputSchema
		and preserved.outputSchema == original.outputSchema and preserved.annotations == original.annotations
		and preserved.icons == original.icons and preserved.execution == original.execution
		and preserved.futureExtension == original.futureExtension)
	var reconstructed = Definition.from_dict(preserved, "minerva")
	check("registered definition survives the application registry adapter and MCP re-export",
		reconstructed.to_mcp_format() == preserved and reconstructed.output_schema == original.outputSchema)
	var before: Dictionary = registry.find_tool("minerva_probe_inspect")
	var malformed: Dictionary = registry.register_plugin_tools("probe", [{"name": "minerva_probe_bad",
		"_mcp_definition": {"name": "bad", "inputSchema": {}, "icons": ["not-an-icon"]}}])
	check("malformed optional fields reject the atomic replacement",
		malformed.has("error") and registry.find_tool("minerva_probe_inspect") == before)

	var process := ResultProcess.new()
	root.add_child(process)
	connection._subprocess = process
	process.output_ready.connect(connection._drain_stdout.bind(process))
	var envelopes: Array = []
	connection.tool_result_envelope_received.connect(
		func(_name: String, envelope): envelopes.append(envelope))
	var application_result: Dictionary = await connection._call_tool_stdio("inspect", {})
	check("real STDIO dispatch exposes a raw-preserving result envelope before legacy adaptation",
		envelopes.size() == 1 and envelopes[0].to_mcp_format().future.opaque
		and envelopes[0].wire_value.raw_utf8.contains("structuredContent")
		and application_result.text == "ok")
	connection._subprocess = null
	process.queue_free()
	connection = null
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
