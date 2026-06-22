extends SceneTree
## Unit tests for MCPPreferenceTools (thin wrappers over PluginSettingsStore).
##
## Run: godot --headless --path src --script test/test_mcp_preference_tools.gd
##
## The module references the SingletonObject autoload (in _get_store's default
## path), so the test awaits a couple of frames before loading it — the autoload
## global is only available after the SceneTree starts processing. A real store
## with in-memory persistence is injected via _store_override so no config is
## touched and the live SingletonObject store is never used.

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


func _init() -> void:
	print("=== MCPPreferenceTools Unit Tests ===\n")
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
	# Let the SingletonObject autoload finish initializing before loading a
	# module that references it at compile time.
	await process_frame
	await process_frame

	var StoreScript := load("res://Scripts/Services/Plugins/PluginSettingsStore.gd")
	var ToolsScript := load("res://Scripts/Services/MCP/Modules/MCPPreferenceTools.gd")
	var store = StoreScript.new(null, MemPersist.new())
	var tools = ToolsScript.new(null)
	tools._store_override = store

	var g: Dictionary = tools.handle("minerva_get_preference", {"scope": "core", "key": "model"})
	_check(g.get("success", false) and g.get("value") == StoreScript.DEFAULT_SUMMARIZATION_MODEL, "get returns default")

	var s: Dictionary = tools.handle("minerva_set_preference", {"scope": "core", "key": "model", "value": "claude-opus-4-8"})
	_check(s.get("success", false) and s.get("value") == "claude-opus-4-8", "set succeeds and echoes value")
	var g2: Dictionary = tools.handle("minerva_get_preference", {"scope": "core", "key": "model"})
	_check(g2.get("value") == "claude-opus-4-8", "get reflects the set value")

	_check(not tools.handle("minerva_get_preference", {"scope": "core", "key": "nope"}).get("success", true), "get unknown key errors")
	_check(not tools.handle("minerva_get_preference", {"scope": "bogus", "key": "model"}).get("success", true), "get unknown scope errors")
	_check(not tools.handle("minerva_set_preference", {"scope": "core", "key": "nope", "value": "x"}).get("success", true), "set unknown key errors")
	_check(not tools.handle("minerva_set_preference", {"scope": "core", "key": "model"}).get("success", true), "set missing value errors")
	_check(not tools.handle("minerva_get_preference", {"scope": "core"}).get("success", true), "get missing key errors")

	var ls: Dictionary = tools.handle("minerva_list_preferences", {})
	_check(ls.get("success", false) and (ls.get("scopes", []) as Array).has("core"), "list (no scope) returns scopes")
	var lc: Dictionary = tools.handle("minerva_list_preferences", {"scope": "core"})
	_check(lc.get("success", false) and (lc.get("fields", []) as Array).size() == 3, "list (core) returns fields")
	_check(not tools.handle("minerva_list_preferences", {"scope": "bogus"}).get("success", true), "list unknown scope errors")

	_check(not tools.handle("minerva_frobnicate", {}).get("success", true), "unknown tool errors")
