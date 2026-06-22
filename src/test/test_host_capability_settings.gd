extends SceneTree
## Unit tests for the host.settings.* capability handlers.
##
## Run: godot --headless --path src --script test/test_host_capability_settings.gd
##
## Awaits frames so the SingletonObject autoload (referenced by CapabilityBroker
## at compile time) is available, then temporarily swaps in a controlled store
## (in-memory persistence, two fake plugins) to prove scope isolation without
## touching the real config. The live store is restored afterwards.

var _pass_count: int = 0
var _fail_count: int = 0


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
	print("=== host.settings.* Capability Tests ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _run() -> void:
	await process_frame
	await process_frame

	# Allowlist carries the new capabilities.
	_check(PluginDefinition.ALLOWED_HOST_CAPABILITIES.has("host.settings.get"), "allowlist has host.settings.get")
	_check(PluginDefinition.ALLOWED_HOST_CAPABILITIES.has("host.settings.list"), "allowlist has host.settings.list")

	# Two plugins, distinct settings, to prove a plugin only ever reads its own.
	var alpha := PluginDefinition.new("alpha")
	alpha.settings = [{"key": "theme", "type": "string", "default": "dark"}]
	var beta := PluginDefinition.new("beta")
	beta.settings = [{"key": "theme", "type": "string", "default": "light"}]
	var db := FakeDB.new()
	db.defs["alpha"] = alpha
	db.defs["beta"] = beta

	var StoreScript := load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var store = StoreScript.new(db, MemPersist.new())

	# Fetch the autoload as a node — the `SingletonObject` global identifier is not
	# resolvable in this entry script's own body (it compiles before autoloads register).
	var singleton = root.get_node_or_null("SingletonObject")
	_check(singleton != null, "SingletonObject autoload present")
	var saved = singleton.plugin_settings_store
	singleton.plugin_settings_store = store

	var BrokerScript := load("res://Scripts/Services/Plugins/CapabilityBroker.gd")
	var broker = BrokerScript.new(null, null)

	var ga: Dictionary = broker._handle_host_settings_get("alpha", {"key": "theme"})
	_check(ga.get("success", false) and (ga.get("result", {}) as Dictionary).get("value") == "dark", "alpha reads its own value")
	var gb: Dictionary = broker._handle_host_settings_get("beta", {"key": "theme"})
	_check(gb.get("success", false) and (gb.get("result", {}) as Dictionary).get("value") == "light", "beta reads its own value (isolation)")

	_check(not broker._handle_host_settings_get("alpha", {"key": "nope"}).get("success", true), "unknown key errors")
	_check(not broker._handle_host_settings_get("alpha", {}).get("success", true), "missing key errors")
	_check(not broker._handle_host_settings_get("ghost", {"key": "theme"}).get("success", true), "unknown plugin errors")

	var la: Dictionary = broker._handle_host_settings_list("alpha", {})
	var la_fields: Array = (la.get("result", {}) as Dictionary).get("fields", [])
	_check(la.get("success", false) and la_fields.size() == 1 and str((la_fields[0] as Dictionary).get("key", "")) == "theme", "list returns own fields")

	singleton.plugin_settings_store = saved
