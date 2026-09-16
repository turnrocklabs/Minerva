extends SceneTree
## Host-owned Voice Support identity cannot be replaced through plugin storage.

var _passed := 0
var _failed := 0


func _init() -> void:
	await process_frame
	var DB = load("res://Scripts/Services/Plugins/PluginDB.gd")
	var Builtin = load("res://Scripts/Services/Voice/BuiltinVoicePlugin.gd")
	var Definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var trusted = Builtin.definition()
	check("current platform has the Voice Support definition", trusted != null and trusted.id == "voice" and trusted.name == "Voice Support")
	var runtime_fixture := ProjectSettings.globalize_path("user://builtin_voice_runtime_fixture")
	if DirAccess.dir_exists_absolute(runtime_fixture):
		_remove_tree(runtime_fixture)
	var repair := "Run scripts/build-extensions.sh --voice-only"
	var missing_issue: String = Builtin.runtime_issue_for(
		runtime_fixture, "linux-x86_64", repair, false)
	check("missing built-in runtime names the Voice-only repair command",
		missing_issue.contains("missing") and missing_issue.contains("--voice-only"))
	for relative in [
		"manifest.sha256", "input-artifacts.sha256", "source-inputs.sha256",
		"target-triple.txt", "bin/python3",
	]:
		var path := runtime_fixture.path_join(relative)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("linux-x86_64\n" if relative == "target-triple.txt" else "fixture\n")
		file.close()
	check("complete built-in runtime passes the cheap UI guard",
		Builtin.runtime_issue_for(runtime_fixture, "linux-x86_64", repair, false).is_empty())
	var wrong_arch: String = Builtin.runtime_issue_for(
		runtime_fixture, "macos-arm64", repair, false)
	check("wrong built-in runtime target is actionable",
		wrong_arch.contains("linux-x86_64") and wrong_arch.contains("macos-arm64")
			and wrong_arch.contains("--voice-only"))
	_remove_tree(runtime_fixture)
	var hostile = Definition.new()
	hostile.id = "voice"
	hostile.entrypoint = "./hostile"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://plugins"))
	var persisted := FileAccess.open("user://plugins/plugins.json", FileAccess.WRITE)
	persisted.store_string(JSON.stringify({"version": 1, "plugins": [hostile.to_dict()]}))
	persisted.close()
	var db = DB.new()
	check("persisted manifest cannot claim host-owned voice", not db.has_plugin("voice"))
	check("trusted voice registration succeeds", db.register_builtin() and db.get_by_id("voice").data_directory == trusted.data_directory)
	check("caller definition cannot replace trusted voice path", db.register_builtin(hostile) and db.get_by_id("voice").entrypoint == trusted.entrypoint and db.get_by_id("voice").data_directory == trusted.data_directory)
	var registered_voice = db.get_by_id("voice")
	check("database refuses replacement of host-owned voice", not db.update_definition(hostile) and db.get_by_id("voice") == registered_voice)
	check("database refuses removal of host-owned voice", not db.remove("voice") and db.has_plugin("voice"))
	check("database refuses lifecycle flags for host-owned voice", not db.set_autostart("voice", true) and not db.set_auto_reload("voice", true))
	var ordinary = Definition.new()
	ordinary.id = "ordinary"
	db._plugins[ordinary.id] = ordinary
	check("ordinary plugin lifecycle remains mutable", db.set_autostart("ordinary", true) and db.set_auto_reload("ordinary", true) and db.remove("ordinary"))
	var VoiceFeature = load("res://Scripts/Services/Voice/VoiceFeatureControl.gd")
	VoiceFeature.set_enabled(false)
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = db
	var panel = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	panel._pm_override = manager
	root.add_child(panel)
	await process_frame
	_select_plugin(panel, "voice")
	check("built-in Voice hides Remove/Reload/Auto controls",
		not panel._remove_button.visible
			and not panel._reload_button.visible
			and not panel._autostart_check.visible
			and not panel._auto_reload_check.visible)
	var plugin_tools = load(
		"res://Scripts/Services/Plugins/PluginMCPTools.gd").new(manager, null, null, null)
	var voice_status: Dictionary = await plugin_tools.handle_tool_call(
		"minerva_plugin_build_status", {"id": "voice"})
	check("built-in Voice is never advertised as rebuildable",
		voice_status.get("rebuildable", true) == false)
	var disabled_start: Dictionary = await manager.start_plugin("voice")
	check("manager refuses external start while Voice Support is disabled", disabled_start.has("error") and db.get_by_id("voice").state == 0)
	var old_connection := RefCounted.new()
	var replacement_connection := RefCounted.new()
	manager._runtime["voice"] = {"connection": replacement_connection, "stopping": false}
	check("late start completion cannot own a replacement runtime", not manager._owns_runtime_connection("voice", old_connection) and manager._owns_runtime_connection("voice", replacement_connection))
	VoiceFeature.set_enabled(true)
	root.remove_child(panel)
	panel.free()
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


func _select_plugin(panel, plugin_id: String) -> void:
	var list: ItemList = panel._plugin_list
	for index in list.item_count:
		if str(list.get_item_metadata(index)) == plugin_id:
			list.select(index)
			panel._on_plugin_selected(index)
			return


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
