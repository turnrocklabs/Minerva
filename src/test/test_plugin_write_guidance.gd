extends SceneTree
## One manifest through the real Editor factory into its operation profile.
const DIRECTORY := "user://write_guidance_contract"
const PLUGIN_ID := "write_guidance_contract"
const GUIDANCE := "Read the current source and replace the complete structured document."
var passed: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	create_timer(20.0).timeout.connect(func() -> void: quit(1))
	DirAccess.make_dir_recursive_absolute(DIRECTORY)
	var script_file := FileAccess.open(DIRECTORY.path_join("Guide.gd"), FileAccess.WRITE)
	script_file.store_string("extends MinervaPluginPanel\n")
	script_file.close()
	var scene := FileAccess.open(DIRECTORY.path_join("Guide.tscn"), FileAccess.WRITE)
	scene.store_string('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Guide.gd" id="1"]\n[node name="Guide" type="Control"]\nscript = ExtResource("1")\n')
	scene.close()
	var manifest := DIRECTORY.path_join("manifest.json")
	var file := FileAccess.open(manifest, FileAccess.WRITE)
	file.store_string(JSON.stringify({"id": PLUGIN_ID, "name": "Guidance contract", "version": "1.0.0",
		"backend": {"transport": "stdio", "entrypoint": "python3"}, "ui": {"panels": [{
			"name": "guide", "kind": "godot_scene", "entry_scene": "Guide.tscn",
			"scripts": ["Guide.gd"], "write_guidance": GUIDANCE}]}}))
	file.close()
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = PluginDB.new()
	var definition: PluginDefinition = manager.get_db().install(manifest)
	check(definition != null and definition.ui_panels[0].write_guidance == GUIDANCE,
		"typed manifest preserves the panel guidance")
	var singleton = root.get_node("SingletonObject")
	var previous_manager = singleton.plugin_manager
	var previous_broker = singleton.plugin_scene_panel_broker
	singleton.plugin_manager = manager
	singleton.plugin_scene_panel_broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new()
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	var editor = editor_script.create_plugin_scene(PLUGIN_ID, "guide", null, "Guidance")
	var identity = load("res://Scripts/Services/Documents/DocumentIdentity.gd")
	var profile: Dictionary = identity.operation_profile(editor)
	check(editor.plugin_write_guidance == GUIDANCE and profile.get("write_guidance") == GUIDANCE
		and not profile.supported_operations.has("minerva_doc_edit"),
		"real Editor factory carries manifest guidance into the structured operation profile")
	editor.free()
	singleton.plugin_manager = previous_manager
	singleton.plugin_scene_panel_broker = previous_broker
	manager.get_db().remove(PLUGIN_ID)
	manager.free()
	for name: String in ["manifest.json", "Guide.tscn", "Guide.gd"]:
		DirAccess.remove_absolute(DIRECTORY.path_join(name))
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
