extends SceneTree
## Unit tests for PluginSettingsStore + PluginDefinition.settings schema.
##
## Run: godot --headless --path src --script test/test_plugin_settings_store.gd
##
## Coverage:
##   manifest settings parse (from_dict) + to_dict round-trip
##   validate() catches: non-dict entry, empty key, duplicate key, bad type, enum w/o options
##   store: core defaults, set/get round-trip, unknown scope/key errors, list_settings/list_scopes
##   store: plugin scope via a fake DB — enum/bool/number coercion + [Plugin:<id>] section
##   ConfigFile round-trips a colon-bearing section name ([Plugin:<id>])

var _pass_count: int = 0
var _fail_count: int = 0


## In-memory persistence injected into the store so tests never touch the real
## config_file.cfg. The store is load()ed at runtime (not referenced by class_name)
## so its SingletonObject reference compiles after autoloads are up.
class MemPersist:
	var mem: Dictionary = {}

	func read(section: String, key: String) -> Variant:
		return (mem.get(section, {}) as Dictionary).get(key, null)

	func write(section: String, key: String, value: Variant) -> void:
		if not mem.has(section):
			mem[section] = {}
		(mem[section] as Dictionary)[key] = value


class FakeDB:
	var defs: Dictionary = {}

	func get_by_id(plugin_id: String):
		return defs.get(plugin_id, null)

	func get_all() -> Array:
		return defs.values()


func _init() -> void:
	print("=== PluginSettingsStore Unit Tests ===\n")

	print("-- manifest settings parse + round-trip --")
	test_manifest_parse_roundtrip()

	print("\n-- manifest settings validation --")
	test_manifest_validation()

	print("\n-- store: core scope --")
	test_store_core()

	print("\n-- store: plugin scope + coercion --")
	test_store_plugin_scope()

	print("\n-- ConfigFile colon-section round-trip --")
	test_colon_section_roundtrip()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _has_err(errors: Array, needle: String) -> bool:
	for e in errors:
		if (e as String).find(needle) != -1:
			return true
	return false


func test_manifest_parse_roundtrip() -> void:
	var manifest := {
		"id": "demo", "name": "Demo", "version": "1.0.0",
		"backend": {"entrypoint": "x"},
		"settings": [
			{"key": "flavor", "type": "enum", "label": "Flavor", "default": "a", "options": ["a", "b"]},
		],
	}
	var def := PluginDefinition.from_dict(manifest)
	_check(def != null, "from_dict succeeds")
	_check(def.settings.size() == 1, "settings parsed (1 entry)")
	_check(str(def.settings[0].get("key", "")) == "flavor", "setting key preserved")
	var rt := def.to_dict()
	_check(rt.has("settings"), "to_dict emits settings")
	_check(str((rt["settings"][0] as Dictionary).get("type", "")) == "enum", "to_dict preserves type")

	var no_settings := PluginDefinition.from_dict({"id": "x", "name": "X", "version": "1", "backend": {"entrypoint": "y"}})
	_check(not no_settings.to_dict().has("settings"), "to_dict omits empty settings")


func test_manifest_validation() -> void:
	var bad := PluginDefinition.new("demo")
	bad.settings = [
		{"key": "", "type": "string"},
		{"key": "dup", "type": "string"},
		{"key": "dup", "type": "string"},
		{"key": "weird", "type": "frobnicate"},
		{"key": "e", "type": "enum"},
	]
	var errs := bad.validate()
	_check(_has_err(errs, "settings[0] has empty 'key'"), "empty key flagged")
	_check(_has_err(errs, "manifest_duplicate_setting_key: 'dup'"), "duplicate key flagged")
	_check(_has_err(errs, "invalid type 'frobnicate'"), "bad type flagged")
	_check(_has_err(errs, "enum setting 'e' requires a non-empty 'options'"), "enum w/o options flagged")

	var good := PluginDefinition.new("demo")
	good.settings = [{"key": "ok", "type": "enum", "options": ["a"]}]
	_check(not _has_err(good.validate(), "setting"), "valid settings produce no settings errors")


func test_store_core() -> void:
	var StoreScript := load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var persist := MemPersist.new()
	var store = StoreScript.new(null, persist)
	_check(store.get_value("core", "model") == StoreScript.DEFAULT_SUMMARIZATION_MODEL, "core model default")
	_check(store.get_value("core", "prompt") == StoreScript.DEFAULT_SUMMARIZATION_PROMPT, "core prompt default")

	var r: Dictionary = store.set_value("core", "model", "claude-opus-4-8")
	_check(r.get("success", false), "set core model succeeds")
	_check(store.get_value("core", "model") == "claude-opus-4-8", "core model round-trips")
	_check((persist.mem.get("Summarization", {}) as Dictionary).has("model"), "core persists under [Summarization]")

	_check(not store.set_value("core", "nope", "x").get("success", false), "unknown key rejected")
	_check(store.get_value("core", "nope") == null, "unknown key reads null")
	_check(not store.set_value("plugin:ghost", "k", "v").get("success", false), "unknown scope rejected")

	var ls: Dictionary = store.list_settings("core")
	_check(ls.get("success", false) and (ls.get("fields", []) as Array).size() == 2, "list_settings core has 2 fields")
	_check(ls.get("title") == "Summarization", "list_settings core carries a title")
	_check(not store.list_settings("bogus").get("success", false), "list_settings unknown scope errors")
	_check((store.list_scopes() as Array).has("core"), "list_scopes includes core")


func test_store_plugin_scope() -> void:
	var pdef := PluginDefinition.new("demo")
	pdef.name = "Demo Plugin"
	pdef.settings = [
		{"key": "flavor", "type": "enum", "label": "Flavor", "default": "a", "options": ["a", "b"]},
		{"key": "enabled", "type": "bool", "label": "Enabled", "default": false},
		{"key": "count", "type": "number", "label": "Count", "default": 1},
	]
	var db := FakeDB.new()
	db.defs["demo"] = pdef
	var StoreScript := load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var persist := MemPersist.new()
	var store = StoreScript.new(db, persist)

	_check(store.get_value("plugin:demo", "flavor") == "a", "plugin enum default")
	_check(not store.set_value("plugin:demo", "flavor", "z").get("success", false), "enum rejects out-of-options")
	_check(store.set_value("plugin:demo", "flavor", "b").get("success", false), "enum accepts valid option")
	_check(store.get_value("plugin:demo", "flavor") == "b", "enum value round-trips")

	var rb: Dictionary = store.set_value("plugin:demo", "enabled", "true")
	_check(rb.get("success", false) and rb.get("value") == true, "bool coerces string 'true'")
	var rn: Dictionary = store.set_value("plugin:demo", "count", "3.5")
	_check(rn.get("success", false) and rn.get("value") == 3.5, "number coerces numeric string")

	_check(persist.mem.has("Plugin:demo"), "plugin persists under [Plugin:demo]")
	_check((store.list_scopes() as Array).has("plugin:demo"), "list_scopes includes declaring plugin")
	_check(store.list_settings("plugin:demo").get("title") == "Demo Plugin", "plugin scope title is the plugin display name")


func test_colon_section_roundtrip() -> void:
	var tmp := "user://__test_settings_roundtrip.cfg"
	var cf := ConfigFile.new()
	cf.set_value("Plugin:demo", "flavor", "b")
	_check(cf.save(tmp) == OK, "save config with colon section")
	var cf2 := ConfigFile.new()
	_check(cf2.load(tmp) == OK, "load config with colon section")
	_check(cf2.has_section("Plugin:demo"), "colon section present after reload")
	_check(cf2.get_value("Plugin:demo", "flavor", "") == "b", "colon-section value round-trips")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
