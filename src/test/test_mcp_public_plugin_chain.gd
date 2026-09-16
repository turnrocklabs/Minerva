extends SceneTree
## End-to-end public HTTP -> production Minerva spine -> real STDIO plugin.
## Requires python3, the schema helper, and isolated user data.

const FIXTURE := "res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
var passed := 0
var failed := 0
var port := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool, detail := "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " ", detail)

func _wait(predicate: Callable, timeout_ms := 7000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func _parse_object(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {}
	return parser.data

func _request(marker: String, modern: bool) -> Dictionary:
	var request := {"jsonrpc": "2.0", "id": marker, "method": "tools/call",
		"params": {"name": "minerva_probe_echo", "arguments": {"marker": marker}}}
	var headers := PackedStringArray(["POST /mcp HTTP/1.1", "Host: 127.0.0.1",
		"Content-Type: application/json", "Accept: application/json, text/event-stream"])
	if modern:
		request.params["_meta"] = Protocol.modern_meta(Protocol.MODERN_VERSION, {})
		headers.append("MCP-Protocol-Version: " + Protocol.MODERN_VERSION)
		headers.append("Mcp-Method: tools/call")
		headers.append("Mcp-Name: minerva_probe_echo")
	var body := JSON.stringify(request).to_utf8_buffer()
	headers.append("Content-Length: %d" % body.size())
	headers.append("Connection: close")
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	if not await _wait(func() -> bool:
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED):
		peer.disconnect_from_host()
		return {}
	peer.put_data(("\r\n".join(headers) + "\r\n\r\n").to_utf8_buffer())
	peer.put_data(body)
	var raw := PackedByteArray()
	var completed: bool = await _wait(func() -> bool:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var available: int = peer.get_available_bytes()
			if available > 0:
				raw.append_array(peer.get_data(available)[1])
		return peer.get_status() in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR])
	if not completed:
		peer.disconnect_from_host()
		return {}
	var text := raw.get_string_from_utf8()
	var boundary := text.find("\r\n\r\n")
	if boundary < 0 or not text.begins_with("HTTP/1.1 200"):
		return {}
	var declared_length := -1
	for header_line: String in text.substr(0, boundary).split("\r\n"):
		if header_line.to_lower().begins_with("content-length:"):
			declared_length = int(header_line.get_slice(":", 1).strip_edges())
			break
	var response_body := text.substr(boundary + 4)
	if declared_length < 0 or response_body.to_utf8_buffer().size() != declared_length:
		return {}
	return _parse_object(response_body)

func _register_public_definition(registry, manager) -> void:
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	for entry: Dictionary in registry.get_plugin_tools("probe"):
		if entry.get("name") == "minerva_probe_echo":
			manager.tool_registry[entry.name] = Definition.from_dict(
				entry.mcp_definition, "minerva")
			return


func _exercise_webview_broker(registry, manager_fixture, singleton,
		marker: String) -> void:
	var Definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = Definition.new()
	definition.id = "probe"
	definition.ui_panel_names.assign(["probe-panel"])
	definition.state = Definition.State.RUNNING
	manager_fixture.get_db()._plugins["probe"] = definition
	var Policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd")
	var policy = Policy.new(manager_fixture.get_db(), null, false)
	var Capability = load("res://Scripts/Services/Plugins/CapabilityBroker.gd")
	var capability = Capability.new(policy)
	var Broker = load("res://Scripts/Services/Plugins/PluginWebviewBroker.gd")
	var broker = Broker.new(manager_fixture, policy, capability)
	broker.register_plugin_panel("probe", "probe-panel")
	var owned: Dictionary = await broker.handle_ipc_message("probe-panel",
		"mcp.proxy:minerva_probe_echo", {"marker": marker}, null, "probe")
	check("plugin document calls its exact registered real STDIO tool without a broad grant",
		owned.get("success", false)
		and owned.get("result", {}).get("echo", {}).get("marker") == marker,
		str(owned))
	var denied: Dictionary = await broker.handle_ipc_message("probe-panel",
		"mcp.proxy:minerva_tool_search", {"query": "note", "limit": 1}, null, "probe")
	check("cross-host tool proxy is denied before an exact grant",
		denied.get("success", true) == false
		and denied.get("error_code") == "capability_not_granted", str(denied))
	policy.grant_capability("probe", "mcp.proxy:minerva_tool_search")
	var allowed: Dictionary = await broker.handle_ipc_message("probe-panel",
		"mcp.proxy:minerva_tool_search", {"query": "note", "limit": 1}, null, "probe")
	check("exact grant reaches the production host policy and tool spine",
		allowed.get("success", false) and allowed.get("result") is Dictionary,
		str(allowed))
	var production_server = singleton.get_mcp_manager().minerva_server
	var saved_policy = production_server.policy_engine
	production_server.policy_engine = load(
		"res://test/helpers/mcp_blocking_policy_fixture.gd").new()
	var policy_denied: Dictionary = await broker.handle_ipc_message("probe-panel",
		"mcp.proxy:minerva_tool_search", {"query": "note", "limit": 1}, null, "probe")
	production_server.policy_engine = saved_policy
	check("production host-policy denial remains a bridge failure with its payload",
		policy_denied.get("success", true) == false
		and policy_denied.get("allowed") == false, str(policy_denied))
	broker.register_plugin_panel("replacement", "probe-panel")
	var stale: Dictionary = await broker.handle_ipc_message("probe-panel",
		"mcp.proxy:minerva_probe_echo", {"marker": "stale"}, null, "probe")
	check("retired document cannot inherit a replacement panel owner's authority",
		stale.get("success", true) == false
		and stale.get("error_code") == "permission_denied", str(stale))
	manager_fixture.get_db()._plugins.erase("probe")

func _collect_outcome(server, context, target: Array) -> void:
	target.append(await server.execute_tool_for_http_outcome(
		"minerva_probe_sleep", {"ms": 100}, "", context))

func _run() -> void:
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var Registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd")
	var ManagerFixture = load("res://test/helpers/plugin_tool_manager_fixture.gd")
	var manager_fixture = ManagerFixture.new()
	# The focused manager fixture is never added to the tree, so its production
	# _ready initializer does not construct PluginDB. Give broker policy and
	# ownership validation the same real DB implementation explicitly.
	manager_fixture._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var registry = Registry.new(manager_fixture)
	var singleton = root.get_node("SingletonObject")
	# Use the same lazy production initializer as the application, then complete
	# plugin initialization before replacing its registry for this fixture. This
	# prevents the deferred normal startup path from overwriting the test owner.
	var production_manager = singleton.get_mcp_manager()
	production_manager.connect_minerva_server()
	singleton.initialize_plugins()
	check("production MCP spine is initialized",
		production_manager.minerva_server != null
		and singleton.plugin_tool_registry != null)
	var saved_registry = singleton.plugin_tool_registry
	singleton.plugin_tool_registry = registry
	var http_server = load("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd").new()
	root.add_child(http_server)
	http_server._mcp_manager = production_manager
	check("isolated public server starts", http_server.start_server(0) == OK)
	port = http_server.get_port()
	for back_era: String in ["modern", "legacy"]:
		var connection = Connection.new("public-chain-" + back_era)
		connection.configure_stdio("python3", PackedStringArray([
			ProjectSettings.globalize_path(FIXTURE), "--profile", back_era]))
		manager_fixture.connections["probe"] = connection
		check("real %s backend registers" % back_era,
			await connection.connect_to_server() == OK
			and (await registry.register_backend_tools("probe", connection)).get("ok", false))
		_register_public_definition(registry, production_manager)
		await _exercise_webview_broker(registry, manager_fixture, singleton,
			back_era + "-broker")
		for modern_front in [false, true]:
			var marker := "%s-%s" % [back_era, "modern" if modern_front else "legacy"]
			var response := await _request(marker, modern_front)
			var result: Dictionary = response.get("result", {})
			var application: Dictionary = _parse_object(
				result.get("content", [{}])[0].get("text", ""))
			check("%s backend reaches %s public front with preserved result" % [
				back_era, "modern" if modern_front else "legacy"],
				response.get("id") == marker
				and application is Dictionary and application.get("success", false)
				and application.get("echo", {}).get("marker") == marker
				and not result.get("isError", false)
				and result.get("futureField", {}).get("kept", false)
				and result.get("structuredContent", {}).get("fixture") == "preserved"
				and result.has("resultType") == modern_front, str(response))
		var duplicate_marker: String = back_era + "-duplicate"
		await _request(duplicate_marker, true)
		var duplicate_response := await _request(duplicate_marker, true)
		var duplicate_result: Dictionary = duplicate_response.get("result", {})
		var duplicate_application: Dictionary = _parse_object(
			duplicate_result.get("content", [{}])[0].get("text", ""))
		check("production duplicate-call mutation replaces the accepted backend envelope",
			duplicate_application is Dictionary
			and duplicate_application.has("warning")
			and duplicate_result.get("structuredContent", {}).get("fixture") == "preserved"
			and not duplicate_result.has("futureField"), str(duplicate_response))
		var Context = load("res://Scripts/Services/MCP/MCPExecutionContext.gd")
		var cancelled_context = Context.create("http")
		var cancelled_outcomes: Array = []
		_collect_outcome(production_manager.minerva_server, cancelled_context,
			cancelled_outcomes)
		await process_frame
		cancelled_context.cancel()
		check("cancelled production completion cannot retain backend wire authority",
			await _wait(func() -> bool: return not cancelled_outcomes.is_empty())
			and not cancelled_outcomes[0].wire_authoritative
			and cancelled_outcomes[0].application.get("error_code") == "cancelled")
		var saved_policy = production_manager.minerva_server.policy_engine
		production_manager.minerva_server.policy_engine = load(
			"res://test/helpers/mcp_blocking_policy_fixture.gd").new()
		var denied_response := await _request(back_era + "-policy-denied", true)
		production_manager.minerva_server.policy_engine = saved_policy
		var denied_result: Dictionary = denied_response.get("result", {})
		var denied_application: Dictionary = _parse_object(
			denied_result.get("content", [{}])[0].get("text", ""))
		check("production host policy denial is exported as a local tool error",
			denied_result.get("isError", false)
			and denied_application is Dictionary
			and denied_application.get("allowed") == false
			and not denied_result.has("futureField"), str(denied_response))
		connection.disconnect_from_server()
	production_manager.tool_registry.erase("minerva_probe_echo")
	singleton.plugin_tool_registry = saved_registry
	http_server.stop_server()
	http_server.queue_free()
	manager_fixture.connections.clear()
	manager_fixture.free()
	print("Public plugin chain: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
