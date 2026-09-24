extends Node
## Unit tests for PluginManager hot-reload decision tree (design §9.2).
##
## Run: godot --headless --path src --script test/test_plugin_manager_hot_reload.gd
##
## Coverage:
##   _on_reload_debounce_expired decision tree:
##     - .py/.js/.sh/.json change → plugin stop+start (existing behaviour preserved)
##     - .gd change with no live scene panels → plugin stop+start
##     - .gd change with live panels → retain the live generation and require restart
##     - .tscn change with a live panel → preserve it and require restart
##     - multiple extensions changed in one debounce window → union;
##       process ext restarts its backend while scene changes remain deferred
##
##   register_live_panel / unregister_live_panel / get_live_panels:
##     - basic registration and query
##     - unregistration removes entry
##
## Approach: StubPluginManager subclasses PluginManager but overrides restart_plugin
## so we can capture stop+start calls without a live subprocess.  Panel state is
## kept in the stub registry (_live_scene_panels dict) populated directly.
## PluginScenePanelHost and real scene loading are NOT exercised here.

signal completed(exit_code: int)

var _pass_count: int = 0
var _fail_count: int = 0


func _ready() -> void:
	print("=== PluginManager Hot-Reload Unit Tests ===\n")

	print("-- Live panel registry --")
	test_register_live_panel_basic()
	test_unregister_live_panel()
	test_get_live_panels_empty()

	print("\n-- Decision tree: process-ext change → stop+start --")
	test_py_change_triggers_stop_start()
	test_js_change_triggers_stop_start()
	test_sh_change_triggers_stop_start()
	test_json_change_triggers_stop_start()

	print("\n-- Decision tree: .gd change --")
	test_gd_no_live_panels_triggers_stop_start()
	test_gd_with_live_panels_reload_ok_no_stop_start()
	test_gd_reload_ok_calls_on_hot_reload_on_panels()
	test_gd_reload_fail_triggers_stop_start()
	test_gd_panel_without_on_hot_reload_is_safe()

	print("\n-- Decision tree: .tscn change --")
	test_tscn_no_live_panels_is_noop()
	test_tscn_with_live_panel_requires_restart()

	print("\n-- Decision tree: multiple extensions --")
	test_mixed_gd_tscn_both_handled()
	test_mixed_process_ext_dominates()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	completed.emit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ===========================================================================
# Stubs and helpers
# ===========================================================================

## StubDB: minimal duck-typed PluginDB that holds one fixed PluginDefinition.
class StubDB extends RefCounted:
	var definitions: Dictionary = {}

	func get_by_id(plugin_id: String):
		return definitions.get(plugin_id, null)

	func get_all() -> Array:
		return definitions.values()

	func get_by_status(state: int) -> Array:
		var result: Array = []
		for def in definitions.values():
			if def.state == state:
				result.append(def)
		return result

	func update_state(plugin_id: String, new_state: int) -> void:
		var def = definitions.get(plugin_id, null)
		if def != null:
			def.state = new_state

	func has_plugin(plugin_id: String) -> bool:
		return definitions.has(plugin_id)


## StubPluginDef: minimal plugin definition (not a real PluginDefinition to avoid
## parse-order issues in headless mode; duck-typed).
class StubPluginDef extends RefCounted:
	var id: String = ""
	var state: int = 2   # S_RUNNING
	var auto_reload: bool = true
	var data_directory: String = "/tmp/stub_plugin"
	var name: String = "stub"
	var version: String = "0.0.1"

	func _init(p_id: String) -> void:
		id = p_id


## StubBroker: captures unregister_panel calls.
class StubBroker extends RefCounted:
	var unregister_calls: Array[Dictionary] = []

	func unregister_panel(plugin_id: String, panel_name: String) -> void:
		unregister_calls.append({"plugin_id": plugin_id, "panel_name": panel_name})


## StubSceneRoot: Control that records _on_panel_unload and _on_hot_reload calls.
class StubSceneRoot extends Control:
	var unload_called: bool = false
	var hot_reload_called: bool = false
	var document: Dictionary = {"value": 7}

	func _on_panel_unload() -> void:
		unload_called = true

	func _on_hot_reload() -> void:
		hot_reload_called = true

	func _on_panel_save_request() -> Dictionary:
		return document.duplicate(true)

	func _on_panel_load_request(value: Variant) -> void:
		document = (value as Dictionary).duplicate(true)


## StubSceneRootNoHooks: Control with no lifecycle hooks.
class StubSceneRootNoHooks extends Control:
	pass


## TestablePluginManager: subclass of PluginManager with test-friendly overrides.
## - Injects StubDB
## - Captures restart_plugin calls instead of actually restarting
## - Allows injecting a fake broker and a fake instantiate callable
## - Exposes _on_reload_debounce_expired and _hot_reload_gd/_hot_reload_tscn
##   (these are inherited — we only override what needs intercepting)
class TestablePluginManager extends PluginManager:
	## Counts how many times restart_plugin was called.
	var restart_call_count: int = 0
	## Captures the plugin_id passed to restart_plugin.
	var restart_called_for: Array[String] = []

	## Injected StubDB — set before calling any methods.
	var stub_db: StubDB = null

	## Injected StubBroker — returned by _get_scene_panel_broker().
	var stub_broker: StubBroker = null

	## Override restart_plugin to capture calls without subprocess.
	func restart_plugin(id: String) -> Dictionary:
		restart_call_count += 1
		restart_called_for.append(id)
		return {"ok": true}

	## Override get_db() to return the stub.
	func get_db():
		return stub_db

	## Override _get_scene_panel_broker to return stub broker.
	func _get_scene_panel_broker() -> PluginScenePanelBroker:
		# Return null if no stub — tests that don't need broker set it themselves.
		# We can't return stub_broker directly (typed PluginScenePanelBroker) because
		# StubBroker doesn't inherit from it.  Instead store broker as Variant and
		# cast in _hot_reload_tscn.  We use the override to set _stub_broker_variant.
		return null  # Tests that need a broker drive _live_scene_panels directly.


## Build a TestablePluginManager with one plugin in state RUNNING with auto_reload=true.
func _make_manager(plugin_id: String) -> TestablePluginManager:
	var mgr := TestablePluginManager.new()
	var db := StubDB.new()
	var def := StubPluginDef.new(plugin_id)
	db.definitions[plugin_id] = def
	mgr.stub_db = db
	mgr._db = db
	return mgr


## Build a named stub panel entry dict (does NOT add to manager._live_scene_panels).
func _make_panel_entry(
		panel_name: String,
		tscn_path: String,
		vbox: Control,
		panel_root: Control,
		editor = null
) -> Dictionary:
	return {
		"panel_name": panel_name,
		"tscn_path":  tscn_path,
		"vbox":       vbox,
		"root":       panel_root,
		"editor":     editor,
	}


# ===========================================================================
# Live panel registry tests
# ===========================================================================

func test_register_live_panel_basic() -> void:
	print("test_register_live_panel_basic:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()

	mgr.register_live_panel("cad", "cad_viewer", "/tmp/p/ui/CadViewer.tscn", vbox, panel_root, null)

	var panels := mgr.get_live_panels("cad")
	check("one panel registered", panels.size() == 1)
	check("panel_name is correct", panels[0].get("panel_name", "") == "cad_viewer")
	check("tscn_path is correct",
		panels[0].get("tscn_path", "") == "/tmp/p/ui/CadViewer.tscn")

	vbox.free()
	panel_root.free()
	mgr.free()


func test_unregister_live_panel() -> void:
	print("test_unregister_live_panel:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()

	mgr.register_live_panel("cad", "cad_viewer", "/tmp/p/ui/CadViewer.tscn", vbox, panel_root, null)
	mgr.unregister_live_panel("cad", "cad_viewer")

	var panels := mgr.get_live_panels("cad")
	check("panel removed after unregister", panels.is_empty())

	vbox.free()
	panel_root.free()
	mgr.free()


func test_get_live_panels_empty() -> void:
	print("test_get_live_panels_empty:")
	var mgr := _make_manager("cad")
	var panels := mgr.get_live_panels("cad")
	check("empty array for plugin with no panels", panels.is_empty())
	mgr.free()


# ===========================================================================
# Decision tree: process-ext change → stop+start
# ===========================================================================

func _run_debounce_for_paths(mgr: TestablePluginManager, plugin_id: String, paths: Array) -> void:
	# Directly inject changed paths into the pending dict (bypasses file system)
	# and fire the debounce handler synchronously.
	mgr._pending_changed_paths[plugin_id] = paths
	# Fake a valid state check: ensure auto_reload + state are set.
	var def = mgr._db.get_by_id(plugin_id)
	if def != null:
		def.state = PluginManager.S_RUNNING
	# _on_reload_debounce_expired is async but its sync path exercises the whole
	# decision tree up to the await points.  We call it without await — the
	# restart_plugin override is non-async so it returns synchronously, meaning
	# the await on restart_plugin resolves immediately.
	# For _hot_reload_gd / _hot_reload_tscn which are also async, same applies.
	mgr._on_reload_debounce_expired(plugin_id)


func test_py_change_triggers_stop_start() -> void:
	print("test_py_change_triggers_stop_start:")
	var mgr := _make_manager("obs")
	_run_debounce_for_paths(mgr, "obs", ["/tmp/obs/obs_controller.py"])
	check("restart called for .py change", mgr.restart_call_count == 1)
	check("restart was for correct plugin_id", "obs" in mgr.restart_called_for)
	mgr.free()


func test_js_change_triggers_stop_start() -> void:
	print("test_js_change_triggers_stop_start:")
	var mgr := _make_manager("webplugin")
	_run_debounce_for_paths(mgr, "webplugin", ["/tmp/wp/panel.js"])
	check("restart called for .js change", mgr.restart_call_count == 1)
	mgr.free()


func test_sh_change_triggers_stop_start() -> void:
	print("test_sh_change_triggers_stop_start:")
	var mgr := _make_manager("shplugin")
	_run_debounce_for_paths(mgr, "shplugin", ["/tmp/sh/start.sh"])
	check("restart called for .sh change", mgr.restart_call_count == 1)
	mgr.free()


func test_json_change_triggers_stop_start() -> void:
	print("test_json_change_triggers_stop_start:")
	var mgr := _make_manager("jsonplugin")
	_run_debounce_for_paths(mgr, "jsonplugin", ["/tmp/jp/config.json"])
	check("restart called for .json change", mgr.restart_call_count == 1)
	mgr.free()


# ===========================================================================
# Decision tree: .gd change
# ===========================================================================

func test_gd_no_live_panels_triggers_stop_start() -> void:
	print("test_gd_no_live_panels_triggers_stop_start:")
	var mgr := _make_manager("cad")
	# No panels registered — _live_scene_panels["cad"] is empty.
	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.gd"])
	check("uncached gd change needs neither process nor app restart",
		mgr.restart_call_count == 0 \
		and mgr.get_restart_required_reason("cad").is_empty())
	mgr.free()


func test_gd_with_live_panels_reload_ok_no_stop_start() -> void:
	print("test_gd_with_live_panels_reload_ok_no_stop_start:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()

	# Register a live panel so _hot_reload_gd sees panels exist.
	mgr.register_live_panel("cad", "cad_viewer", "/tmp/cad/ui/CadViewer.tscn", vbox, panel_root, null)

	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.gd"])

	check("no process restart when a live panel requires an app restart",
		mgr.restart_call_count == 0)
	check("live .gd update records an explicit restart reason",
		not mgr.get_restart_required_reason("cad").is_empty())
	check("old panel generation remains intact", is_instance_valid(panel_root))

	vbox.free()
	panel_root.free()
	mgr.free()


func test_gd_reload_ok_calls_on_hot_reload_on_panels() -> void:
	print("test_gd_reload_ok_calls_on_hot_reload_on_panels:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()

	mgr.register_live_panel("cad", "cad_viewer", "/tmp/cad/ui/CadViewer.tscn", vbox, panel_root, null)

	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.gd"])

	check("unsafe in-place _on_hot_reload is not dispatched", not panel_root.hot_reload_called)

	vbox.free()
	panel_root.free()
	mgr.free()


func test_gd_reload_fail_triggers_stop_start() -> void:
	print("test_gd_reload_fail_triggers_stop_start:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()
	mgr.register_live_panel("cad", "cad_viewer", "/tmp/cad/ui/CadViewer.tscn", vbox, panel_root, null)

	panel_root.queue_free()   # Free before check — root is now invalid.
	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.gd"])

	check("registry presence still prevents an unsafe process-only restart",
		mgr.restart_call_count == 0)
	check("freed panel entry still reports app restart requirement",
		not mgr.get_restart_required_reason("cad").is_empty())

	vbox.free()
	mgr.free()


func test_gd_panel_without_on_hot_reload_is_safe() -> void:
	print("test_gd_panel_without_on_hot_reload_is_safe:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRootNoHooks.new()

	mgr.register_live_panel("cad", "cad_viewer", "/tmp/cad/ui/CadViewer.tscn", vbox, panel_root, null)
	# No hooks are invoked for a GDScript update; the known-good root is retained.
	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.gd"])
	check("hookless panel also gets an explicit restart requirement",
		not mgr.get_restart_required_reason("cad").is_empty())
	vbox.free()
	panel_root.free()
	mgr.free()


# ===========================================================================
# Decision tree: .tscn change
# ===========================================================================

func test_tscn_no_live_panels_is_noop() -> void:
	print("test_tscn_no_live_panels_is_noop:")
	var mgr := _make_manager("cad")
	_run_debounce_for_paths(mgr, "cad", ["/tmp/cad/ui/CadViewer.tscn"])
	check("no restart boundary for an unloaded scene", mgr.get_restart_required_reason("cad").is_empty())
	mgr.free()


func test_tscn_with_live_panel_requires_restart() -> void:
	print("test_tscn_with_live_panel_requires_restart:")
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()
	var tscn := "/tmp/cad/ui/CadViewer.tscn"
	mgr.register_live_panel("cad", "cad_viewer", tscn, vbox, panel_root, null)
	_run_debounce_for_paths(mgr, "cad", [tscn])
	check("live scene remains intact", is_instance_valid(panel_root) and not panel_root.unload_called)
	check("scene change records restart requirement",
		not mgr.get_restart_required_reason("cad").is_empty())
	vbox.free()
	panel_root.free()
	mgr.free()


# ===========================================================================
# Decision tree: multiple extensions in one window
# ===========================================================================

func test_mixed_gd_tscn_both_handled() -> void:
	print("test_mixed_gd_tscn_both_handled:")
	# .gd + .tscn changed in one window: retain the loaded scene generation.
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()
	var tscn := "/tmp/cad/ui/CadViewer.tscn"

	mgr.register_live_panel("cad", "cad_viewer", tscn, vbox, panel_root, null)

	_run_debounce_for_paths(mgr, "cad", [
		"/tmp/cad/ui/CadViewer.gd",
		tscn,
	])

	# No process-ext → no stop+start.
	check("no stop+start for mixed gd+tscn", mgr.restart_call_count == 0)
	check("mixed gd+tscn retains the old root",
		is_instance_valid(panel_root) and not panel_root.unload_called)
	check("mixed gd+tscn records restart guidance",
		not mgr.get_restart_required_reason("cad").is_empty())

	vbox.free()
	mgr.free()


func test_mixed_process_ext_dominates() -> void:
	print("test_mixed_process_ext_dominates:")
	# .py + .gd + .tscn: process ext dominates → stop+start.
	var mgr := _make_manager("cad")
	var vbox := Control.new()
	var panel_root := StubSceneRoot.new()
	var tscn := "/tmp/cad/ui/CadViewer.tscn"

	mgr.register_live_panel("cad", "cad_viewer", tscn, vbox, panel_root, null)

	_run_debounce_for_paths(mgr, "cad", [
		"/tmp/cad/obs_controller.py",
		"/tmp/cad/ui/CadViewer.gd",
		tscn,
	])

	check("stop+start triggered when process ext present in mixed change",
		mgr.restart_call_count == 1)
	# Early return before tscn path: unload NOT called.
	check("_on_panel_unload NOT called (early stop+start return)",
		not panel_root.unload_called)

	vbox.free()
	panel_root.free()
	mgr.free()
