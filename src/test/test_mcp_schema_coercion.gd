extends SceneTree
## Exercise discovered schemas through HTTP dispatch, the plugin registry and
## scene-panel broker. The panel observes native types before JSON encoding.

class EchoPanel extends Control:
	signal entered
	signal release
	var calls := 0
	var invalid_output := false
	var error_output := false
	func handle_tool(_name: String, args: Dictionary) -> Dictionary:
		calls += 1
		if args.get("wait", false):
			entered.emit()
			await release
		if invalid_output:
			return {"success": true, "integer": "wrong"}
		if error_output:
			return {"success": false, "error": "expected panel refusal"}
		return {"success": true, "integer": args.wait_ms is int,
			"number": args.clearance is float, "boolean": args.enabled is bool,
			"object": args.options is Dictionary, "wire": JSON.stringify(args)}

var passed := 0
var failed := 0

func collect_outcome(server, tool: String, args: Dictionary, holder: Array,
		context = null) -> void:
	holder.append(await server.execute_tool_for_http_outcome(tool, args, "", context))


func wait_for(predicate: Callable, timeout_ms := 3000) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

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
		"options": {"type": "object"}, "wait": {"type": "boolean"}}}}
	var native_definition: Dictionary = definition.duplicate(true)
	native_definition["executor"] = "panel"
	native_definition["outputSchema"] = {"type": "object", "properties": {
		"success": {"type": "boolean"}, "integer": {"type": "boolean"}},
		"required": ["success", "integer"]}
	var registration: Dictionary = registry.register_plugin_tools(
		"coercion", [native_definition])
	check("fixture publishes the declared native input schema",
		registration.get("ok", false))
	server.tool_budget_manager.activate_tool(tool, definition)
	var valid_args := {"editor_name": "coercion-fixture", "wait_ms": 0,
		"clearance": 0.27, "enabled": true, "options": {"fit": true}}
	var before_validation_calls: int = panel.calls
	var replaced_during_validation: Array = []
	collect_outcome(server, tool, valid_args, replaced_during_validation)
	registration = registry.register_plugin_tools("coercion", [native_definition])
	check("replacement during input validation never dispatches the retired tool",
		registration.get("ok", false)
		and await wait_for(func() -> bool: return replaced_during_validation.size() == 1)
		and panel.calls == before_validation_calls
		and replaced_during_validation[0].application.get("success") == false)
	var args: Dictionary = JSON.parse_string('{"editor_name":"coercion-fixture","wait_ms":0,"clearance":0.27,"enabled":"true","options":"{\\"fit\\":true}"}')
	var public_reply: Dictionary = await server.execute_tool_for_http(tool, args)
	check("public protocol validates raw arguments without LLM coercion",
		public_reply.get("success") == false and panel.calls == 0)
	var reply: Dictionary = await server.call_tool(tool, args)
	check("host/plugin boundary receives declared types", reply.get("integer", false)
		and reply.get("number", false) and reply.get("boolean", false) and reply.get("object", false))
	check("integer is serialized without a fractional suffix", str(reply.get("wire", "")).contains('"wait_ms":0,')
		or str(reply.get("wire", "")).contains('"wait_ms":0}'))
	var public_outcome = await server.execute_tool_for_http_outcome(tool, valid_args)
	var http = load("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd").new()
	var public_result: Dictionary = http._public_result_from_outcome(public_outcome, true)
	check("validated native panel output is explicit public structuredContent",
		public_outcome.envelope == null and not public_outcome.wire_authoritative
		and public_result.get("structuredContent", {}).get("integer") == true)
	panel.invalid_output = true
	var invalid_output = await server.execute_tool_for_http_outcome(tool, valid_args)
	check("declared panel outputSchema rejects invalid successful native output",
		invalid_output.application.get("success") == false
		and invalid_output.application.get("error_code") == "schema_mismatch")
	panel.invalid_output = false
	panel.error_output = true
	var error_output = await server.execute_tool_for_http_outcome(tool, valid_args)
	check("native panel errors skip successful outputSchema validation",
		error_output.application.get("success") == false
		and error_output.application.get("error") == "expected panel refusal")
	panel.error_output = false
	http.free()
	var entered_count := [0]
	panel.entered.connect(func() -> void: entered_count[0] += 1)
	var waiting_args: Dictionary = valid_args.duplicate(true)
	waiting_args["wait"] = true
	var unrelated_holder: Array = []
	collect_outcome(server, tool, waiting_args, unrelated_holder)
	check("panel handler entered before unrelated registration",
		await wait_for(func() -> bool: return entered_count[0] == 1))
	var unrelated_registration: Dictionary = registry.register_plugin_tools(
		"unrelated", [])
	panel.release.emit()
	check("unrelated registration does not cancel the owned panel call",
		unrelated_registration.get("ok", false)
		and await wait_for(func() -> bool: return unrelated_holder.size() == 1)
		and unrelated_holder[0].application.get("success") == true)
	var stale_holder: Array = []
	collect_outcome(server, tool, waiting_args, stale_holder)
	check("panel handler entered before registration replacement",
		await wait_for(func() -> bool: return entered_count[0] == 2))
	registration = registry.register_plugin_tools("coercion", [native_definition])
	panel.release.emit()
	check("registration replacement suppresses a stale panel completion",
		registration.get("ok", false)
		and await wait_for(func() -> bool: return stale_holder.size() == 1)
		and stale_holder[0].application.get("success") == false)
	var context = load("res://Scripts/Services/MCP/MCPExecutionContext.gd").create("http")
	var cancelled_holder: Array = []
	collect_outcome(server, tool, waiting_args, cancelled_holder, context)
	check("replacement registration remains callable before cancellation",
		await wait_for(func() -> bool: return entered_count[0] == 3))
	context.cancel()
	panel.release.emit()
	check("cancelled panel completion cannot become a public success",
		await wait_for(func() -> bool: return cancelled_holder.size() == 1)
		and cancelled_holder[0].application.get("success") == false)
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
