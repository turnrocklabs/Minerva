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
		manager._db = loaded
		var refusal: Dictionary = await manager.start_plugin("voice")
		check("manual start cannot bypass a persisted cycle", refusal.get("error_code") == "plugin_dependency_cycle" and manager.get_connection("voice") == null)
		manager.free()
		for id: String in ids:
			loaded.remove(id)
		for previous: PluginDefinition in original:
			if previous != null:
				check("fixture restores the previous installed definition", loaded.restore(previous))
	print("=== Results: %d passed, %d failed ===" % [checks - failures, failures])
	completed.emit(1 if failures else 0)
