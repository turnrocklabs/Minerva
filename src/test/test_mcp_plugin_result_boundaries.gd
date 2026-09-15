extends SceneTree
## Real-child plugin dispatch covers native schema validation, correlated full
## outcomes, MRTR classification, and the privileged capability boundary.

const FIXTURE := "res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"
var passed := 0
var failed := 0

class ProbeCapabilityBroker extends RefCounted:
	signal first_entered
	signal release_first
	var calls := 0
	var hold_first := false
	func dispatch(_plugin: String, _capability: String, _args: Dictionary,
			_context = null) -> Dictionary:
		calls += 1
		if hold_first and calls == 1:
			first_entered.emit()
			await release_first
		return {"success": true}

	func release_held() -> void:
		release_first.emit()

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 unavailable")
		quit(0)
		return
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var CustomWebSocketConnection = load(
		"res://test/helpers/mcp_custom_websocket_connection_fixture.gd")
	var Registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd")
	var Manager = load("res://test/helpers/plugin_tool_manager_fixture.gd")
	var connection = Connection.new("plugin-boundary")
	connection.configure_stdio("python3", PackedStringArray([
		ProjectSettings.globalize_path(FIXTURE), "--profile", "modern"]))
	var manager = Manager.new()
	manager.connections["probe"] = connection
	var registry = Registry.new(manager)
	var broker := ProbeCapabilityBroker.new()
	registry.capability_broker = broker
	check("real modern plugin connects and registers its native definitions",
		await connection.connect_to_server() == OK
		and (await registry.register_backend_tools("probe", connection)).get("ok", false))

	var interaction = await registry.handle_tool_call_outcome("minerva_probe_input_required", {})
	check("plugin result-aware path preserves and classifies input_required before text",
		interaction.envelope != null and interaction.envelope.result_type == "input_required"
		and interaction.application.get("error_code") == "input_required"
		and interaction.application.get("requestState", {}).get("opaque")
		and broker.calls == 0)
	var nested = await registry.handle_tool_call_outcome("minerva_probe_nested_precision_loss", {})
	check("unsafe nested JSON cannot reach plugin application or capability processing",
		nested.application.get("error_code") == "unsupported_number" and broker.calls == 0)
	var echo = await registry.handle_tool_call_outcome(
		"minerva_probe_echo", {"marker": "full-outcome"})
	check("plugin dispatch retains the same full result envelope with its application view",
		echo.envelope != null and echo.envelope.to_mcp_format().futureField.kept
		and echo.application.get("echo", {}).get("marker") == "full-outcome")
	var invalid_input = await registry.handle_tool_call_outcome(
		"minerva_probe_typed_input", {"count": "7"})
	check("plugin arguments validate against the native schema without LLM coercion",
		invalid_input.application.has("error") and invalid_input.envelope == null)
	var invalid_output = await registry.handle_tool_call_outcome(
		"minerva_probe_requires_output", {})
	check("declared structured output is validated before capability exposure",
		invalid_output.application.has("error") and invalid_output.envelope != null
		and broker.calls == 0)
	var ExternalManager = load("res://Scripts/Services/MCP/MCPManager.gd")
	var native_manager = ExternalManager.new()
	native_manager.servers["plugin-boundary"] = connection
	native_manager._register_server_tools(connection)
	var manager_outcomes: Array = []
	native_manager.tool_outcome_executed.connect(
		func(_server: String, _tool: String, value): manager_outcomes.append(value))
	var manager_invalid_input: Dictionary = await native_manager.execute_tool(
		"typed_input", {"count": "not-an-integer"})
	var manager_invalid_output: Dictionary = await native_manager.execute_tool(
		"requires_output", {})
	check("external Manager enforces normalized native input and output validation",
		manager_invalid_input.get("error_code") == "schema_mismatch"
		and manager_invalid_output.get("error_code") == "schema_mismatch"
		and manager_outcomes.size() == 1 and manager_outcomes[0].envelope != null)
	native_manager.servers.clear()
	native_manager.free()
	var SchemaRuntime = load("res://Scripts/Services/MCP/MCPToolSchemaRuntime.gd")
	var schema_results: Array = []
	for wave in range(9):
		var wave_results: Array = []
		for index in range(40):
			var schema := {"type": "object", "title": "schema-%d" % (index % 3),
				"properties": {"value": {"type": "integer"}}}
			_collect(SchemaRuntime.validate.bind(schema, {"value": wave}), wave_results)
		await _wait_size(wave_results, 40, 7000)
		schema_results.append_array(wave_results)
	var queue_rejections := 0
	var unexpected_schema_failures := 0
	for schema_result: Variant in schema_results:
		if not schema_result.get("ok", false):
			if schema_result.get("error", {}).get("code") == "queue_full":
				queue_rejections += 1
			else:
				unexpected_schema_failures += 1
	var after_contention: Dictionary = await SchemaRuntime.validate(
		{"type": "object"}, {"still": "usable"})
	check("concurrent schema operations stay bounded and release every native handle",
		schema_results.size() == 360 and queue_rejections == 72
		and unexpected_schema_failures == 0 and after_contention.get("ok", false))
	var valid_output = await registry.handle_tool_call_outcome("minerva_probe_valid_output", {})
	var valid_array_output = await registry.handle_tool_call_outcome(
		"minerva_probe_valid_array_output", {})
	var expected_error = await registry.handle_tool_call_outcome(
		"minerva_probe_error_missing_output", {})
	check("valid structured output passes while isError needs no structuredContent",
		valid_output.application.get("success", false)
		and valid_array_output.application.get("success", false)
		and expected_error.envelope != null and not expected_error.application.get("success", true))
	var modern_direct = await registry.handle_tool_call_outcome(
		"minerva_probe_capability_direct", {})
	check("modern result fields remain application data rather than legacy host control",
		modern_direct.application.get("capability_requests", []).size() == 1
		and broker.calls == 0)
	var legacy_connection = Connection.new("plugin-boundary-legacy")
	legacy_connection.configure_stdio("python3", PackedStringArray([
		ProjectSettings.globalize_path(FIXTURE), "--profile", "legacy"]))
	manager.connections["probe"] = legacy_connection
	check("legacy plugin reconnects and atomically replaces its backend catalog",
		await legacy_connection.connect_to_server() == OK
		and (await registry.register_backend_tools("probe", legacy_connection)).get("ok", false))
	var direct = await registry.handle_tool_call_outcome("minerva_probe_capability_direct", {})
	var calls_after_direct := broker.calls
	var nested_capability = await registry.handle_tool_call_outcome(
		"minerva_probe_capability_nested", {})
	check("only the directly validated capability payload reaches the broker",
		direct.application.get("capability_results", []).size() == 1
		and calls_after_direct == 1 and broker.calls == calls_after_direct
		and not nested_capability.application.has("capability_results"))

	broker.calls = 0
	broker.hold_first = true
	var capability_results: Array = []
	_collect(registry.handle_tool_call_outcome.bind(
		"minerva_probe_capability_two", {}), capability_results)
	await broker.first_entered
	manager.connections["probe"] = Connection.new("replacement")
	broker.call_deferred("release_held")
	var capability_settled := await _wait_size(capability_results, 1, 3000)
	check("connection replacement during a capability await suppresses the second request",
		capability_settled and capability_results[0].application.has("error")
		and broker.calls == 1)
	manager.connections["probe"] = legacy_connection
	broker.hold_first = false

	# Custom WebSocket servers remain on their established application contract;
	# the additive outcome API must not require a modern MCP envelope.
	var websocket_connection = CustomWebSocketConnection.new("custom-websocket")
	websocket_connection.transport = Connection.TransportType.WEBSOCKET
	websocket_connection.server_connected = true
	var websocket_outcome = await websocket_connection.call_tool_outcome_with_context(
		"custom", {"marker": "preserved"},
		load("res://Scripts/Services/MCP/MCPExecutionContext.gd").create("internal"))
	check("custom WebSocket calls retain their native application result through the outcome seam",
		websocket_outcome.envelope == null
		and websocket_outcome.application.get("custom") == "preserved")
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var external_manager = ExternalManager.new()
	external_manager.servers["custom-websocket"] = websocket_connection
	websocket_connection.tools = [Definition.from_dict(
		{"name": "custom", "inputSchema": {"type": "object"}}, "custom-websocket")]
	external_manager._register_server_tools(websocket_connection)
	var websocket_result: Dictionary = await external_manager.execute_tool(
		"custom", {"marker": "manager-preserved"})
	check("manager dispatch keeps the custom WebSocket compatibility lane",
		websocket_result.get("custom") == "manager-preserved")
	websocket_connection.disconnect_from_server()
	external_manager.servers.clear()
	external_manager.free()

	legacy_connection.disconnect_from_server()
	connection.disconnect_from_server()
	registry.plugin_manager = null
	registry.capability_broker = null
	manager.connections.clear()
	manager.free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)


func _collect(operation: Callable, results: Array) -> void:
	results.append(await operation.call())


func _wait_size(values: Array, expected: int, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while values.size() < expected and Time.get_ticks_msec() < deadline:
		await process_frame
	return values.size() == expected
