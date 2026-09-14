extends SceneTree
## Real native dispatcher and connection lifecycle; requires isolated user data
## because dispatcher construction may migrate configuration. Tool operations
## are read-only; no sockets, model calls, or plugin processes are used.
## Only the completion timing is controlled.

const Context = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
var passed := 0
var failed := 0

class Gate extends RefCounted:
	signal released

class Probe extends RefCounted:
	var server
	var seen: Array[Dictionary] = []

	func can_handle(name: String) -> bool:
		return name == "minerva_context_probe"

	func handle_with_context(_name: String, arguments: Dictionary, context: Context) -> Dictionary:
		if arguments.has("gate"):
			await arguments.gate.released
		if arguments.get("nested", false):
			return await server.call_tool("minerva_context_probe", {}, context)
		var result := {"success": true, "chat": context.caller_chat_id,
			"agent": context.agent_id, "plugin": context.plugin_id, "origin": context.origin}
		seen.append(result)
		return result

class MemoryPersistence extends RefCounted:
	func read(_section: String, _key: String) -> Variant:
		return null

	func write(_section: String, _key: String, _value: Variant) -> void:
		assert(false, "read-only preference test must not write")

class Pipe extends RefCounted:
	var requests: Array[Dictionary] = []
	var connection
	var inline_reply := false

	func is_running() -> bool:
		return true

	func write_data(data: String) -> bool:
		var request: Dictionary = JSON.parse_string(data)
		requests.append(request)
		if inline_reply:
			connection._resolve_pending(str(request.id), {"jsonrpc": "2.0", "id": request.id,
				"result": {"success": true, "inline": true}})
		return true


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, value: bool) -> void:
	if value:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)


func collect(operation: Callable, results: Dictionary, key: String) -> void:
	results[key] = await operation.call()


func _run() -> void:
	await process_frame
	var Server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd")
	var Manager = load("res://Scripts/Services/MCP/MCPManager.gd")
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var Broker = load("res://Scripts/Services/Plugins/CapabilityBroker.gd")
	var Policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd")
	var Preferences = load("res://Scripts/Services/MCP/Modules/MCPPreferenceTools.gd")
	var Store = load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var server = Server.new()
	server.server_enabled = true
	server.auto_tool_management = false
	var probe := Probe.new()
	probe.server = server
	var preferences = Preferences.new(server)
	preferences._store_override = Store.new(null, MemoryPersistence.new())
	server._modules = [probe, preferences]
	var manager = Manager.new()
	manager.minerva_server = server
	for name in ["minerva_context_probe", "minerva_get_preference"]:
		var definition = Definition.new()
		definition.name = name
		definition.server_name = "minerva"
		manager.tool_registry[name] = definition
	var so = root.get_node("SingletonObject")
	var previous_manager = so.mcp_manager
	so.mcp_manager = manager
	var policy = Policy.new(null, null, false)
	var broker = Broker.new(policy, null)

	# Same production preference tool over every existing native entrypoint.
	var args := {"scope": "core", "key": "model"}
	var internal: Dictionary = await manager.execute_tool("minerva_get_preference", args, "chat-A")
	var module_result: Dictionary = await server.call_tool("minerva_get_preference", args)
	var http: Dictionary = await server.execute_tool_for_http("minerva_get_preference", args, "external-A")
	check("real preference tool retains equivalent native payloads across entrypoints",
		internal.get("success", false) and internal.get("value") == module_result.get("value")
		and internal.get("value") == http.get("value"))
	policy.grant_capability("probe", "mcp.proxy:minerva_get_preference")
	var proxied: Dictionary = await broker.dispatch("probe", "mcp.proxy:minerva_get_preference", args)
	check("granted proxy returns the same native domain value", proxied.get("success", false)
		and proxied.get("result", {}).get("value") == internal.get("value"))
	var denied: Dictionary = await broker.dispatch("ungranted", "mcp.proxy:minerva_context_probe", {})
	check("ungranted proxy never reaches native dispatch", not denied.get("success", true) and probe.seen.is_empty())
	var invalid: Dictionary = await server.call_tool("minerva_get_preference", {})
	var invalid_http: Dictionary = await server.execute_tool_for_http("minerva_get_preference", {})
	check("domain validation failures stay native and equivalent", not invalid.get("success", true)
		and invalid.get("error") == invalid_http.get("error"))
	var invalid_proxy: Dictionary = await broker.dispatch("probe", "mcp.proxy:minerva_get_preference", {})
	check("proxy keeps domain failure distinct from transport success", not invalid_proxy.get("success", true)
		and invalid_proxy.get("error_message") == invalid.get("error"))
	server.server_enabled = false
	var disabled: Dictionary = await manager.execute_tool("minerva_get_preference", args)
	var available: Dictionary = await server.execute_tool_for_http("minerva_get_preference", args)
	check("HTTP availability remains independent of internal enablement", not disabled.get("success", true)
		and available.get("success", false))
	server.server_enabled = true

	var gate_a := Gate.new()
	var gate_b := Gate.new()
	var results := {}
	collect(manager.execute_tool.bind("minerva_context_probe", {"gate": gate_a, "nested": true}, "chat-A"), results, "a")
	collect(server.execute_tool_for_http.bind("minerva_context_probe", {"gate": gate_b, "nested": true}, "agent-B"), results, "b")
	gate_b.released.emit()
	gate_a.released.emit()
	check("overlapping nested HTTP call retains its own identity", results.b.agent == "agent-B"
		and results.b.chat == "" and results.b.origin == "http")
	check("overlapping nested chat call retains its own identity", results.a.chat == "chat-A"
		and results.a.agent == "" and results.a.origin == "internal")
	policy.grant_capability("probe", "mcp.proxy:minerva_context_probe")
	var parent := Context.create("internal", "chat-parent")
	var provider := parent.for_provider("provider-B")
	check("provider ownership does not overwrite caller identity or lifetime", provider.provider_plugin_id == "provider-B"
		and provider.plugin_id.is_empty() and provider.call_id == parent.call_id and provider.lifetime == parent.lifetime)
	check("child deadline cannot extend the transport's normal request budget",
		Context.create("internal", "", "", 300.0).remaining_seconds() <= 120.0)
	var inherited: Dictionary = await broker.dispatch("probe", "mcp.proxy:minerva_context_probe", {}, parent)
	check("response-bound callback preserves parent and adds plugin provenance",
		inherited.result.chat == "chat-parent" and inherited.result.plugin == "probe")
	var standalone: Dictionary = await broker.dispatch("probe", "mcp.proxy:minerva_context_probe", {})
	check("legacy uncorrelated callback has explicit plugin origin and no guessed chat",
		standalone.result.origin == "plugin" and standalone.result.chat == "" and standalone.result.plugin == "probe")

	var cancel_context := Context.create("internal", "cancel-chat")
	var cancel_gate := Gate.new()
	var before := probe.seen.size()
	collect(server.call_tool.bind("minerva_context_probe", {"gate": cancel_gate, "nested": true}, cancel_context), results, "cancel")
	cancel_context.cancel()
	check("cancel releases caller before native await completes", results.has("cancel")
		and results.cancel.get("error_code") == "cancelled")
	cancel_gate.released.emit()
	check("cancelled parent cannot begin a nested mutation", probe.seen.size() == before)
	var deadline := Context.create("internal", "", "", 0.02)
	var deadline_gate := Gate.new()
	var timed: Dictionary = await server.call_tool("minerva_context_probe", {"gate": deadline_gate, "nested": true}, deadline)
	check("deadline releases native waiter", timed.get("error_code") == "deadline_exceeded")
	deadline_gate.released.emit()

	await _test_connection_context()
	so.mcp_manager = previous_manager
	probe.server = null
	preferences.server = null
	manager.minerva_server = null
	manager.free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func _test_connection_context() -> void:
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var connection = Connection.new()
	connection.transport = Connection.TransportType.STDIO
	var pipe := Pipe.new()
	pipe.connection = connection
	connection._subprocess = pipe
	var first := Context.create("internal", "A")
	var second := Context.create("internal", "B")
	var results := {}
	collect(connection.call_tool_with_context.bind("first", {}, first), results, "first")
	collect(connection.call_tool_with_context.bind("second", {}, second), results, "second")
	first.cancel()
	check("connection cancellation removes only its owned request", connection.pending_request_count() == 1
		and results.first.get("error_code") == "cancelled" and not results.has("second"))
	var request: Dictionary = pipe.requests[1]
	connection._resolve_pending(str(request.id), {"id": request.id, "result": {"success": true, "other": true}})
	check("concurrent unrelated request completes normally", results.second.get("other", false)
		and connection.pending_request_count() == 0)
	pipe.inline_reply = true
	var inline_result: Dictionary = await connection.call_tool_with_context("inline", {}, Context.create("internal"))
	check("synchronous completion cannot strand the waiter", inline_result.get("inline", false))
	connection._subprocess = null
	pipe.connection = null
