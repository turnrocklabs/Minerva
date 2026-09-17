extends SceneTree
## Internal plugins as a CLASS: whatever InternalPlugins.REGISTRY lists is
## host-owned — reconstructed from its trusted res:// source, never persisted,
## never removable, and owning an actionable runtime-repair sentence.
##
## Everything here loops over the registry, so adding a member adds coverage.
## test_builtin_voice_catalog.gd remains the voice-specific regression oracle.

var _passed := 0
var _failed := 0

const FIXTURE_ROOT := "user://internal_runtime_fixture"


func _init() -> void:
	await process_frame
	var DB = load("res://Scripts/Services/Plugins/PluginDB.gd")
	var Definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var ids := InternalPlugins.ids()
	check("registry lists at least voice and agent_relay",
		ids.has("voice") and ids.has("agent_relay"))
	check("registry membership is exact", InternalPlugins.has("voice")
		and InternalPlugins.has("agent_relay") and not InternalPlugins.has("ordinary"))

	# Trusted definitions, captured before any storage is involved. A member
	# unsupported on this platform yields null and is skipped throughout.
	var trusted: Dictionary = {}
	for id in ids:
		var def = InternalPlugins.definition_for(id)
		if def != null:
			trusted[id] = def
	check("every registry member resolves a trusted definition here",
		trusted.size() == ids.size())

	# --- C2: a hostile plugins.json cannot claim a host-owned identity -------
	var hostile_records: Array = []
	for id in ids:
		var hostile = Definition.new()
		hostile.id = id
		hostile.name = "Hostile"
		hostile.entrypoint = "./hostile"
		hostile.data_directory = "/tmp/hostile"
		hostile_records.append(hostile.to_dict())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://plugins"))
	var persisted := FileAccess.open("user://plugins/plugins.json", FileAccess.WRITE)
	persisted.store_string(JSON.stringify({"version": 1, "plugins": hostile_records}))
	persisted.close()

	var db = DB.new()
	var claimed: Array[String] = []
	for id in ids:
		if db.has_plugin(id):
			claimed.append(id)
	check("persisted records cannot claim any host-owned id (C2)", claimed.is_empty())

	var registered: Array[String] = db.register_internal()
	check("register_internal returns every supported member",
		registered.size() == trusted.size())
	var trusted_paths := true
	for id in registered:
		var stored = db.get_by_id(id)
		if stored.entrypoint != trusted[id].entrypoint \
				or stored.data_directory != trusted[id].data_directory:
			trusted_paths = false
	check("registration uses trusted paths, not the file's (C2)", trusted_paths)

	# Preparing reconstructed definitions must not reconstruct user consent.
	var Policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd")
	var prepare_manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	var prepare_policy = Policy.new(db, null, false)
	prepare_policy._grants["voice"] = []  # explicit persisted decision
	prepare_manager._db = db
	prepare_manager._policy_ref = prepare_policy
	var relay_skills: Array[Dictionary] = db.get_by_id("agent_relay").skills
	db.get_by_id("agent_relay").skills = []  # grant behavior is isolated here
	prepare_manager.prepare_internal_plugins()
	db.get_by_id("agent_relay").skills = relay_skills
	check("prepare preserves explicitly revoked internal grants",
		prepare_policy._grants.get("voice", []) == [])
	check("first prepare still grants a new internal member's declarations",
		prepare_policy._grants.has("agent_relay")
			and not prepare_policy._grants["agent_relay"].is_empty())
	prepare_manager.free()

	# --- C1: registered in the catalog, absent from persistent storage ------
	var in_catalog := true
	for id in registered:
		if not db.has_plugin(id):
			in_catalog = false
	check("every member is in get_all() (C1)",
		in_catalog and db.get_all().size() >= registered.size())

	var ordinary = Definition.new()
	ordinary.id = "ordinary"
	ordinary.name = "Ordinary"
	ordinary.entrypoint = "./ordinary"
	db._plugins[ordinary.id] = ordinary
	db._save()
	var saved_text := FileAccess.get_file_as_string("user://plugins/plugins.json")
	var saved_ids: Array = []
	for record in (JSON.parse_string(saved_text) as Dictionary).get("plugins", []):
		saved_ids.append(str(record.get("id", "")))
	var leaked: Array[String] = []
	for id in registered:
		if saved_ids.has(id):
			leaked.append(id)
	check("no member reaches plugins.json after a save (C1)", leaked.is_empty())
	check("an ordinary plugin still persists (C1 control)", saved_ids.has("ordinary"))

	# --- C3: every mutation path refuses a member and accepts a non-member --
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = db
	var mutations_refused := true
	for id in registered:
		var before = db.get_by_id(id)
		var hostile = Definition.new()
		hostile.id = id
		hostile.entrypoint = "./hostile"
		var removal: Dictionary = manager.remove_plugin(id)
		if not removal.has("error") \
				or db.remove(id) \
				or db.update_definition(hostile) \
				or db.set_autostart(id, true) \
				or db.set_auto_reload(id, true) \
				or manager.set_auto_reload(id, true) \
				or db.get_by_id(id) != before:
			mutations_refused = false
	check("every member refuses remove/update/lifecycle flags (C3)", mutations_refused)
	check("a non-member accepts the same calls (C3 control)",
		db.set_autostart("ordinary", true) and db.set_auto_reload("ordinary", true)
			and db.remove("ordinary"))

	# --- A1/A3: agent-relay identity and tool surface -----------------------
	if trusted.has("agent_relay"):
		var relay = db.get_by_id("agent_relay")
		var AgentRelay = load("res://Scripts/Services/Plugins/InternalAgentRelayPlugin.gd")
		check("agent_relay entrypoint resolves to the staged worker (A1)",
			relay.entrypoint == "./%s" % AgentRelay.binary_name()
				and relay.data_directory == AgentRelay.runtime_directory()
				and relay.working_dir == relay.data_directory)
		check("agent_relay state is routed to persistent writable user data",
			relay.args.size() == 2 and relay.args[0] == "--state-file"
				and str(relay.args[1]).contains("plugins/data/agent_relay")
				and not str(relay.args[1]).begins_with(relay.data_directory))
		check("agent_relay is absent from plugins.json (A1)", not saved_ids.has("agent_relay"))
		var tool_names: Array[String] = []
		for entry in relay.tools:
			tool_names.append(str(entry.get("name", "")))
		check("agent_relay keeps its 15 namespaced tool names (A2)",
			tool_names.size() == 15
				and tool_names.has("minerva_agent_relay_watch_start")
				and tool_names.has("minerva_agent_relay_relay_ask"))
		var skill_ids: Array[String] = []
		for skill in relay.skills:
			skill_ids.append(str(skill.get("id", "")))
		check("agent_relay still ships the relay skill",
			skill_ids == ["minerva_agent_relay_relay"])
		check("plugin_remove refuses agent_relay by name (A3)",
			manager.remove_plugin("agent_relay").get("error", "").contains("agent_relay"))

	# --- C7: a damaged runtime names the missing file and the repair --------
	var target := InternalPlugins.target_triple()
	_remove_tree(ProjectSettings.globalize_path(FIXTURE_ROOT))
	var damage_reported := true
	var complete_accepted := true
	for id in registered:
		var stage := ProjectSettings.globalize_path(FIXTURE_ROOT).path_join(id)
		var required: Array = InternalPlugins.required_runtime_files(id)
		var repair := InternalPlugins.repair_hint(id)
		for omitted in required:
			_build_stage(stage, required, target, omitted)
			var issue := InternalPlugins.runtime_issue_at(id, stage, target)
			if not (issue.contains(str(omitted).get_file()) and issue.contains(repair)):
				damage_reported = false
		_build_stage(stage, required, target, "")
		if not InternalPlugins.runtime_issue_at(id, stage, target).is_empty():
			complete_accepted = false
	check("a member missing any required file names it and the repair (C7)", damage_reported)
	check("a complete stage passes the cheap guard (C7 control)", complete_accepted)
	_remove_tree(ProjectSettings.globalize_path(FIXTURE_ROOT))

	# start_plugin surfaces the member's own sentence verbatim. Vacuous on a
	# host whose runtimes are fully staged; the fixture loop above is what
	# proves the sentence itself.
	var start_matches := true
	for id in registered:
		var issue := InternalPlugins.runtime_issue(id)
		if issue.is_empty():
			continue
		var result: Dictionary = await manager.start_plugin(id)
		if result.get("error", "") != issue:
			start_matches = false
	check("start_plugin returns the member's runtime issue verbatim (C7)", start_matches)

	manager.free()
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)


## Write a complete stage under `stage`, skipping `omitted` when non-empty.
func _build_stage(stage: String, required: Array, target: String, omitted: String) -> void:
	_remove_tree(stage)
	for relative in required:
		if str(relative) == omitted:
			continue
		var path := stage.path_join(str(relative))
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("%s\n" % target if str(relative) == "target-triple.txt" else "fixture\n")
		file.close()


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
