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
	var disabled_start: Dictionary = await manager.start_plugin("voice")
	check("manager refuses external start while Voice Support is disabled", disabled_start.has("error") and db.get_by_id("voice").state == 0)
	var old_connection := RefCounted.new()
	var replacement_connection := RefCounted.new()
	manager._runtime["voice"] = {"connection": replacement_connection, "stopping": false}
	check("late start completion cannot own a replacement runtime", not manager._owns_runtime_connection("voice", old_connection) and manager._owns_runtime_connection("voice", replacement_connection))
	VoiceFeature.set_enabled(true)
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
