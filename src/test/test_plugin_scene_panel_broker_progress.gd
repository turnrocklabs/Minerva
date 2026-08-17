extends SceneTree
## Unit tests for PluginScenePanelBroker.push_progress.
##
## Run: godot --headless --path src --script test/test_plugin_scene_panel_broker_progress.gd
##
## Coverage:
##   push_progress to registered panel with on_progress: delivers correctly; audit fires
##   push_progress to unregistered panel: returns false; audit scene_progress_miss
##   push_progress with mismatched plugin_id: returns false; audit scene_denied
##   push_progress when scene lacks on_progress: returns false; reason progress_unsupported
##   push_progress passes phase + fraction through unchanged
##   Multiple concurrent progress events with different request_ids each deliver correctly

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginScenePanelBroker push_progress Unit Tests ===\n")

	print("-- push_progress: registered panel with on_progress --")
	test_push_progress_registered_panel()

	print("\n-- push_progress: unregistered panel --")
	test_push_progress_unregistered_panel()

	print("\n-- push_progress: mismatched plugin_id --")
	test_push_progress_wrong_owner()

	print("\n-- push_progress: scene lacks on_progress --")
	test_push_progress_no_on_progress_method()

	print("\n-- push_progress: phase and fraction pass-through --")
	test_push_progress_data_passthrough()

	print("\n-- push_progress: multiple concurrent request_ids --")
	test_push_progress_multiple_request_ids()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ===========================================================================
# Test stubs
# ===========================================================================

## PluginDB stub.
class StubDB extends RefCounted:
	var definitions: Dictionary = {}

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)


## PluginManager stub.
class StubManager extends RefCounted:
	var _db: StubDB = StubDB.new()

	func get_db():
		return _db

	func get_connection(_id: String):
		return null


## PluginAuditLog stub: captures events.
class StubAuditLog extends PluginAuditLog:
	var events: Array[Dictionary] = []

	func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
		events.append({"plugin_id": plugin_id, "event_type": event_type, "detail": detail})

	func has_event_type(t: String) -> bool:
		for e in events:
			if e["event_type"] == t:
				return true
		return false

	func events_of_type(t: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for e in events:
			if e["event_type"] == t:
				out.append(e)
		return out

	func last_event_of_type(t: String) -> Dictionary:
		var all := events_of_type(t)
		if all.is_empty():
			return {}
		return all[-1]


## Scene root with on_progress support.
class StubSceneWithProgress extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var progress_calls: Array[Dictionary] = []

	func receive(_channel: String, _payload: Dictionary) -> void:
		pass

	func on_progress(request_id: String, phase: String, fraction: float) -> void:
		progress_calls.append({
			"request_id": request_id,
			"phase": phase,
			"fraction": fraction,
		})


## Scene root WITHOUT on_progress (opts out of progress notifications).
class StubSceneNoProgress extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	func receive(_channel: String, _payload: Dictionary) -> void:
		pass


## Build a minimal PluginDefinition.
func _make_def(plugin_id: String, panel_names: Array, ipc_messages: Array) -> PluginDefinition:
	var typed_panels: Array = []
	for n in panel_names:
		typed_panels.append({
			"name": String(n),
			"kind": "html",
			"entry": ("ui/%s.html" % String(n)),
		})

	var d := {
		"id": plugin_id,
		"name": plugin_id,
		"version": "0.0.1",
		"host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "stub.py", "args": [], "working_dir": ""},
		"ui": {"panels": typed_panels, "ipc_messages": ipc_messages},
		"tools": [],
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"data_directory": "/tmp/stub_plugin",
		"autostart": false,
		"auto_reload": false,
	}
	var def := PluginDefinition.from_dict(d)
	if def != null:
		def.state = PluginDefinition.State.RUNNING
	return def


## Build a broker pre-wired with one plugin definition.
## Returns [broker, db, audit, mgr].
func _make_broker_with_plugin(
		plugin_id: String,
		panel_names: Array,
		ipc_messages: Array
) -> Array:
	var def := _make_def(plugin_id, panel_names, ipc_messages)

	var db := StubDB.new()
	if def != null:
		db.definitions[plugin_id] = def

	var mgr := StubManager.new()
	mgr._db = db

	var audit := StubAuditLog.new()

	var broker := PluginScenePanelBroker.new(
		mgr,
		null,
		null,
		audit as PluginAuditLog
	)

	return [broker, db, audit, mgr]


# ===========================================================================
# Tests
# ===========================================================================

func test_push_progress_registered_panel() -> void:
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var panel_root := StubSceneWithProgress.new()
	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	var pushed := broker.push_progress("cad", "cad_viewer", "req_00001", "tessellate", 0.5)

	check("push_progress returns true for live panel with on_progress", pushed)
	check("on_progress was called on scene root", panel_root.progress_calls.size() == 1)
	check("audit: scene_progress emitted",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS))

	panel_root.free()


func test_push_progress_unregistered_panel() -> void:
	var parts := _make_broker_with_plugin("cad", [], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var pushed := broker.push_progress("cad", "nonexistent_panel", "req_00002", "parse", 0.1)

	check("push_progress returns false for unregistered panel", not pushed)
	check("audit: scene_progress_miss emitted",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS_MISS))
	var miss_ev := audit.last_event_of_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS_MISS)
	check("miss reason is not_registered",
		miss_ev.get("detail", {}).get("reason", "") == "not_registered")


func test_push_progress_wrong_owner() -> void:
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var panel_root := StubSceneWithProgress.new()
	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	# "impostor_plugin" tries to push progress to a panel it doesn't own.
	var pushed := broker.push_progress("impostor_plugin", "cad_viewer", "req_00003", "export", 0.9)

	check("push_progress returns false for mismatched plugin_id", not pushed)
	check("audit: scene_denied emitted for mismatch",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_ev := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is progress_plugin_mismatch",
		denied_ev.get("detail", {}).get("reason", "") == "progress_plugin_mismatch")
	check("on_progress was NOT called", panel_root.progress_calls.is_empty())

	panel_root.free()


func test_push_progress_no_on_progress_method() -> void:
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	# Scene that does NOT implement on_progress.
	var panel_root := StubSceneNoProgress.new()
	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	var pushed := broker.push_progress("cad", "cad_viewer", "req_00004", "validate", 0.3)

	check("push_progress returns false when scene lacks on_progress", not pushed)
	check("audit: scene_progress_miss emitted",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS_MISS))
	var miss_ev := audit.last_event_of_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS_MISS)
	check("miss reason is progress_unsupported",
		miss_ev.get("detail", {}).get("reason", "") == "progress_unsupported")

	panel_root.free()


func test_push_progress_data_passthrough() -> void:
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	var panel_root := StubSceneWithProgress.new()
	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	# Use boundary-ish fraction values and verify they arrive unchanged.
	broker.push_progress("cad", "cad_viewer", "req_xyz", "translate", 0.0)
	broker.push_progress("cad", "cad_viewer", "req_xyz", "tessellate", 1.0)
	broker.push_progress("cad", "cad_viewer", "req_xyz", "export", 0.42)

	check("three on_progress calls recorded", panel_root.progress_calls.size() == 3)

	# fraction = 0.0 call
	check("fraction 0.0 passes through",
		panel_root.progress_calls[0].get("fraction", -1.0) == 0.0)
	check("phase 'translate' passes through",
		panel_root.progress_calls[0].get("phase", "") == "translate")

	# fraction = 1.0 call
	check("fraction 1.0 passes through",
		panel_root.progress_calls[1].get("fraction", -1.0) == 1.0)
	check("phase 'tessellate' passes through",
		panel_root.progress_calls[1].get("phase", "") == "tessellate")

	# fraction = 0.42 call
	check("fraction 0.42 passes through (approx)",
		absf(panel_root.progress_calls[2].get("fraction", -1.0) - 0.42) < 1e-6)

	# request_id passes through unchanged
	check("request_id passes through on all calls",
		panel_root.progress_calls[0].get("request_id", "") == "req_xyz" and
		panel_root.progress_calls[2].get("request_id", "") == "req_xyz")

	panel_root.free()


func test_push_progress_multiple_request_ids() -> void:
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var panel_root := StubSceneWithProgress.new()
	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	# Interleave progress notifications for two different request ids.
	broker.push_progress("cad", "cad_viewer", "req_A", "parse", 0.25)
	broker.push_progress("cad", "cad_viewer", "req_B", "parse", 0.10)
	broker.push_progress("cad", "cad_viewer", "req_A", "tessellate", 0.75)
	broker.push_progress("cad", "cad_viewer", "req_B", "tessellate", 0.50)

	check("four on_progress calls recorded", panel_root.progress_calls.size() == 4)

	# Verify each call preserved its own request_id independently.
	check("call 0 belongs to req_A",
		panel_root.progress_calls[0].get("request_id", "") == "req_A")
	check("call 1 belongs to req_B",
		panel_root.progress_calls[1].get("request_id", "") == "req_B")
	check("call 2 belongs to req_A",
		panel_root.progress_calls[2].get("request_id", "") == "req_A")
	check("call 3 belongs to req_B",
		panel_root.progress_calls[3].get("request_id", "") == "req_B")

	# Verify fractions are not cross-contaminated.
	check("req_A first fraction is 0.25",
		absf(panel_root.progress_calls[0].get("fraction", -1.0) - 0.25) < 1e-6)
	check("req_B first fraction is 0.10",
		absf(panel_root.progress_calls[1].get("fraction", -1.0) - 0.10) < 1e-6)

	# Each call should produce a scene_progress audit event (4 total).
	check("four scene_progress audit events",
		audit.events_of_type(PluginScenePanelBroker.EVENT_SCENE_PROGRESS).size() == 4)

	panel_root.free()


# ===========================================================================
# Shared helpers
# ===========================================================================

func _find_event(events: Array, event_type: String) -> Dictionary:
	for e in events:
		if e.get("event_type", "") == event_type:
			return e
	return {}
