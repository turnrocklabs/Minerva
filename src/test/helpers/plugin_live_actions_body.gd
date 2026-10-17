extends Node
signal completed(code: int)
const ID := "live_actions_contract"
var checks: int = 0
var failed: int = 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(3.0).timeout
	get_tree().create_timer(45.0).timeout.connect(func() -> void: completed.emit(1))
	var singleton: Node = get_tree().root.get_node("SingletonObject")
	var previous_manager: Variant = singleton.plugin_manager
	var previous_broker: Variant = singleton.plugin_scene_panel_broker
	var manager := PluginManager.new()
	manager._db = PluginDB.new()
	var policy := PluginPolicy.new(manager.get_db(), null, false)
	var broker := PluginScenePanelBroker.new(manager, policy, CapabilityBroker.new(policy))
	singleton.plugin_manager = manager
	singleton.plugin_scene_panel_broker = broker
	add_child(manager)
	manager.set_process(false)
	var fixture_script: Script = load("res://test/helpers/plugin_live_reload_test_body.gd")
	var fixture: Node = fixture_script.new()
	fixture.call("_fixture", ID, 1)
	var manifest_path := "user://plugins/" + ID + "/manifest.json"
	check(manager.get_db().install(manifest_path) != null, "real fixture installs")
	var tools_script: Script = load("res://Scripts/Services/Plugins/PluginMCPTools.gd")
	var tools: RefCounted = tools_script.new(manager)
	var missing: Dictionary = await tools.handle_tool_call("minerva_plugin_revert", {"id": ID})
	check(not missing.get("success", true) and str(missing.error).contains("No retained"), "MCP no-LKG refusal is explicit")
	var definitions: Array = tools.get_tool_definitions()
	check(definitions.filter(func(entry: Dictionary) -> bool: return entry.name == "minerva_plugin_revert").size() == 1, "MCP revert verb registered exactly once")
	var editor := Editor.create_plugin_scene(ID, "main")
	add_child(editor)
	await get_tree().process_frame
	editor.plugin_scene_root.document = {"newer edits": "keep", "undo": [9, 8], "view": 7, "large": 9007199254740993}
	var expected: PackedByteArray = var_to_bytes(editor.plugin_scene_root.document)
	var data_path := "user://actions-current-user-data.txt"
	var file := FileAccess.open(data_path, FileAccess.WRITE)
	file.store_string("newer data must survive every revert")
	file.close()
	fixture.call("_fixture", ID, 2)
	var loaded: Dictionary = await tools.handle_tool_call("minerva_plugin_reload", {"id": ID})
	check(loaded.get("success", false) and editor.plugin_scene_root.VERSION == 2, "MCP reload uses the production scene swap")
	var store := PluginGenerationStore.new(ID)
	var selected_before := FileAccess.get_file_as_bytes(store.selector_path())
	var root_before := editor.plugin_scene_root.get_instance_id()
	for repeat: int in 2:
		var unchanged: Dictionary = await tools.handle_tool_call("minerva_plugin_reload", {"id": ID})
		check(unchanged.get("success", false) and FileAccess.get_file_as_bytes(store.selector_path()) == selected_before
			and editor.plugin_scene_root.get_instance_id() == root_before, "unchanged Reload preserves distinct LKG, selector and root")
	var panel: Control = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	panel._pm_override = manager
	add_child(panel)
	panel._selected_plugin_id = ID
	panel._populate_detail_panel(ID)
	var button: Button = panel._revert_button
	check(button.visible and button.text == "Revert to previous version", "one-click revert is available for opt-in plugin")
	button.pressed.emit()
	for frame: int in 5:
		await get_tree().process_frame
	check(editor.plugin_scene_root.VERSION == 1 and str(panel._status_label.text).contains("Previous scene"), "real UI click restores previous marker and shows selectable status")
	check(var_to_bytes(editor.plugin_scene_root.document) == expected and FileAccess.get_file_as_string(data_path) == "newer data must survive every revert", "UI revert preserves exact transient state and current user file")
	var reverted: Dictionary = await tools.handle_tool_call("minerva_plugin_revert", {"id": ID})
	check(reverted.get("success", false) and editor.plugin_scene_root.VERSION == 2, "MCP revert shares the same retained-build swap")
	# Marketplace installation retains the selected scene until restart.
	fixture.call("_fixture", ID, 3)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var added_panel: Dictionary = manifest.ui.panels[0].duplicate(true)
	added_panel.name = "new_panel"
	manifest.ui.panels.append(added_panel)
	var manifest_file := FileAccess.open(manifest_path, FileAccess.WRITE)
	manifest_file.store_string(JSON.stringify(manifest))
	manifest_file.close()
	var definition := PluginDefinition.from_manifest(manifest_path, PluginDefinition.LANE_MARKETPLACE)
	check(manager.get_db().update_definition(definition), "commit installed marketplace definition")
	var pending: Dictionary = manager.installed_scene_update(ID)
	check(pending.get("ok", false) and pending.restart_pending and editor.plugin_scene_root.VERSION == 2,
		"installed update retains selected scene and marks restart-pending")
	check(not manager.resolve_scene_generation(ID, "new_panel").get("ok", true)
		and manager.get_plugin_status(ID).live_reload.restart_pending, "new panel absent from retained build cannot clear restart boundary")
	var refused: Dictionary = await tools.handle_tool_call("minerva_plugin_reload", {"id": ID})
	check(not refused.get("success", true) and editor.plugin_scene_root.VERSION == 2, "MCP cannot bypass marketplace restart boundary")
	var refused_revert: Dictionary = await tools.handle_tool_call("minerva_plugin_revert", {"id": ID})
	check(not refused_revert.get("success", true) and refused.message == refused_revert.message, "MCP reload and revert share restart refusal and status")
	panel._populate_detail_panel(ID)
	check(panel._reload_button.disabled and panel._revert_button.disabled
		and panel._reload_button.tooltip_text == "Restart Minerva to load the installed update"
		and panel._revert_button.tooltip_text == panel._reload_button.tooltip_text, "restart-pending prevents in-session scene activation")
	check(var_to_bytes(editor.plugin_scene_root.document) == expected and FileAccess.get_file_as_string(data_path) == "newer data must survive every revert", "installed update keeps newer user data")
	editor.free()
	var boot_script: Script = load("res://Scripts/Services/Plugins/PluginLiveReload.gd")
	var boot: Node = boot_script.new()
	boot.configure(manager, broker, Callable())
	add_child(boot)
	var resolved: Dictionary = boot.resolve(ID, "main")
	var packed: PackedScene = load(str(resolved.directory).path_join("Panel.tscn"))
	var selected: Control = packed.instantiate()
	check(resolved.get("ok", false) and selected.VERSION == 3, "next boot validates NEW installed scene after restart boundary")
	selected.free()
	boot.free()
	panel.free()
	fixture.free()
	manager.get_db().remove(ID)
	singleton.plugin_manager = previous_manager
	singleton.plugin_scene_panel_broker = previous_broker
	manager.free()
	print("Live actions: %d checks, %d failures" % [checks, failed])
	completed.emit(1 if failed else 0)


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failed += 1
	print(("PASS: " if condition else "FAIL: ") + label)
