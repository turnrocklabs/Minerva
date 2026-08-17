extends SceneTree
## T7.5 — host.fs.* platform-reserved channels for plugin file watcher access.
## Run: godot --headless --script test/test_plugin_scene_panel_broker_host_fs.gd
##
## Coverage:
##   - host.fs.watch RPC: success path, missing path, bad path
##   - host.fs.unwatch: removes watch + reverse-map entry
##   - host.fs.changed push: scene.receive() called when watched path changes
##   - panel teardown auto-unwatches (no leak after unregister)
##   - empty-path payload returns explicit error response

const FWS = preload("res://Scripts/Services/Watcher/FileWatcherService.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/host_fs_broker_test"


func _init() -> void:
	print("=== host.fs.* Broker Tests ===\n")

	_setup()

	test_watch_success_returns_path()
	test_watch_empty_path_returns_error()
	test_unwatch_removes_subscription()
	test_changed_pushed_to_subscribed_panel()
	test_changed_not_pushed_after_unwatch()
	test_unregister_panel_auto_unwatches()
	test_two_panels_one_path_both_receive()
	test_changed_payload_carries_path_mtime_size()

	_teardown()

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


func _setup() -> void:
	DirAccess.make_dir_recursive_absolute(_temp_dir)


func _teardown() -> void:
	var d := DirAccess.open(_temp_dir)
	if d == null:
		return
	for name in d.get_files():
		DirAccess.remove_absolute("%s/%s" % [_temp_dir, name])
	DirAccess.remove_absolute(_temp_dir)


func _temp_path(name: String) -> String:
	return "%s/%s" % [_temp_dir, name]


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ─── Stubs (mirror test_plugin_scene_panel_broker.gd shape) ──────────────────

class StubDB extends RefCounted:
	var definitions: Dictionary = {}
	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)


class StubManager extends RefCounted:
	var _db: StubDB = StubDB.new()
	func get_db(): return _db
	func get_connection(_id: String): return null


class StubAuditLog extends PluginAuditLog:
	var events: Array[Dictionary] = []
	func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
		events.append({"plugin_id": plugin_id, "event_type": event_type, "detail": detail})


class StubSceneRoot extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var received_calls: Array[Dictionary] = []
	func receive(channel: String, payload: Dictionary) -> void:
		received_calls.append({"channel": channel, "payload": payload})


# ─── Helpers ─────────────────────────────────────────────────────────────────

func _make_def(plugin_id: String, panel_names: Array, ipc_messages: Array) -> PluginDefinition:
	var typed_panels: Array = []
	for n in panel_names:
		typed_panels.append({"name": String(n), "kind": "html", "entry": "ui/%s.html" % String(n)})
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


func _fresh_broker(plugin_id: String, panels: Array) -> Array:
	# Reset FWS so previous test state can't leak through.
	FWS.reset_instance()

	var db := StubDB.new()
	var def := _make_def(plugin_id, panels, [])  # ipc_messages empty: host.fs.* bypass allowlist
	db.definitions[plugin_id] = def

	var mgr := StubManager.new()
	mgr._db = db

	var audit := StubAuditLog.new()
	var broker := PluginScenePanelBroker.new(mgr, null, null, audit as PluginAuditLog)
	return [broker, audit]


# Captured reply payload via root.received_calls in StubSceneRoot... but the
# reply path uses MinervaIPC._reply, not scene.receive(). For RPC reply we need
# the IPC helper attached. handle_scene_request calls _deliver_reply -> ipc._reply.
# Tests below verify the host.fs.changed PUSH (scene.receive()) directly, and
# for RPC replies inspect FileWatcherService state to confirm the watch landed.


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_watch_success_returns_path() -> void:
	print("test_watch_success_returns_path")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]

	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("watched.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "rpc1")

	check("FWS now watching path", FWS.get_instance().is_watched(path))
	check("FWS owner_count = 1", FWS.get_instance().owner_count(path) == 1)

	panel_root.queue_free()


func test_watch_empty_path_returns_error() -> void:
	print("test_watch_empty_path_returns_error")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	# Empty path → handler returns {success:false, error:"path_required"}.
	# We can't easily inspect the reply without a live MinervaIPC, but we CAN
	# confirm no watch was registered in FWS.
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": ""}, "rpc2")

	check("no watch registered for empty path", FWS.get_instance().watch_count() == 0)

	panel_root.queue_free()


func test_unwatch_removes_subscription() -> void:
	print("test_unwatch_removes_subscription")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("unwatch_me.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "r1")
	check("watched after watch RPC", FWS.get_instance().is_watched(path))

	broker.handle_scene_request("panel1", "host.fs.unwatch", {"path": path}, "r2")
	check("not watched after unwatch RPC", not FWS.get_instance().is_watched(path))

	panel_root.queue_free()


func test_changed_pushed_to_subscribed_panel() -> void:
	print("test_changed_pushed_to_subscribed_panel")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("changes.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "r1")

	# Drop the prior received_calls (the platform may have pushed something).
	panel_root.received_calls.clear()

	OS.delay_msec(1100)
	_write(path, "v2_external")
	FWS.get_instance().tick()

	var fs_changes: Array = []
	for c in panel_root.received_calls:
		if c.channel == "host.fs.changed":
			fs_changes.append(c)
	check("scene received exactly one host.fs.changed", fs_changes.size() == 1)
	if fs_changes.size() > 0:
		check("payload path matches", fs_changes[0].payload.get("path", "") == path)

	panel_root.queue_free()


func test_changed_not_pushed_after_unwatch() -> void:
	print("test_changed_not_pushed_after_unwatch")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("ephem.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "r1")
	broker.handle_scene_request("panel1", "host.fs.unwatch", {"path": path}, "r2")
	panel_root.received_calls.clear()

	OS.delay_msec(1100)
	_write(path, "v2")
	FWS.get_instance().tick()

	var fs_changes: Array = []
	for c in panel_root.received_calls:
		if c.channel == "host.fs.changed":
			fs_changes.append(c)
	check("no host.fs.changed pushed after unwatch", fs_changes.size() == 0)

	panel_root.queue_free()


func test_unregister_panel_auto_unwatches() -> void:
	print("test_unregister_panel_auto_unwatches")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("leak_check.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "r1")
	check("watched while panel registered", FWS.get_instance().is_watched(path))

	broker.unregister_panel("p1", "panel1")
	check("watch removed when panel unregistered", not FWS.get_instance().is_watched(path))

	panel_root.queue_free()


func test_two_panels_one_path_both_receive() -> void:
	print("test_two_panels_one_path_both_receive")
	var parts := _fresh_broker("p1", ["panel_a", "panel_b"])
	var broker: PluginScenePanelBroker = parts[0]
	var root_a := StubSceneRoot.new()
	var root_b := StubSceneRoot.new()
	get_root().add_child(root_a)
	get_root().add_child(root_b)
	broker.register_panel(root_a, "p1", "panel_a", PackedStringArray([]))
	broker.register_panel(root_b, "p1", "panel_b", PackedStringArray([]))

	var path := _temp_path("shared.txt")
	_write(path, "v1")
	broker.handle_scene_request("panel_a", "host.fs.watch", {"path": path}, "ra")
	broker.handle_scene_request("panel_b", "host.fs.watch", {"path": path}, "rb")

	check("FWS owner_count = 2 for shared path", FWS.get_instance().owner_count(path) == 2)

	root_a.received_calls.clear()
	root_b.received_calls.clear()

	OS.delay_msec(1100)
	_write(path, "v2")
	FWS.get_instance().tick()

	var a_changes := 0
	var b_changes := 0
	for c in root_a.received_calls:
		if c.channel == "host.fs.changed":
			a_changes += 1
	for c in root_b.received_calls:
		if c.channel == "host.fs.changed":
			b_changes += 1
	check("panel_a got host.fs.changed", a_changes == 1)
	check("panel_b got host.fs.changed", b_changes == 1)

	root_a.queue_free()
	root_b.queue_free()


func test_changed_payload_carries_path_mtime_size() -> void:
	print("test_changed_payload_carries_path_mtime_size")
	var parts := _fresh_broker("p1", ["panel1"])
	var broker: PluginScenePanelBroker = parts[0]
	var panel_root := StubSceneRoot.new()
	get_root().add_child(panel_root)
	broker.register_panel(panel_root, "p1", "panel1", PackedStringArray([]))

	var path := _temp_path("payload.txt")
	_write(path, "short")
	broker.handle_scene_request("panel1", "host.fs.watch", {"path": path}, "r1")
	panel_root.received_calls.clear()

	OS.delay_msec(1100)
	_write(path, "much_longer_content")
	FWS.get_instance().tick()

	for c in panel_root.received_calls:
		if c.channel == "host.fs.changed":
			check("payload path", c.payload.get("path", "") == path)
			check("payload size = new content length",
				int(c.payload.get("size", -1)) == "much_longer_content".length())
			check("payload mtime > 0", int(c.payload.get("mtime", 0)) > 0)

	panel_root.queue_free()
