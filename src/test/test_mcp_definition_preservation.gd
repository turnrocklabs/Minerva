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
	var PluginManagerScript = load("res://Scripts/Services/Plugins/PluginManager.gd")
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
	var panel_seed: Dictionary = registry.register_plugin_tools("probe", [{
		"name": "minerva_probe_panel", "description": "Installed panel action",
		"input_schema": {"type": "object"}, "executor": "panel"}])
	var registered: Dictionary = await registry.register_backend_tools("probe", connection)
	var entry: Dictionary = registry.find_tool("minerva_probe_inspect")
	var preserved: Dictionary = entry.get("mcp_definition", {})
	check("real backend registration preserves every definition field while rewriting only name",
		registered.get("ok", false) and preserved.name == "minerva_probe_inspect"
		and preserved.inputSchema == original.inputSchema
		and preserved.outputSchema == original.outputSchema and preserved.annotations == original.annotations
		and preserved.icons == original.icons and preserved.execution == original.execution
		and preserved.futureExtension == original.futureExtension)
	check("backend catalog replacement preserves installed panel tools",
		panel_seed.get("ok", false)
		and registry.find_tool("minerva_probe_panel").get("executor") == "panel")
	var reconstructed = Definition.from_dict(preserved, "minerva")
	check("registered definition survives the application registry adapter and MCP re-export",
		reconstructed.to_mcp_format() == preserved and reconstructed.output_schema == original.outputSchema
		and reconstructed.native_input_schema() == original.inputSchema
		and reconstructed.input_schema.properties.tags.has("items"))
	var malformed_root = Definition.from_dict(
		{"name": "malformed", "inputSchema": true, "outputSchema": false}, "fixture")
	check("native schema accessors preserve malformed scalar roots for explicit rejection",
		malformed_root.native_input_schema() == true
		and malformed_root.native_output_schema() == false)
	var before: Dictionary = registry.find_tool("minerva_probe_inspect")
	var malformed: Dictionary = registry.register_plugin_tools("probe", [{"name": "minerva_probe_bad",
		"_mcp_definition": {"name": "bad", "inputSchema": {}, "icons": ["not-an-icon"]}}])
	check("malformed optional fields reject the atomic replacement",
		malformed.has("error") and registry.find_tool("minerva_probe_inspect") == before)

	var manager = PluginManagerScript.new()
	registry.plugin_manager = manager
	var stale = Connection.new()
	stale.tools = [Definition.from_dict(original, "fixture")]
	stale.hold_refresh = true
	manager._runtime["probe"] = {"connection": stale}
	var stale_results: Array = []
	_collect(registry.register_backend_tools.bind("probe", stale), stale_results)
	check("held discovery entered before ownership replacement", stale.refresh_entered_flag)
	var replacement = Connection.new()
	manager._runtime["probe"] = {"connection": replacement}
	stale.release_refresh.emit()
	await process_frame
	check("stale backend discovery cannot replace the current plugin catalog",
		stale_results.size() == 1 and stale_results[0].has("error")
		and registry.find_tool("minerva_probe_inspect") == before)

	var process := ResultProcess.new()
	root.add_child(process)
	connection._subprocess = process
	var drain_callback: Callable = connection._drain_stdout.bind(process)
	process.output_ready.connect(drain_callback)
	var envelopes: Array = []
	connection.tool_result_envelope_received.connect(
		func(_name: String, envelope): envelopes.append(envelope))
	var call_outcome = await connection._call_tool_stdio_outcome("inspect", {})
	var application_result: Dictionary = call_outcome.application
	check("real STDIO dispatch exposes a raw-preserving result envelope before legacy adaptation",
		envelopes.size() == 1 and envelopes[0].to_mcp_format().future.opaque
		and call_outcome.envelope == envelopes[0]
		and envelopes[0].wire_value.raw_utf8.contains("structuredContent")
		and application_result.text == "ok")
	var Context = load("res://Scripts/Services/MCP/MCPExecutionContext.gd")
	var cancelled_context = Context.create("envelope-cancel")
	var application_emissions: Array = []
	connection.tool_result_received.connect(func(_name: String, _result: Dictionary) -> void:
		application_emissions.append(true))
	connection.tool_result_envelope_received.connect(
		func(_name: String, _envelope) -> void: cancelled_context.cancel(), CONNECT_ONE_SHOT)
	var cancelled_outcome = await connection._call_tool_stdio_outcome(
		"inspect", {}, 5.0, cancelled_context)
	check("synchronous envelope cancellation suppresses the stale application signal",
		cancelled_outcome.application.has("error") and application_emissions.is_empty())
	connection._subprocess = null
	process.output_ready.disconnect(drain_callback)
	process.queue_free()
	await process_frame
	registry.plugin_manager = null
	manager._runtime.clear()
	manager.free()
	connection = null
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func _collect(operation: Callable, results: Array) -> void:
	results.append(await operation.call())
