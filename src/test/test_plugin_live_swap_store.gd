extends SceneTree
## Storage public contracts on real files; no production profile is used.

const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
var _failures: int = 0
var _checks: int = 0
var _test_root: String


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, passed: bool) -> void:
	_checks += 1
	if not passed:
		_failures += 1
		printerr("FAIL: " + label)
	else:
		print("PASS: " + label)


func build(store: RefCounted, version: int) -> Dictionary:
	return store.bundle({
		"Panel.gd": ("extends Control\nconst VERSION := %d\n" % version).to_utf8_buffer(),
		"Panel.tscn": '[gd_scene load_steps=2 format=3 uid="uid://fixture"]\n[ext_resource type="Script" path="Panel.gd" uid="uid://script" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n'.to_utf8_buffer(),
		"Panel.gd.uid": "uid://fixture".to_utf8_buffer(),
		"asset.bin": PackedByteArray([0, 255, 128]),
	})


func _run() -> void:
	await process_frame
	_test_root = "user://generation-store-contract-" + str(Time.get_ticks_usec())
	var store := Store.new("fixture", _test_root)
	var v1 := build(store, 1)
	var v2 := build(store, 2)
	check("content determines generation digest", v1.ok and v1.digest != v2.digest)
	check("UID sidecars omitted", not v1.files.has("Panel.gd.uid"))
	check("resource UIDs stripped", not v1.files["Panel.tscn"].get_string_from_utf8().contains("uid://"))
	check("binary bytes remain exact", v1.files["asset.bin"] == PackedByteArray([0, 255, 128]))
	check("archive v1", store.archive(v1).ok)
	check("archive v2", store.archive(v2).ok)
	check("archive read preserves bytes", store.read_archive(v1.digest).files == v1.files)
	check("initial selector prepared", store.prepare_selector(v1.digest, {}).ok)
	check("prepare does not publish selector", not FileAccess.file_exists(store.selector_path()))
	check("initial publish", store.publish_selector().ok)
	var valid := func(_candidate: Dictionary) -> Dictionary: return {"ok": true}
	var recovered := store.recover(valid)
	check("boot validates active", recovered.ok and recovered.digest == v1.digest)
	var next := store.prepare_selector(v2.digest, recovered.record)
	check("next selector prepared", next.ok)
	check("leftover temp cannot publish uncommitted candidate", store.recover(valid).digest == v1.digest)
	check("publish next build", store.publish_selector().ok)
	recovered = store.recover(valid)
	check("published build has previous LKG", recovered.digest == v2.digest and recovered.record.lkg == v1.digest)
	var reject_v2 := func(candidate: Dictionary) -> Dictionary: return {"ok": candidate.digest != v2.digest}
	var fallback := store.recover(reject_v2)
	check("active compile/load validation failure falls back", fallback.ok and fallback.recovered and fallback.digest == v1.digest)
	var reject_all := func(_candidate: Dictionary) -> Dictionary: return {"ok": false}
	check("both invalid refuse visibly", not store.recover(reject_all).ok and not store.error_message().is_empty())
	# Real selector absence, using a move rather than deleting files.
	check("move selector away", DirAccess.rename_absolute(store.selector_path(), store.selector_path() + ".saved") == OK)
	check("missing selector recovers published predecessor", store.recover(valid).digest == v1.digest)
	check("restore selector", DirAccess.rename_absolute(store.selector_path() + ".saved", store.selector_path()) == OK)
	var archive_path := store.directory.path_join(v2.digest + ".json")
	check("corrupt active archive on disk", Atomic.write(archive_path, "{}"))
	check("corrupt active archive falls back", store.recover(valid).digest == v1.digest)
	check("corrupt immutable archive refused rather than overwritten", not store.archive(v2).ok)
	check("archive traversal refused", not store.read_archive("../escape").ok)
	check("unsafe plugin id refused", Store.new("../other", _test_root).directory.is_empty())
	check("relative traversal refused", not store.bundle({"../escape.gd": PackedByteArray()}).ok)
	check("cross-plugin preload refused", not store.normalize_resource("Panel.gd", 'extends Control\nconst X = preload("user://plugins/other/X.gd")').ok)
	check("unlisted host preload refused", not store.normalize_resource("Panel.gd", 'extends Control\nconst X = preload("res://Scripts/Services/Plugins/PluginManager.gd")').ok)
	for path: String in Store.HOST_PATHS:
		check("public host API exists: " + path, FileAccess.file_exists(path))
		check("public host preload allowed: " + path, store.normalize_resource("Panel.gd", 'extends Control\nconst X = preload("%s")' % path).ok)
	check("relative dependency allowed", store.normalize_resource("Panel.gd", 'extends Control\nconst X = preload("lib/X.gd")').ok)
	check("UID-only dependency refused", not store.normalize_resource("Panel.tscn", '[ext_resource type="Script" path="uid://fixture" id="1"]').ok)
	check("slot write", store.write_slot("A", v1).ok)
	check("slot asset bytes", FileAccess.get_file_as_bytes(store.slot_path("A").path_join("asset.bin")) == v1.files["asset.bin"])
	check("invalid slot refused", not store.write_slot("../escape", v1).ok)
	# An actual filesystem error: a directory cannot be replaced by a file.
	var blocked := store.directory.path_join("blocked")
	DirAccess.make_dir_recursive_absolute(blocked)
	check("actual selector replacement error refuses", not Atomic.write(blocked, "candidate"))
	await _capability_checks()
	print("Generation store: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _capability_checks() -> void:
	# Runtime loading permits the project's autoload-backed definition types.
	var definition_script: Script = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_script.new()
	definition.capabilities.assign(["live_reload"])
	check("opt-in requires a scene panel", definition.validate_capabilities().get("error") == "capability_no_scene_panel")
	definition.data_directory = ProjectSettings.globalize_path(_test_root)
	var hook_path: String = definition.data_directory.path_join("Hooks.gd")
	check("write hooks fixture", Atomic.write(hook_path, "extends Control\nfunc _on_panel_save_request():\n\treturn {}\nfunc _on_panel_load_request(_state):\n\tpass\n"))
	definition.ui_panels.assign([{"name": "main", "kind": "godot_scene", "scripts": ["Hooks.gd"]}])
	check("opt-in requires hooks on its scene panel", definition.validate_capabilities().is_empty())
	definition.ui_panels.append({"name": "other", "kind": "godot_scene", "scripts": []})
	check("one panel cannot supply another panel's hooks", definition.validate_capabilities().get("error") == "capability_missing_hook")
	definition.capabilities.clear()
	check("non-opt-in plugin retains its contract", definition.validate_capabilities().is_empty())
