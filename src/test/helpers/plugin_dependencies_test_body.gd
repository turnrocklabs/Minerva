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
	host.plugin_tool_registry = registry
	var pending_results: Array[Dictionary] = []
	var seen := {"started": false, "ready": false}
	manager.plugin_started.connect(func(id: String) -> void:
		seen.started = not manager.get_plugin_status(id).ready
		var profile: String = provider.args[provider.args.find("--profile") + 1]
		var previous_results := pending_results.size()
		if profile in ["delayed_tools", "catalog_exit", "catalog_error"]:
			collect_readiness(PluginReadiness.new(manager, registry), id, pending_results)
		if profile != "delayed_tools":
			return
		get_tree().create_timer(0.1).timeout.connect(func() -> void:
			if not is_instance_valid(manager) or manager.get_connection(id) == null:
				return
			check("real provider admission stays pending before catalog release", pending_results.size() == previous_results)
			check("delayed catalog is running but not ready", manager.get_plugin_status(id).running and not manager.get_plugin_status(id).ready)
			check("fixture releases catalog through public host event", manager.get_connection(id).send_host_event("test_release_tools", {}) == OK)))
	manager.plugin_ready.connect(func(id: String) -> void: seen.ready = manager.get_plugin_status(id).ready)
	var result: Dictionary = await manager.start_plugin(provider.id)
	check("actual start sets ready before the ready event: " + str(result), result.get("ok", false) and seen.started and seen.ready)
	if not result.get("ok", false):
		host.plugin_tool_registry = old_registry
		manager.free()
		return
	check("real delayed discovery completes one event-driven admission", pending_results.size() == 1 and pending_results[0].get("ok", false))
	check("missing action visible without constraining other actions", manager.dependency_contract_issue(consumer.id).contains("tool minerva_agent_relay_absent")
		and manager.dependency_contract_issue(consumer.id, "minerva_agent_relay_echo").is_empty()
		and manager.dependency_contract_issue(consumer.id, "unrelated").is_empty())
	consumer.requires_plugins[0].min_version = "2.0.0"
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
	db.remove(consumer.id)
	db.remove(provider.id)
	if previous != null:
		db.restore(previous)
	manager.free()
