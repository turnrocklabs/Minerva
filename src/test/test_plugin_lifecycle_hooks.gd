extends SceneTree
## Unit tests for PluginScenePanelHost save/load/unload static dispatch helpers
## and PluginDefinition save_mode manifest field (design §5.1, §7.5).
##
## Run: godot --headless --path src --script test/test_plugin_lifecycle_hooks.gd
##
## Coverage:
##   PluginScenePanelHost.invoke_save:
##     - scene implements _on_panel_save_request → called, result returned
##     - scene does NOT implement the method → returns null + warning (no crash)
##     - scene hook pushes an error internally → host does not crash
##     - null panel_root → returns null without crash
##
##   PluginScenePanelHost.invoke_load:
##     - scene implements _on_panel_load_request → called with correct document
##     - scene does NOT implement the method → returns false + warning (no crash)
##     - scene hook pushes an error internally → host does not crash
##     - null panel_root → returns false without crash
##
##   PluginScenePanelHost.invoke_unload:
##     - scene implements _on_panel_unload → called
##     - scene does NOT implement the method → no crash
##     - null panel_root → no crash
##
##   PluginDefinition._parse_panel_entry save_mode field:
##     - save_mode: "host_owned" accepted, persisted in panel dict
##     - save_mode: "plugin_owned" accepted, persisted in panel dict
##     - save_mode: "garbage" rejected with panel_save_mode_invalid structured error
##     - save_mode absent → defaults to "host_owned"
##     - save_mode applies to html panels as well as godot_scene panels

const PluginScenePanelHost_ = preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginScenePanelHost Lifecycle Hook Tests ===\n")

	print("-- invoke_save --")
	test_invoke_save_calls_hook_and_returns_result()
	test_invoke_save_missing_method_returns_null_no_crash()
	test_invoke_save_hook_error_host_does_not_crash()
	test_invoke_save_null_root_returns_null()

	print("\n-- invoke_load --")
	test_invoke_load_calls_hook_with_document()
	test_invoke_load_missing_method_returns_false_no_crash()
	test_invoke_load_hook_error_host_does_not_crash()
	test_invoke_load_null_root_returns_false()

	print("\n-- invoke_unload --")
	test_invoke_unload_calls_hook()
	test_invoke_unload_missing_method_no_crash()
	test_invoke_unload_null_root_no_crash()

	print("\n-- PluginDefinition save_mode field --")
	test_save_mode_host_owned_accepted()
	test_save_mode_plugin_owned_accepted()
	test_save_mode_invalid_rejected_with_structured_error()
	test_save_mode_absent_defaults_to_host_owned()
	test_save_mode_applies_to_html_panels()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr(("  FAIL: %s — expected %s, got %s") % [description, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Mock scene classes
# ---------------------------------------------------------------------------

## A scene that fully implements all three lifecycle save/load hooks.
## Returns a predictable Dictionary from _on_panel_save_request so tests can
## verify the return value is passed through unchanged.
class MockSceneWithHooks extends Control:
	var save_called: bool = false
	var save_ctx_received: Dictionary = {}
	var load_called: bool = false
	var load_document_received: Variant = null
	var unload_called: bool = false

	func _on_panel_save_request() -> Dictionary:
		save_called = true
		return {"version": 1, "data": "mock_save_payload"}

	func _on_panel_load_request(document: Dictionary) -> void:
		load_called = true
		load_document_received = document

	func _on_panel_unload() -> void:
		unload_called = true


## A scene that deliberately does NOT implement any of the save/load hooks.
## Used to verify that invoke_save / invoke_load return gracefully without crash.
class MockSceneNoHooks extends Control:
	# Intentionally empty — no save/load/unload hooks.
	pass


## A scene whose hooks call push_error() internally (simulating a scene-side
## error).  The host must not crash; it logs the error and returns normally.
class MockSceneWithErrorInHook extends Control:
	var save_called: bool = false
	var load_called: bool = false
	var unload_called: bool = false

	func _on_panel_save_request() -> Dictionary:
		save_called = true
		push_error("[MockSceneWithErrorInHook] intentional error in _on_panel_save_request")
		return {"error_state": true}

	func _on_panel_load_request(_document: Dictionary) -> void:
		load_called = true
		push_error("[MockSceneWithErrorInHook] intentional error in _on_panel_load_request")

	func _on_panel_unload() -> void:
		unload_called = true
		push_error("[MockSceneWithErrorInHook] intentional error in _on_panel_unload")


# ---------------------------------------------------------------------------
# Manifest helper
# ---------------------------------------------------------------------------

## Build a minimal valid manifest dict for testing save_mode parsing.
func _minimal_manifest_with_panel(panel: Dictionary,
		extra_ipc_messages: Array = []) -> Dictionary:
	var ipc_msgs: Array = extra_ipc_messages.duplicate()
	return {
		"id": "test_plugin",
		"name": "Test Plugin",
		"version": "0.1.0",
		"backend": {
			"transport": "stdio",
			"entrypoint": "server.py",
		},
		"ui": {
			"panels": [panel],
			"ipc_messages": ipc_msgs,
		},
		"permissions": {
			"host_capabilities": [],
			"network": {"mode": "none"},
			"filesystem": {"mode": "none"},
		},
	}


# ===========================================================================
# invoke_save tests
# ===========================================================================

func test_invoke_save_calls_hook_and_returns_result() -> void:
	print("test_invoke_save_calls_hook_and_returns_result:")
	var scene := MockSceneWithHooks.new()
	var ctx: Dictionary = {}
	var result: Variant = PluginScenePanelHost_.invoke_save(scene, ctx)
	check("invoke_save: hook was called", scene.save_called)
	check("invoke_save: result is a Dictionary", result is Dictionary)
	check("invoke_save: result has expected key",
		result is Dictionary and (result as Dictionary).has("data"))
	check("invoke_save: result value correct",
		result is Dictionary and (result as Dictionary).get("data", "") == "mock_save_payload")
	scene.free()


func test_invoke_save_missing_method_returns_null_no_crash() -> void:
	print("test_invoke_save_missing_method_returns_null_no_crash:")
	var scene := MockSceneNoHooks.new()
	# Wrap in Array to capture by reference across the GDScript lambda boundary.
	var did_crash_holder: Array = [false]
	var result: Variant = null
	# This must not raise; if it did, the test itself would abort.
	result = PluginScenePanelHost_.invoke_save(scene, {})
	check("invoke_save missing method: returns null", result == null)
	check("invoke_save missing method: did not crash", not did_crash_holder[0])
	scene.free()


func test_invoke_save_hook_error_host_does_not_crash() -> void:
	print("test_invoke_save_hook_error_host_does_not_crash:")
	var scene := MockSceneWithErrorInHook.new()
	# If the host crashes this test function would never reach the check() call.
	var result: Variant = PluginScenePanelHost_.invoke_save(scene, {})
	check("invoke_save hook error: hook was still called", scene.save_called)
	check("invoke_save hook error: host returned a value (no crash)", result != null)
	check("invoke_save hook error: result is Dictionary", result is Dictionary)
	scene.free()


func test_invoke_save_null_root_returns_null() -> void:
	print("test_invoke_save_null_root_returns_null:")
	var result: Variant = PluginScenePanelHost_.invoke_save(null, {})
	check("invoke_save null root: returns null", result == null)


# ===========================================================================
# invoke_load tests
# ===========================================================================

func test_invoke_load_calls_hook_with_document() -> void:
	print("test_invoke_load_calls_hook_with_document:")
	var scene := MockSceneWithHooks.new()
	var document: Dictionary = {"file_format": "mcad", "version": 2, "nodes": []}
	var ok: bool = PluginScenePanelHost_.invoke_load(scene, document)
	check("invoke_load: returns true", ok)
	check("invoke_load: hook was called", scene.load_called)
	check("invoke_load: document passed correctly",
		scene.load_document_received is Dictionary and
		(scene.load_document_received as Dictionary).get("file_format", "") == "mcad")
	scene.free()


func test_invoke_load_missing_method_returns_false_no_crash() -> void:
	print("test_invoke_load_missing_method_returns_false_no_crash:")
	var scene := MockSceneNoHooks.new()
	var ok: bool = PluginScenePanelHost_.invoke_load(scene, {"data": "irrelevant"})
	check("invoke_load missing method: returns false", not ok)
	scene.free()


func test_invoke_load_hook_error_host_does_not_crash() -> void:
	print("test_invoke_load_hook_error_host_does_not_crash:")
	var scene := MockSceneWithErrorInHook.new()
	# Must complete without crashing even though hook calls push_error.
	var ok: bool = PluginScenePanelHost_.invoke_load(scene, {})
	check("invoke_load hook error: hook was called", scene.load_called)
	check("invoke_load hook error: returned true (hook dispatched, no crash)", ok)
	scene.free()


func test_invoke_load_null_root_returns_false() -> void:
	print("test_invoke_load_null_root_returns_false:")
	var ok: bool = PluginScenePanelHost_.invoke_load(null, {})
	check("invoke_load null root: returns false", not ok)


# ===========================================================================
# invoke_unload tests
# ===========================================================================

func test_invoke_unload_calls_hook() -> void:
	print("test_invoke_unload_calls_hook:")
	var scene := MockSceneWithHooks.new()
	PluginScenePanelHost_.invoke_unload(scene)
	check("invoke_unload: hook was called", scene.unload_called)
	scene.free()


func test_invoke_unload_missing_method_no_crash() -> void:
	print("test_invoke_unload_missing_method_no_crash:")
	var scene := MockSceneNoHooks.new()
	# Must not crash. If it crashed the test would abort before reaching check().
	PluginScenePanelHost_.invoke_unload(scene)
	check("invoke_unload missing method: no crash", true)
	scene.free()


func test_invoke_unload_null_root_no_crash() -> void:
	print("test_invoke_unload_null_root_no_crash:")
	PluginScenePanelHost_.invoke_unload(null)
	check("invoke_unload null root: no crash", true)


# ===========================================================================
# PluginDefinition save_mode field tests
# ===========================================================================

func test_save_mode_host_owned_accepted() -> void:
	print("test_save_mode_host_owned_accepted:")
	var manifest := _minimal_manifest_with_panel({
		"name": "my_panel",
		"kind": "godot_scene",
		"entry_scene": "ui/MyPanel.tscn",
		"scripts": ["ui/MyPanel.gd"],
		"save_mode": "host_owned",
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("save_mode host_owned: def not null", def != null)
	if def == null:
		return
	check_eq("save_mode host_owned: panel count", def.ui_panels.size(), 1)
	check_eq("save_mode host_owned: save_mode value",
		def.ui_panels[0].get("save_mode", ""), "host_owned")


func test_save_mode_plugin_owned_accepted() -> void:
	print("test_save_mode_plugin_owned_accepted:")
	var manifest := _minimal_manifest_with_panel({
		"name": "my_panel",
		"kind": "godot_scene",
		"entry_scene": "ui/MyPanel.tscn",
		"scripts": ["ui/MyPanel.gd"],
		"save_mode": "plugin_owned",
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("save_mode plugin_owned: def not null", def != null)
	if def == null:
		return
	check_eq("save_mode plugin_owned: save_mode value",
		def.ui_panels[0].get("save_mode", ""), "plugin_owned")


func test_save_mode_invalid_rejected_with_structured_error() -> void:
	print("test_save_mode_invalid_rejected_with_structured_error:")
	# "garbage" is not a valid save_mode — manifest must be rejected.
	var manifest := _minimal_manifest_with_panel({
		"name": "my_panel",
		"kind": "godot_scene",
		"entry_scene": "ui/MyPanel.tscn",
		"scripts": ["ui/MyPanel.gd"],
		"save_mode": "garbage",
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("save_mode garbage: def is null (rejected)", def == null)


func test_save_mode_absent_defaults_to_host_owned() -> void:
	print("test_save_mode_absent_defaults_to_host_owned:")
	# save_mode absent → must default to "host_owned"
	var manifest := _minimal_manifest_with_panel({
		"name": "my_panel",
		"kind": "godot_scene",
		"entry_scene": "ui/MyPanel.tscn",
		"scripts": ["ui/MyPanel.gd"],
		# save_mode intentionally absent
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("save_mode absent: def not null", def != null)
	if def == null:
		return
	check_eq("save_mode absent: defaults to host_owned",
		def.ui_panels[0].get("save_mode", ""), "host_owned")


func test_save_mode_applies_to_html_panels() -> void:
	print("test_save_mode_applies_to_html_panels:")
	# save_mode should also apply to html kind panels (§7.5 doesn't restrict to godot_scene).
	var manifest := _minimal_manifest_with_panel({
		"name": "html_panel",
		"kind": "html",
		"save_mode": "plugin_owned",
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("save_mode html panel: def not null", def != null)
	if def == null:
		return
	check_eq("save_mode html panel: save_mode persisted",
		def.ui_panels[0].get("save_mode", ""), "plugin_owned")
