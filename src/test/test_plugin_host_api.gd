extends SceneTree
## One incompatible package through real install, visible diagnostics and start.
const DIRECTORY := "user://host_api_contract"
const PLUGIN_ID := "host_api_contract"
const EXPECTED := "Plugin 'host_api_contract' v1.0.0 was built for Minerva host API 0; this Minerva provides host API 1. Update it from the Marketplace, or reinstall from a manifest built for API 1."
var passed: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	create_timer(20.0).timeout.connect(func() -> void: quit(1))
	DirAccess.make_dir_recursive_absolute(DIRECTORY)
	var manifest := DIRECTORY.path_join("manifest.json")
	var file := FileAccess.open(manifest, FileAccess.WRITE)
	file.store_string(JSON.stringify({"id": PLUGIN_ID, "name": "API contract", "version": "1.0.0",
		"host_api_version": "0", "backend": {"transport": "stdio", "entrypoint": "python3"}}))
	file.close()
	# Runtime load preserves the real manager's autoload dependency context.
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = PluginDB.new()
	var installed: Dictionary = await manager.install_plugin(manifest, true)
	check(installed.get("error") == EXPECTED and not manager.get_db().has_plugin(PLUGIN_ID),
		"incompatible install returns the exact actionable message without registering")
	var tools = load("res://Scripts/Services/Plugins/PluginMCPTools.gd").new(manager)
	var wire: Dictionary = await tools.handle_tool_call("minerva_plugin_install", {"manifest_path": manifest})
	check(wire.get("error") == EXPECTED, "minerva_plugin_install preserves the exact message")
	var panel = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	panel._pm_override = manager
	root.add_child(panel)
	await panel._on_manifest_selected(manifest)
	var status: TextEdit = panel._status_label
	status.select_all()
	check(not status.editable and status.get_selected_text() == "Install failed: " + EXPECTED,
		"the complete install error is visible and selectable in the real status TextEdit")
	# Loading saved API-0 records is deliberately allowed; only execution is gated.
	var saved: PluginDefinition = manager.get_db().install(manifest)
	check(saved != null, "an existing incompatible record remains loadable")
	manager._db = PluginDB.new()
	check(manager.get_db().has_plugin(PLUGIN_ID), "PluginDB retains incompatible records on reload")
	var updated: Dictionary = await manager.update_plugin(manifest, true)
	check(updated.get("error") == EXPECTED, "update uses the same compatibility refusal")
	var started: Dictionary = await manager.start_plugin(PLUGIN_ID)
	var snapshot: Dictionary = manager.get_plugin_status(PLUGIN_ID)
	check(started.get("error") == EXPECTED and snapshot.state == manager.S_ERROR
		and snapshot.notice == EXPECTED and not snapshot.running,
		"start refuses before launch with ERROR state and the exact visible notice")
	var singleton = root.get_node("SingletonObject")
	var previous = singleton.plugin_manager
	singleton.plugin_manager = manager
	var mount := VBoxContainer.new()
	root.add_child(mount)
	var scene_host = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
	var placeholder: Control = scene_host.instantiate_into(mount, PLUGIN_ID, "unused", null)
	var visible := false
	for label: Label in placeholder.find_children("*", "Label", true, false):
		visible = visible or label.text == EXPECTED
	check(visible, "opening a panel without start also displays the same refusal")
	singleton.plugin_manager = previous
	mount.free()
	var compatible: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest))
	compatible["host_api_version"] = "1"
	compatible["version"] = "1.0.1"
	file = FileAccess.open(manifest, FileAccess.WRITE)
	file.store_string(JSON.stringify(compatible))
	file.close()
	var repaired: Dictionary = await manager.update_plugin(manifest, true)
	check(not repaired.has("error") and manager.get_plugin_status(PLUGIN_ID).notice.is_empty(),
		"a compatible update retires its old compatibility diagnostic")
	panel.free()
	manager.get_db().remove(PLUGIN_ID)
	manager.free()
	DirAccess.remove_absolute(manifest)
	DirAccess.remove_absolute(DIRECTORY)
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)
