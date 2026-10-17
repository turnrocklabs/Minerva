extends Node
signal completed(code: int)
const ID := "production_crash_contract"
const DATA := "user://production-crash-data.bin"
var mode: String = ""
var nonce: String = ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[args.find("--crash-mode") + 1]
	nonce = args[args.find("--nonce") + 1]
	await get_tree().create_timer(3.0).timeout
	if mode == "baseline":
		print("CRASH_BASELINE_DONE")
		completed.emit(0)
		return
	get_tree().create_timer(40.0).timeout.connect(func() -> void: completed.emit(1))
	var fixture_script: Script = load("res://test/helpers/plugin_live_reload_test_body.gd")
	var fixture: Node = fixture_script.new()
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
	if mode == "seed":
		fixture.call("_fixture", ID, 1)
		if manager.get_db().install("user://plugins/" + ID + "/manifest.json") == null:
			completed.emit(1)
			return
		var data := FileAccess.open(DATA, FileAccess.WRITE)
		data.store_buffer(nonce.hex_decode())
		data.close()
	var editor := Editor.create_plugin_scene(ID, "main")
	add_child(editor)
	await get_tree().process_frame
	var panel: Control = editor.plugin_scene_root
	if not panel.get_meta("_minerva_plugin_panel_load_ok", false):
		completed.emit(1)
		return
	panel.document = {"unsaved": nonce, "large": 9007199254740993, "undo": [1, 2, 3]}
	if mode == "loop":
		Engine.max_fps = 10
		for version: int in range(2, 100):
			fixture.call("_fixture", ID, version)
			var path := "user://plugins/" + ID + "/Panel.gd"
			var source := FileAccess.get_file_as_string(path).replace("document = state.duplicate(true)",
				'document = state.duplicate(true)\n\tprint("CRASH_READY:' + nonce + '")')
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string(source)
			file.close()
			var result: Dictionary = await manager.reload_scene_plugin(ID)
			if not result.get("ok", false):
				print("CRASH_LOOP_REFUSED:" + JSON.stringify(result))
				completed.emit(1)
				return
			print("CRASH_SWAP_DONE:" + nonce)
		completed.emit(1) # The driver must kill an in-flight swap first.
		return
	var store := PluginGenerationStore.new(ID)
	var selected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(store.selector_path()))
	var build := store.read_archive(str(selected.get("active", "")))
	var version: int = panel.VERSION
	var valid: bool = build.get("ok", false) and panel.operation(10) == 10 + version \
		and panel.get_node("Marker").text == str(version) \
		and FileAccess.get_file_as_bytes(DATA).hex_encode() == nonce
	print("CRASH_RECEIPT:" + JSON.stringify({"ok": valid, "mode": mode, "nonce": nonce,
		"selected": selected, "version": version, "data_hex": FileAccess.get_file_as_bytes(DATA).hex_encode(),
		"release": OS.has_feature("release"), "debug": OS.has_feature("debug"), "editor": OS.has_feature("editor")}))
	fixture.free()
	editor.free()
	singleton.plugin_manager = previous_manager
	singleton.plugin_scene_panel_broker = previous_broker
	manager.free()
	completed.emit(0 if valid else 1)
