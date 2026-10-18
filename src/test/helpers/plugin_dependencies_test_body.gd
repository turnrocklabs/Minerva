extends Node
signal completed(code: int)
var failures: int = 0
var checks: int = 0

func check(label: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("PASS: " + label)
	else:
		failures += 1
		printerr("FAIL: " + label)

func manifest(id: String, provider: String = "") -> Dictionary:
	var value := {"id": id, "name": id, "version": "1.0.0", "host_api_version": "2", "backend": {"transport": "stdio", "entrypoint": "python3"}}
	if not provider.is_empty():
		value["capabilities"] = ["plugin_dependencies"]
		value["requires_plugins"] = [{"id": provider, "min_version": "1.0.0", "actions": ["minerva_" + provider + "_probe"]}]
	return value

func _ready() -> void:
	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		printerr("FAIL: dependency fixture timed out")
		completed.emit(1))
	var raw := manifest("consumer", "agent_relay")
	var before := raw.duplicate(true)
	var parsed := PluginDefinition.from_dict(JSON.parse_string(JSON.stringify(raw)))
	check("valid dependency round-trips JSON without mutating input", parsed != null and raw == before)
	if parsed == null:
		completed.emit(1)
		return
	check("data-only capability passes installation validation", parsed.validate_capabilities().is_empty())
	var restored := PluginDefinition.from_dict(JSON.parse_string(JSON.stringify(parsed.to_dict())))
	check("persisted dependency retains version and canonical actions", restored != null and restored.requires_plugins == parsed.requires_plugins)
	for field: String in ["id", "min_version", "actions"]:
		for bad: Variant in [null, 1, {}]:
			var invalid := raw.duplicate(true)
			invalid.requires_plugins[0][field] = bad
			check("malformed dependency field refuses: " + field, PluginDefinition.from_dict(invalid) == null)
	for bad: String in ["1.0", "01.0.0", "1.0.0-01", "1.0.0+", "1.0.0\n"]:
		var invalid := raw.duplicate(true)
		invalid.requires_plugins[0].min_version = bad
		check("malformed min_version refuses: " + bad, PluginDefinition.from_dict(invalid) == null)
	for bad: String in ["minerva_voice_probe", "minerva_agent_relay_", "minerva_agent_relay_a/b"]:
		var invalid := raw.duplicate(true)
		invalid.requires_plugins[0].actions = [bad]
		check("foreign or malformed action refuses", PluginDefinition.from_dict(invalid) == null)
	var duplicated_provider := raw.duplicate(true)
	duplicated_provider.requires_plugins.append(duplicated_provider.requires_plugins[0].duplicate(true))
	check("duplicate provider refuses", PluginDefinition.from_dict(duplicated_provider) == null)
	var prerelease := raw.duplicate(true)
	prerelease.requires_plugins[0].min_version = "1.0.0-rc.1+build.2"
	check("valid prerelease and build accepted", PluginDefinition.from_dict(prerelease) != null)
	var null_requirements := raw.duplicate(true)
	null_requirements.requires_plugins = null
	check("explicit JSON null is not an absent requirement array", PluginDefinition.from_dict(JSON.parse_string(JSON.stringify(null_requirements))) == null)
	var no_cap := raw.duplicate(true)
	no_cap.erase("capabilities")
	check("dependencies cannot silently run without the capability", PluginDefinition.from_dict(no_cap) == null)
	check("self and optional-provider requirements refuse", PluginDefinition.from_dict(manifest("voice", "voice")) == null
		and PluginDefinition.from_dict(manifest("consumer", "not_required")) == null)
	var db := PluginDB.new()
	var ids: Array[String] = ["voice", "agent_relay"]
	var original: Array[PluginDefinition] = []
	for id: String in ids:
		original.append(db.get_by_id(id))
	var voice := PluginDefinition.from_dict(manifest("voice", "agent_relay"))
	var relay := PluginDefinition.from_dict(manifest("agent_relay", "voice"))
	check("cycle fixture definitions are valid individually", voice != null and relay != null)
	if voice != null and relay != null:
		check("update target already exists without a dependency", db.restore(PluginDefinition.from_dict(manifest("agent_relay"))))
		check("first requirement persists through the owning DB API", db.restore(voice))
		check("cycle update is refused atomically", not db.update_definition(relay) and db.dependency_issue(relay.id, relay).contains("voice")
			and db.get_last_install_error().get("error_code") == "plugin_dependency_cycle" and db.get_by_id("agent_relay").requires_plugins.is_empty())
		check("rollback API can seed a persisted recovery fixture", db.restore(relay))
		var loaded := PluginDB.new()
		check("both persisted fixture records load", loaded.has_plugin("voice") and loaded.has_plugin("agent_relay"))
		check("load marks cyclic records ERROR with both named providers", loaded.has_plugin("voice") and loaded.has_plugin("agent_relay") and loaded.get_by_id("voice").state == PluginDefinition.State.ERROR
			and loaded.get_by_id("agent_relay").state == PluginDefinition.State.ERROR and loaded.dependency_issue("voice").contains("agent_relay"))
		var manager := PluginManager.new()
		get_tree().root.add_child(manager)
		loaded = manager.get_db()
		check("initialized manager recovers the persisted records", manager.is_node_ready() and loaded.has_plugin("voice"))
		check("load-time cycle is visible in the copyable plugin status", str(manager.get_plugin_status("voice").notice).contains("plugin_dependency_cycle"))
		var refusal: Dictionary = await manager.start_plugin("voice")
		check("manual start cannot bypass a persisted cycle", refusal.get("error_code") == "plugin_dependency_cycle" and manager.get_connection("voice") == null)
		var current := PluginDefinition.from_dict(manifest("agent_relay"))
		current.version = "2.0.0"
		current.args.assign(["-c", "raise SystemExit(1)"])
		check("pending update's current graph is acyclic", loaded.restore(current) and loaded.dependency_issue(current.id).is_empty())
		var transaction: Script = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
		var staging := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
		var pending: RefCounted = transaction.begin(staging)
		check("real pending transaction starts inside isolated user profile", pending != null and staging.begins_with(OS.get_user_data_dir() + "/"))
		if pending != null:
			pending.plugin_id = current.id
			pending.db_before = relay.to_dict()
			pending.had_previous = true
			DirAccess.make_dir_recursive_absolute(str(pending.op_dir).path_join("previous"))
			check("rollback fixture has a previous directory and durable pending phase", pending.publish(transaction.PHASE_PENDING) and transaction.pending_for(staging, current.id) != null)
			var rollback_start: Dictionary = await manager.start_plugin(current.id)
			check("public pending start restores old version but refuses its cyclic graph", str(rollback_start.get("error", "")).contains("plugin_dependency_cycle")
				and loaded.get_by_id(current.id).version == "1.0.0" and not loaded.dependency_issue(current.id).is_empty() and manager.get_connection(current.id) == null)

		manager.free()
		for id: String in ids:
			loaded.remove(id)
		for previous: PluginDefinition in original:
			if previous != null:
				check("fixture restores the previous installed definition", loaded.restore(previous))
	await exercise_readiness()
	print("=== Results: %d passed, %d failed ===" % [checks - failures, failures])
	completed.emit(1 if failures else 0)

func collect_readiness(readiness: PluginReadiness, provider: String, results: Array[Dictionary]) -> void:
	results.append(await readiness.wait_for_provider(provider))

func collect_dispatch(server: MinervaMCPServer, context: MCPExecutionContext, completion: MCPExecutionContext.Completion) -> void:
	completion.finish(await server.call_tool("minerva_agent_relay_echo", {"value": "one dispatch"}, context))

func collect_typed_dispatch(server: MinervaMCPServer, completion: MCPExecutionContext.Completion) -> void:
	completion.finish(await server.call_tool("minerva_agent_relay_typed_input", {"count": "3"}))

func exercise_aliases(server: MinervaMCPServer, manager: PluginManager, registry: PluginToolRegistry) -> void:
	const LEGACY := "minerva_fixture_legacy_echo"
	const CANONICAL := "minerva_agent_relay_echo"
	var internal: Dictionary = await server.call_tool(LEGACY, {"value": "legacy"})
	check("internal alias dispatches canonical backend and labels target", internal.get("alias_of") == CANONICAL and internal.get("echo", {}).get("value") == "legacy")
	await exercise_alias_http_boundary(server, manager)
	var cancelled := MCPExecutionContext.create("fixture")
	cancelled.cancel()
	var stopped: Dictionary = await server.call_tool(LEGACY, {}, cancelled)
	check("cancelled alias retains its label without dispatch", stopped.get("error_code") == "cancelled" and stopped.get("alias_of") == CANONICAL)
	var outcome: MCPToolCallOutcome = await server.execute_tool_for_http_outcome(LEGACY, {"value": "wire"})
	var http := MinervaMCPHttpServer.new()
	for modern: bool in [false, true]:
		var wire := http._public_result_from_outcome(outcome, modern)
		check("alias label survives authoritative HTTP envelope", wire.get("alias_of") == CANONICAL and wire.get("futureField", {}).get("kept") == true
			and wire.get("structuredContent", {}).get("fixture") == "preserved" and outcome.wire_authoritative)
	var native_aliases: Dictionary[String, String] = {LEGACY: "minerva_open_file"}
	var native := MinervaMCPServer.new(null, native_aliases)
	native._modules.append(MCPGeneralTools.new(native))
	var native_outcome: MCPToolCallOutcome = await native.execute_tool_for_http_outcome(LEGACY, {"path": "/missing-alias-fixture.unknown"})
	var native_wire := http._public_result_from_outcome(native_outcome, false)
	check("native HTTP serialization keeps host alias metadata", native_outcome.envelope == null and native_wire.get("alias_of") == "minerva_open_file"
		and JSON.parse_string(native_wire.content[0].text).get("alias_of") == "minerva_open_file" and native_wire.get("isError", false))
	var policy = load("res://test/helpers/hosted_policy_fixture.gd").new()
	var policy_items: Array[Dictionary] = [{"id": "canonical-alias-denial", "title": "Canonical alias denial", "status": "active",
		"description": "---policy-rule---\n" + JSON.stringify({"tool_pattern": CANONICAL, "effect": "block", "priority": 10}) + "\n---end-rule---"}]
	policy.set_policy_items(policy_items)
	server.policy_engine = policy
	var connection := manager.get_connection("agent_relay")
	var before: Dictionary = await connection.call_tool("catalog_count", {}, 5.0)
	var denied: Dictionary = await server.call_tool(LEGACY, {"value": "blocked"})
	var public_denied: MCPToolCallOutcome = await server.execute_tool_for_http_outcome(LEGACY, {"value": "blocked HTTP"})
	var denied_wire := http._public_result_from_outcome(public_denied, false)
	var after: Dictionary = await connection.call_tool("catalog_count", {}, 5.0)
	check("real policy evaluates canonical alias before backend dispatch", policy.rule_count() == 1 and denied.get("allowed") == false
		and denied.get("alias_of") == CANONICAL and after.get("echo_calls") == before.get("echo_calls"))
	check("HTTP alias denial labels canonical policy result", public_denied.application.get("allowed") == false and denied_wire.get("isError", false) and denied_wire.get("alias_of") == CANONICAL)
	server.policy_engine = null
	http.free()
	registry.set_builtin_tool_names(["minerva_plugin_list"])
	var refused := registry.register_plugin_tools("plugin", [{"name": "minerva_plugin_list", "input_schema": {"type": "object"}}])
	check("plugin cannot claim a builtin as an unauthorized alias", str(refused.get("error")).contains("built-in")
		and not registry.is_plugin_tool("minerva_plugin_list") and registry.is_plugin_tool(CANONICAL))

func exercise_alias_http_boundary(server: MinervaMCPServer, manager: PluginManager) -> void:
	var http := MinervaMCPHttpServer.new()
	get_tree().root.add_child(http)
	var catalog = load("res://test/helpers/mcp_public_server_fixture.gd").new()
	catalog.minerva_server = server
	catalog._add_tool("minerva_agent_relay_echo", {"type": "object", "properties": {}})
	http._mcp_manager = catalog
	var enabled_sets: Array = server._enabled_tool_sets.duplicate()
	server._enabled_tool_sets = []
	check("real alias HTTP server starts on an isolated port", http.start_server(0) == OK)
	var client := MCPServerConnection.new("alias-loopback", "http://127.0.0.1:%d" % http.get_port())
	var connected: Error = await client.connect_to_server()
	check("real alias HTTP client discovers the canonical definition: " + client.last_failure_reason, connected == OK)
	if connected == OK:
		var result: MCPToolCallOutcome = await client.call_tool_outcome("minerva_fixture_legacy_echo", {"value": "loopback"})
		check("real HTTP preflight accepts alias and preserves labelled wire", result.application.get("echo", {}).get("value") == "loopback"
			and result.envelope != null and result.envelope.to_mcp_format().get("alias_of") == "minerva_agent_relay_echo")
		var connection := manager.get_connection("agent_relay")
		var before: Dictionary = await connection.call_tool("catalog_count", {}, 5.0)
		var unknown: Dictionary = await client.call_tool("minerva_fixture_unknown", {})
		var missing: Dictionary = await client.call_tool("minerva_fixture_missing_target", {})
		server._enabled_tool_sets = ["not-the-canonical-set"]
		var filtered: Dictionary = await client.call_tool("minerva_fixture_legacy_echo", {})
		var after: Dictionary = await connection.call_tool("catalog_count", {}, 5.0)
		check("HTTP unknown and absent canonical targets refuse before dispatch", str(unknown).contains("Unknown tool") and str(missing).contains("Unknown tool")
			and before.get("echo_calls") == after.get("echo_calls"))
		check("HTTP tool-set filtering uses the canonical definition", str(filtered).contains("not enabled"))
	client.disconnect_from_server()
	server._enabled_tool_sets = enabled_sets
	http.stop_server()
	http.free()


func exercise_readiness() -> void:
	var manager := PluginManager.new()
	get_tree().root.add_child(manager)
	var db: PluginDB = manager.get_db()
	var previous := db.get_by_id("agent_relay")
	var raw := manifest("agent_relay")
	raw.backend.args = [ProjectSettings.globalize_path("res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"), "--profile", "delayed_tools"]
	var provider := PluginDefinition.from_dict(raw)
	var consumer := PluginDefinition.from_dict(manifest("readiness_consumer", "agent_relay"))
	consumer.requires_plugins[0].actions = ["minerva_agent_relay_echo", "minerva_agent_relay_absent"]
	check("readiness fixture owns fresh consumer and persists provider", not db.has_plugin(consumer.id) and db.restore(provider) and db.restore(consumer))
	var registry := PluginToolRegistry.new(manager, null, null)
	manager.configure_dependency_tools(registry)
	var host := get_tree().root.get_node("SingletonObject")
	var old_registry: Variant = host.plugin_tool_registry
	var old_manager: Variant = host.plugin_manager
	host.plugin_tool_registry = registry
	host.plugin_manager = manager
	var aliases: Dictionary[String, String] = {"minerva_fixture_legacy_echo": "minerva_agent_relay_echo", "minerva_fixture_missing_target": "minerva_agent_relay_absent_target"}
	var server := MinervaMCPServer.new(null, aliases)
	server.plugin_admission = host._admit_plugin_tool
	var dispatch := MCPExecutionContext.Completion.new()
	var typed_dispatch := MCPExecutionContext.Completion.new()
	var dispatch_caller := MCPExecutionContext.create("fixture").for_plugin(consumer.id)
	var pending_results: Array[Dictionary] = []
	var seen := {"started": false, "ready": false, "dispatch_started": false}
	manager.plugin_started.connect(func(id: String) -> void:
		seen.started = not manager.get_plugin_status(id).ready
		var profile: String = provider.args[provider.args.find("--profile") + 1]
		var previous_results := pending_results.size()
		if profile in ["delayed_tools", "catalog_exit", "catalog_error"]:
			collect_readiness(PluginReadiness.new(manager, registry), id, pending_results)
		if profile != "delayed_tools":
			return
		var first_dispatch: bool = not seen.dispatch_started
		if first_dispatch:
			seen.dispatch_started = true
			collect_dispatch(server, dispatch_caller, dispatch)
			collect_typed_dispatch(server, typed_dispatch)
		get_tree().create_timer(0.1).timeout.connect(func() -> void:
			if not is_instance_valid(manager) or manager.get_connection(id) == null:
				return
			check("real provider admission stays pending before catalog release", pending_results.size() == previous_results)
			if first_dispatch:
				check("generic MCP dispatch stays pending before catalog release", not dispatch.done and not dispatch_caller.lifetime.dispatched)
				check("typed call has no schema and stays pending", not typed_dispatch.done and registry.find_tool("minerva_agent_relay_typed_input").is_empty())
			check("delayed catalog is running but not ready", manager.get_plugin_status(id).running and not manager.get_plugin_status(id).ready)
			check("fixture releases catalog through public host event", manager.get_connection(id).send_host_event("test_release_tools", {}) == OK)))
	manager.plugin_ready.connect(func(id: String) -> void: seen.ready = manager.get_plugin_status(id).ready)
	var result: Dictionary = await manager.start_plugin(provider.id)
	check("actual start sets ready before the ready event: " + str(result), result.get("ok", false) and seen.started and seen.ready)
	if not result.get("ok", false):
		host.plugin_tool_registry = old_registry
		host.plugin_manager = old_manager
		manager.free()
		return
	check("real delayed discovery completes one event-driven admission", pending_results.size() == 1 and pending_results[0].get("ok", false))
	if not dispatch.done:
		await dispatch.finished
	check("generic MCP dispatch keeps caller identity and reaches backend", dispatch.result.get("echo", {}).get("value") == "one dispatch")
	if not typed_dispatch.done:
		await typed_dispatch.finished
	check("delayed native schema coerces internal arguments", typed_dispatch.result.get("success", false))
	var strict: Dictionary = await server.execute_tool_for_http("minerva_agent_relay_typed_input", {"count": "3"})
	check("HTTP arguments still validate without coercion", strict.get("success") == false)
	var counted: Dictionary = await manager.get_connection(provider.id).call_tool("catalog_count", {}, 5.0)
	check("independent backend counter proves delayed call dispatched once", counted.get("echo_calls") == 1)
	await exercise_aliases(server, manager, registry)
	check("missing action visible without constraining other actions", manager.dependency_contract_issue(consumer.id).contains("tool minerva_agent_relay_absent")
		and manager.dependency_contract_issue(consumer.id, "minerva_agent_relay_echo").is_empty()
		and manager.dependency_contract_issue(consumer.id, "unrelated").is_empty())
	consumer.requires_plugins[0].min_version = "2.0.0"
	var refused: Dictionary = await server.call_tool("minerva_agent_relay_echo", {}, MCPExecutionContext.create("fixture").for_plugin(consumer.id))
	var unconstrained: Dictionary = await server.call_tool("minerva_agent_relay_echo", {"free": true}, MCPExecutionContext.create("fixture").for_plugin("unrelated"))
	check("generic dispatch refuses only the dependent caller", str(refused).contains(">= 2.0.0") and unconstrained.get("echo", {}).get("free") == true)
	var readiness := PluginReadiness.new(manager, registry)
	var caller := MCPExecutionContext.create("fixture").for_plugin(consumer.id)
	var dependent: Dictionary = await readiness.wait_for_tool("minerva_agent_relay_echo", caller)
	var unrelated: Dictionary = await readiness.wait_for_tool("minerva_agent_relay_echo", MCPExecutionContext.create("fixture").for_plugin("other"))
	var other_provider: Dictionary = await readiness.wait_for_tool("minerva_uninstalled_other_probe", caller)
	check("readiness owner applies requirements only to caller and provider", str(dependent).contains(">= 2.0.0") and unrelated.get("ok", false) and other_provider.get("ok", false))
	check("older installed provider refuses consumer contract", manager.dependency_contract_issue(consumer.id).contains(">= 2.0.0"))
	consumer.requires_plugins[0].min_version = "1.0.0"
	provider.tools = [{"name": "minerva_agent_relay_panel", "executor": "panel"}]
	check("required missing panel tool refuses contract", str(await RequiredPlugins.host_tools_missing(provider, manager.get_connection(provider.id), [])).contains("minerva_agent_relay_panel"))
	check("combined panel and backend catalog passes", str(await RequiredPlugins.host_tools_missing(provider, manager.get_connection(provider.id), provider.tools)).is_empty())
	var ordered := PluginDependencyContract.startup_order([consumer, provider])
	check("dependency order overrides consumer-first insertion", ordered.order == [provider.id, consumer.id] and ordered.cycles.is_empty())
	provider.requires_plugins = [{"id": consumer.id}]
	check("cycles remain visibly unresolved in autostart plan", PluginDependencyContract.startup_order([consumer, provider]).cycles.size() == 2)
	provider.requires_plugins.clear()
	var crashed := {"seen": false}
	manager.plugin_crashed.connect(func(_id: String) -> void: crashed.seen = true)
	await manager.get_connection(provider.id).call_tool("exit", {}, 5.0)
	if not crashed.seen:
		await manager.plugin_crashed
	await get_tree().process_frame
	check("natural exit clears readiness", not manager.get_plugin_status(provider.id).ready)
	var missing_panel: Dictionary = await manager.start_plugin(provider.id)
	check("actual start refuses missing required panel tool", str(missing_panel.get("error", "")).contains("minerva_agent_relay_panel"))
	manager.plugin_started.connect(registry.on_plugin_started)
	check("required panel tool registers before any panel opens", (await manager.start_plugin(provider.id)).get("ok", false)
		and manager.get_plugin_status(provider.id).ready and registry.get_panel_tool_entries(provider.id).size() == 1
		and (host.editor_pane == null or host.editor_pane.get_open_editors().is_empty()))
	provider.tools.clear()
	manager.stop_plugin(provider.id)
	var profile_index := provider.args.find("--profile")
	provider.args[profile_index + 1] = "catalog_error"
	var before_catalog_error := pending_results.size()
	var unavailable: Dictionary = await manager.start_plugin(provider.id)
	check("discovery failure leaves process running with a visible reason", unavailable.get("ok", false)
		and manager.get_plugin_status(provider.id).running and not manager.get_plugin_status(provider.id).ready
		and str(manager.get_plugin_status(provider.id).notice).contains("provider tools unavailable: tools/list")
		and str(manager.get_plugin_status(provider.id).notice).contains("Restart the plugin to retry"))
	check("pending admission receives discovery failure without timing out", pending_results.size() == before_catalog_error + 1
		and str(pending_results.back().get("error")).contains("provider tools unavailable: tools/list")
		and str(pending_results.back().get("error")).contains("Restart the plugin to retry"))
	var live_echo: Dictionary = await manager.get_connection(provider.id).call_tool("echo", {"value": "still alive"}, 5.0)
	check("unready provider constrains only declared dependency actions", not manager.dependency_contract_issue(consumer.id, "minerva_agent_relay_echo").is_empty()
		and manager.dependency_contract_issue(consumer.id, "unrelated").is_empty() and live_echo.get("echo", {}).get("value") == "still alive")
	manager.stop_plugin(provider.id)
	provider.args[profile_index + 1] = "catalog_exit"
	var pending_before_crash := pending_results.size()
	var interrupted: Dictionary = await manager.start_plugin(provider.id)
	await get_tree().process_frame
	check("exit DURING discovery preserves crash state before another start", interrupted.has("error")
		and manager.get_plugin_status(provider.id).state == PluginDefinition.State.ERROR and not manager.get_plugin_status(provider.id).ready)
	check("actual crash releases the pending readiness admission", pending_results.size() == pending_before_crash + 1
		and str(pending_results.back().get("error")).contains("provider_crashed"))
	manager.stop_plugin(provider.id)
	provider.args[profile_index + 1] = "empty_tools"
	for tool_name: String in RequiredPlugins.PLUGINS.agent_relay.host_tools:
		provider.tools.append({"name": tool_name, "executor": "panel", "input_schema": {"type": "object"}})
	var empty_catalog: Dictionary = await manager.start_plugin(provider.id)
	check("successful empty backend plus all required panel entries starts ready on FIRST attempt", empty_catalog.get("ok", false)
		and manager.get_connection(provider.id) != null and manager.get_connection(provider.id).tools.is_empty()
		and registry.get_panel_tool_entries(provider.id).size() == RequiredPlugins.PLUGINS.agent_relay.host_tools.size()
		and manager.get_plugin_status(provider.id).running and manager.get_plugin_status(provider.id).ready)
	manager.stop_plugin(provider.id)
	provider.tools.clear()
	provider.args[profile_index + 1] = "single_catalog"
	var single_catalog: Dictionary = await manager.start_plugin(provider.id)
	var single_connection := manager.get_connection(provider.id)
	check("first successful catalog starts ready without a second query", single_catalog.get("ok", false)
		and single_connection != null and manager.get_plugin_status(provider.id).running and manager.get_plugin_status(provider.id).ready)
	if single_connection != null:
		var count: Dictionary = await single_connection.call_tool("catalog_count", {}, 5.0)
		check("independent backend count proves exactly one startup discovery", count.get("catalog_requests") == 1)
		check("anti-case is armed: a subsequent catalog request fails", await single_connection.refresh_tools() != OK)
	manager.stop_plugin(provider.id)
	check("stop clears readiness", not manager.get_plugin_status(provider.id).ready)
	host.plugin_tool_registry = old_registry
	host.plugin_manager = old_manager
	db.remove(consumer.id)
	db.remove(provider.id)
	if previous != null:
		db.restore(previous)
	manager.free()
