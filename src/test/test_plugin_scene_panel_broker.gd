extends SceneTree
## Unit tests for PluginScenePanelBroker and MinervaIPC (synchronous paths).
##
## Run: godot --headless --script test/test_plugin_scene_panel_broker.gd
##
## Coverage:
##   PluginScenePanelBroker:
##     - register_panel: basic registration, duplicate, bad args
##     - unregister_panel / unregister_plugin_panels
##     - is_panel_registered / get_panel_owner
##     - handle_scene_request validation (all denial paths)
##     - push_to_panel: live panel, not-registered, wrong owner, no-receive
##     - Audit events emitted on allow/deny/push
##     - panel_registered / panel_unregistered signals
##
##   MinervaIPC:
##     - _reply with no pending awaiter (stale) → logs and drops
##     - _reply with empty reply_id → logs and drops
##     - Multiple _pending entries are independent
##
## NOT covered here (requires full SceneTree + async loop):
##   - await_reply timeout path (needs SceneTreeTimer)
##   - await_reply success path (needs coroutine resume)
##   These are exercised by integration tests in PluginScenePanelHost's test harness.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginScenePanelBroker + MinervaIPC Unit Tests ===\n")

	# --- MinervaIPC synchronous paths ---
	print("-- MinervaIPC: synchronous paths --")
	test_ipc_stale_reply_is_dropped()
	test_ipc_empty_reply_id_is_dropped()
	test_ipc_reply_fires_for_pending()
	test_ipc_pending_ids_are_independent()

	# --- Broker: registration ---
	print("\n-- PluginScenePanelBroker: registration --")
	test_register_panel_basic()
	test_register_panel_attaches_ipc_helper()
	test_register_panel_emits_signal()
	test_register_panel_bad_args()
	test_register_panel_duplicate_same_owner()
	test_register_panel_duplicate_different_owner()

	# --- Broker: unregistration ---
	print("\n-- PluginScenePanelBroker: unregistration --")
	test_unregister_panel()
	test_unregister_panel_unknown()
	test_unregister_panel_wrong_owner()
	test_unregister_plugin_panels()
	test_unregister_plugin_panels_empty()

	# --- Broker: queries ---
	print("\n-- PluginScenePanelBroker: queries --")
	test_is_panel_registered()
	test_get_panel_owner()

	# --- Broker: handle_scene_request validation ---
	print("\n-- PluginScenePanelBroker: handle_scene_request validation --")
	test_request_panel_not_registered()
	test_request_channel_not_in_panel_scope()
	test_request_channel_not_declared_in_manifest()
	test_request_payload_too_large()
	test_request_audit_allowed_event()
	test_request_panel_ownership_mismatch()

	# --- Broker: push_to_panel ---
	print("\n-- PluginScenePanelBroker: push_to_panel --")
	test_push_panel_not_registered()
	test_push_panel_wrong_owner()
	test_push_panel_live_no_receive_method()
	test_push_panel_live_with_receive()

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
# Test helpers / stubs
# ===========================================================================

## PluginDB stub: returns pre-registered PluginDefinition objects.
class StubDB extends RefCounted:
	var definitions: Dictionary = {}   # id -> PluginDefinition

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)


## PluginManager stub.
class StubManager extends RefCounted:
	var _db: StubDB = StubDB.new()

	func get_db():  # -> StubDB (duck-typed as PluginDB)
		return _db

	func get_connection(_id: String):  # -> null (no live connection in tests)
		return null


## Build a PluginDefinition with the given panels and ipc_messages.
## Uses from_dict to avoid the validation path that requires entrypoint/version.
func _make_def(plugin_id: String, panel_names: Array, ipc_messages: Array) -> PluginDefinition:
	# Build a minimal dict that bypasses the validate() call.
	# We use _from_dict_internal-equivalent manually since from_dict does not
	# call validate(). from_dict is the right path here.
	var d := {
		"id": plugin_id,
		"name": plugin_id,
		"version": "0.0.1",
		"host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "stub.py", "args": [], "working_dir": ""},
		"ui": {"panels": panel_names, "ipc_messages": ipc_messages},
		"tools": [],
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"data_directory": "/tmp/stub_plugin",
		"autostart": false,
		"auto_reload": false,
	}
	var def := PluginDefinition.from_dict(d)
	# Force to RUNNING state so dispatch validation doesn't fail on state.
	if def != null:
		def.state = PluginDefinition.State.RUNNING
	return def


## CapabilityBroker stub (never called in validation-failure tests).
class StubCapabilityBroker extends RefCounted:
	var last_dispatch: Dictionary = {}

	func dispatch(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
		last_dispatch = {"plugin_id": plugin_id, "capability": capability, "args": args}
		return PluginErrors.success({"stub": true})


## PluginAuditLog stub: captures events.
class StubAuditLog extends PluginAuditLog:
	var events: Array[Dictionary] = []

	func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
		events.append({"plugin_id": plugin_id, "event_type": event_type, "detail": detail})

	func last_event_type() -> String:
		if events.is_empty():
			return ""
		return events[-1]["event_type"]

	func has_event_type(t: String) -> bool:
		for e in events:
			if e["event_type"] == t:
				return true
		return false


## Scene root stub: a bare Control with a `request` signal and `receive` method.
class StubSceneRoot extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var received_calls: Array[Dictionary] = []

	func receive(channel: String, payload: Dictionary) -> void:
		received_calls.append({"channel": channel, "payload": payload})


## Scene root stub without a `receive` method (tests the missing-method path).
class StubSceneRootNoReceive extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)


## Build a broker pre-wired with one plugin definition.
## Returns [broker, stub_db, stub_audit, stub_mgr].
func _make_broker_with_plugin(
		plugin_id: String,
		panel_names: Array,
		ipc_messages: Array
) -> Array:
	var def := _make_def(plugin_id, panel_names, ipc_messages)
	if def == null:
		push_error("_make_broker_with_plugin: failed to create PluginDefinition for '%s'" % plugin_id)

	var db := StubDB.new()
	if def != null:
		db.definitions[plugin_id] = def

	var mgr := StubManager.new()
	mgr._db = db

	var audit := StubAuditLog.new()

	# plugin_manager is untyped Variant on the broker (duck-typing escape hatch);
	# StubManager satisfies the interface via matching method signatures.
	var broker := PluginScenePanelBroker.new(
		mgr,    # duck-typed stub; broker calls get_db() and get_connection()
		null,   # no policy needed for these tests
		null,   # no capability broker needed for most tests
		audit as PluginAuditLog
	)

	return [broker, db, audit, mgr]


# ===========================================================================
# MinervaIPC synchronous path tests
# ===========================================================================

func test_ipc_stale_reply_is_dropped() -> void:
	print("test_ipc_stale_reply_is_dropped:")
	var ipc := MinervaIPC.new()
	# _reply on a reply_id with no pending awaiter should not crash and should
	# not add anything to _pending.
	ipc._reply("unknown-id", {"success": true, "result": {}})
	check("stale reply does not add to _pending", not ipc._pending.has("unknown-id"))
	ipc.free()


func test_ipc_empty_reply_id_is_dropped() -> void:
	print("test_ipc_empty_reply_id_is_dropped:")
	var ipc := MinervaIPC.new()
	# Should not crash, no state change.
	ipc._reply("", {"success": true, "result": {}})
	check("empty reply_id leaves _pending empty", ipc._pending.is_empty())
	ipc.free()


func test_ipc_reply_fires_for_pending() -> void:
	print("test_ipc_reply_fires_for_pending:")
	var ipc := MinervaIPC.new()
	# Manually insert an observer into _pending (simulates what await_reply does
	# before the coroutine yields).
	var observer := MinervaIPC._ReplyObserver.new()
	ipc._pending["test-id-1"] = observer

	var fired := false
	var fired_result: Dictionary = {}
	observer.resolved.connect(func(r: Dictionary) -> void:
		fired = true
		fired_result = r
	)

	ipc._reply("test-id-1", {"success": true, "result": {"x": 42}})

	check("reply fires observer for registered reply_id", fired)
	check("result is passed through correctly", fired_result.get("success", false) == true)
	check("result.result has expected data", fired_result.get("result", {}).get("x", 0) == 42)
	ipc.free()


func test_ipc_pending_ids_are_independent() -> void:
	print("test_ipc_pending_ids_are_independent:")
	var ipc := MinervaIPC.new()

	var obs_a := MinervaIPC._ReplyObserver.new()
	var obs_b := MinervaIPC._ReplyObserver.new()
	ipc._pending["id-a"] = obs_a
	ipc._pending["id-b"] = obs_b

	var fired_a := false
	var fired_b := false
	obs_a.resolved.connect(func(_r: Dictionary) -> void: fired_a = true)
	obs_b.resolved.connect(func(_r: Dictionary) -> void: fired_b = true)

	# Only fire reply for id-b.
	ipc._reply("id-b", {"success": false, "error_code": "test"})

	check("only obs_b fired", fired_b)
	check("obs_a not fired by id-b reply", not fired_a)
	check("id-a still in _pending after id-b reply", ipc._pending.has("id-a"))
	ipc.free()


# ===========================================================================
# Broker: registration tests
# ===========================================================================

func test_register_panel_basic() -> void:
	print("test_register_panel_basic:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	check("panel is registered after register_panel", broker.is_panel_registered("cad_viewer"))
	check("panel owner is correct", broker.get_panel_owner("cad_viewer") == "cad")
	root.free()


func test_register_panel_attaches_ipc_helper() -> void:
	print("test_register_panel_attaches_ipc_helper:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	var helper := root.get_node_or_null(MinervaIPC.HELPER_NODE_NAME)
	check("$_MinervaIPC node is attached to scene root", helper != null)
	check("attached node is a MinervaIPC", helper is MinervaIPC)
	root.free()


func test_register_panel_emits_signal() -> void:
	print("test_register_panel_emits_signal:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]

	var emitted_pid := ""
	var emitted_pname := ""
	broker.panel_registered.connect(func(pid: String, pname: String) -> void:
		emitted_pid = pid
		emitted_pname = pname
	)

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())

	check("panel_registered emits plugin_id", emitted_pid == "cad")
	check("panel_registered emits panel_name", emitted_pname == "cad_viewer")
	root.free()


func test_register_panel_bad_args() -> void:
	print("test_register_panel_bad_args:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	# Null root.
	broker.register_panel(null, "cad", "cad_viewer", PackedStringArray())
	check("null root: panel not registered", not broker.is_panel_registered("cad_viewer"))

	# Empty plugin_id.
	var root := StubSceneRoot.new()
	broker.register_panel(root, "", "cad_viewer", PackedStringArray())
	check("empty plugin_id: panel not registered", not broker.is_panel_registered("cad_viewer"))

	# Empty panel_name.
	broker.register_panel(root, "cad", "", PackedStringArray())
	check("empty panel_name: not in registry (no key)", broker.get_panel_owner("") == "")
	root.free()


func test_register_panel_duplicate_same_owner() -> void:
	print("test_register_panel_duplicate_same_owner:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	var root1 := StubSceneRoot.new()
	var root2 := StubSceneRoot.new()

	broker.register_panel(root1, "cad", "cad_viewer", PackedStringArray())
	broker.register_panel(root2, "cad", "cad_viewer", PackedStringArray())

	# Second registration should succeed and re-assign.
	check("panel still registered after re-register", broker.is_panel_registered("cad_viewer"))
	check("owner unchanged on same-owner re-register", broker.get_panel_owner("cad_viewer") == "cad")
	# root2 should now have the helper. root1's helper was detached (removed_child
	# is synchronous; queue_free is deferred so we don't check is_instance_valid here).
	var helper2 := root2.get_node_or_null(MinervaIPC.HELPER_NODE_NAME)
	var helper1 := root1.get_node_or_null(MinervaIPC.HELPER_NODE_NAME)
	check("old root has no helper as child after re-register", helper1 == null)
	check("new root has helper after re-register", helper2 != null)
	root1.free()
	root2.free()


func test_register_panel_duplicate_different_owner() -> void:
	print("test_register_panel_duplicate_different_owner:")
	var parts := _make_broker_with_plugin("plugin_a", ["shared_panel"], [])
	var broker: PluginScenePanelBroker = parts[0]

	# Also add plugin_b to the db.
	var db: StubDB = parts[1]
	var def_b := _make_def("plugin_b", ["shared_panel"], [])
	if def_b != null:
		db.definitions["plugin_b"] = def_b

	var root1 := StubSceneRoot.new()
	var root2 := StubSceneRoot.new()

	broker.register_panel(root1, "plugin_a", "shared_panel", PackedStringArray())
	# Intentionally attempt to steal ownership.
	broker.register_panel(root2, "plugin_b", "shared_panel", PackedStringArray())

	# The broker logs a warning but re-assigns (last-writer-wins, with warning).
	check("panel still registered", broker.is_panel_registered("shared_panel"))
	check("owner is now plugin_b after re-register", broker.get_panel_owner("shared_panel") == "plugin_b")
	root1.free()
	root2.free()


# ===========================================================================
# Broker: unregistration tests
# ===========================================================================

func test_unregister_panel() -> void:
	print("test_unregister_panel:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	var emitted: Array[String] = []
	broker.panel_unregistered.connect(func(pid: String, _pn: String) -> void:
		emitted.append(pid)
	)

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())
	broker.unregister_panel("cad", "cad_viewer")

	check("panel is no longer registered", not broker.is_panel_registered("cad_viewer"))
	check("panel_unregistered signal emitted", "cad" in emitted)
	root.free()


func test_unregister_panel_unknown() -> void:
	print("test_unregister_panel_unknown:")
	var parts := _make_broker_with_plugin("cad", [], [])
	var broker: PluginScenePanelBroker = parts[0]

	# Should not crash when unregistering an unknown panel.
	broker.unregister_panel("cad", "nonexistent_panel")
	check("unregistering unknown panel does not crash", true)


func test_unregister_panel_wrong_owner() -> void:
	print("test_unregister_panel_wrong_owner:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())

	# Wrong owner should not remove the panel.
	broker.unregister_panel("wrong_plugin", "cad_viewer")
	check("panel still registered after wrong-owner unregister", broker.is_panel_registered("cad_viewer"))
	root.free()


func test_unregister_plugin_panels() -> void:
	print("test_unregister_plugin_panels:")
	var parts := _make_broker_with_plugin("cad", ["panel_a", "panel_b"], [])
	var broker: PluginScenePanelBroker = parts[0]

	var root_a := StubSceneRoot.new()
	var root_b := StubSceneRoot.new()
	broker.register_panel(root_a, "cad", "panel_a", PackedStringArray())
	broker.register_panel(root_b, "cad", "panel_b", PackedStringArray())

	broker.unregister_plugin_panels("cad")

	check("panel_a removed by unregister_plugin_panels", not broker.is_panel_registered("panel_a"))
	check("panel_b removed by unregister_plugin_panels", not broker.is_panel_registered("panel_b"))
	root_a.free()
	root_b.free()


func test_unregister_plugin_panels_empty() -> void:
	print("test_unregister_plugin_panels_empty:")
	var parts := _make_broker_with_plugin("cad", [], [])
	var broker: PluginScenePanelBroker = parts[0]

	# Should not crash when plugin has no registered panels.
	broker.unregister_plugin_panels("cad")
	check("unregistering empty plugin does not crash", true)


# ===========================================================================
# Broker: query tests
# ===========================================================================

func test_is_panel_registered() -> void:
	print("test_is_panel_registered:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	check("unregistered panel: is_panel_registered returns false",
		not broker.is_panel_registered("cad_viewer"))

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())
	check("registered panel: is_panel_registered returns true",
		broker.is_panel_registered("cad_viewer"))
	root.free()


func test_get_panel_owner() -> void:
	print("test_get_panel_owner:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]

	check("unknown panel: get_panel_owner returns empty string",
		broker.get_panel_owner("cad_viewer") == "")

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())
	check("registered panel: get_panel_owner returns correct plugin_id",
		broker.get_panel_owner("cad_viewer") == "cad")
	root.free()


# ===========================================================================
# Broker: handle_scene_request validation tests
# Note: handle_scene_request is async (uses await for dispatch), so we test
# the synchronous denial paths by calling it without awaiting.
# Denial decisions happen before any await point, so audit events fire
# synchronously within the same frame.
# ===========================================================================

func test_request_panel_not_registered() -> void:
	print("test_request_panel_not_registered:")
	var parts := _make_broker_with_plugin("cad", [], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	# Call without await — denial fires synchronously before any await point.
	broker.handle_scene_request("unknown_panel", "cad.render", {}, "reply-1")

	check("audit: scene_denied emitted for unregistered panel",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_event := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is panel_not_registered",
		denied_event.get("detail", {}).get("reason", "") == "panel_not_registered")


func test_request_channel_not_in_panel_scope() -> void:
	print("test_request_channel_not_in_panel_scope:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	# Panel declares only "cad.render" as its channels.
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	# Request with a channel NOT in the panel's declared channels.
	broker.handle_scene_request("cad_viewer", "cad.undeclared_channel", {}, "reply-2")

	check("audit: scene_denied emitted for undeclared channel",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_event := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is channel_not_in_panel_scope",
		denied_event.get("detail", {}).get("reason", "") == "channel_not_in_panel_scope")
	root.free()


func test_request_channel_not_declared_in_manifest() -> void:
	print("test_request_channel_not_declared_in_manifest:")
	# Panel declares "cad.render" in ipc_channels, but manifest ui_ipc_messages
	# does NOT include it — simulates a misconfigured manifest.
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	# ui_ipc_messages is empty: no channels declared at manifest level.
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	broker.handle_scene_request("cad_viewer", "cad.render", {}, "reply-3")

	check("audit: scene_denied for channel not in manifest ipc_messages",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_event := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is channel_not_declared",
		denied_event.get("detail", {}).get("reason", "") == "channel_not_declared")
	root.free()


func test_request_payload_too_large() -> void:
	print("test_request_payload_too_large:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	# Build a payload that exceeds 64 KiB when serialised.
	var big_payload := {"data": "x".repeat(PluginScenePanelBroker.MAX_PAYLOAD_BYTES + 1)}
	broker.handle_scene_request("cad_viewer", "cad.render", big_payload, "reply-4")

	check("audit: scene_denied for oversized payload",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_event := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is payload_too_large",
		denied_event.get("detail", {}).get("reason", "") == "payload_too_large")
	root.free()


func test_request_audit_allowed_event() -> void:
	print("test_request_audit_allowed_event:")
	# We can only test that the allowed audit event fires before the async dispatch.
	# The dispatch itself is async; we confirm the audit event fires synchronously.
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], ["cad.render"])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray(["cad.render"]))

	# A valid request with valid channel and small payload.
	# The async dispatch will fail (no running plugin), but the ALLOWED audit
	# event fires before the await point.
	broker.handle_scene_request("cad_viewer", "cad.render", {}, "reply-5")

	check("audit: scene_allowed emitted for valid request",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_ALLOWED))
	root.free()


func test_request_panel_ownership_mismatch() -> void:
	print("test_request_panel_ownership_mismatch:")
	# Simulate ownership mismatch: panel is registered for plugin_a but the
	# manifest for plugin_a doesn't include the panel name (post-registration).
	var parts := _make_broker_with_plugin("cad", [], ["cad.render"])
	# ui_panels is EMPTY: panel name won't be found in the manifest.
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	# We directly manipulate the registry to simulate a mismatch scenario:
	# register without manifest validation (bypass by inserting a raw entry).
	var root := StubSceneRoot.new()
	# Register normally — this will succeed registration because register_panel
	# doesn't check ui_panels at registration time (it checks at request time).
	broker.register_panel(root, "cad", "unlisted_panel", PackedStringArray(["cad.render"]))

	broker.handle_scene_request("unlisted_panel", "cad.render", {}, "reply-6")

	check("audit: scene_denied for panel not in manifest",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	var denied_event := _find_event(audit.events, PluginScenePanelBroker.EVENT_SCENE_DENIED)
	check("denial reason is panel_ownership_mismatch",
		denied_event.get("detail", {}).get("reason", "") == "panel_ownership_mismatch")
	root.free()


# ===========================================================================
# Broker: push_to_panel tests
# ===========================================================================

func test_push_panel_not_registered() -> void:
	print("test_push_panel_not_registered:")
	var parts := _make_broker_with_plugin("cad", [], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var pushed := broker.push_to_panel("cad", "nonexistent_panel", "cad.update", {})

	check("push_to_panel returns false for unregistered panel", not pushed)
	check("audit: scene_push_miss emitted",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PUSH_MISS))


func test_push_panel_wrong_owner() -> void:
	print("test_push_panel_wrong_owner:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())

	var pushed := broker.push_to_panel("different_plugin", "cad_viewer", "cad.update", {})

	check("push_to_panel returns false for wrong owner", not pushed)
	check("audit: scene_denied emitted for wrong-owner push",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	root.free()


func test_push_panel_live_no_receive_method() -> void:
	print("test_push_panel_live_no_receive_method:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRootNoReceive.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())

	var pushed := broker.push_to_panel("cad", "cad_viewer", "cad.update", {})

	check("push_to_panel returns false when no receive method", not pushed)
	check("audit: scene_push_miss emitted for missing receive",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PUSH_MISS))
	root.free()


func test_push_panel_live_with_receive() -> void:
	print("test_push_panel_live_with_receive:")
	var parts := _make_broker_with_plugin("cad", ["cad_viewer"], [])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[2]

	var root := StubSceneRoot.new()
	broker.register_panel(root, "cad", "cad_viewer", PackedStringArray())

	var test_payload := {"entity_id": "wall-001", "x": 100.0}
	var pushed := broker.push_to_panel("cad", "cad_viewer", "cad.update", test_payload)

	check("push_to_panel returns true for live panel with receive", pushed)
	check("audit: scene_push emitted", audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_PUSH))
	check("receive was called on scene root", root.received_calls.size() == 1)
	check("receive got correct channel", root.received_calls[0]["channel"] == "cad.update")
	check("receive got correct payload",
		root.received_calls[0]["payload"].get("entity_id", "") == "wall-001")
	root.free()


# ===========================================================================
# Shared helpers
# ===========================================================================

## Find the first event in the audit log matching the given event_type.
func _find_event(events: Array, event_type: String) -> Dictionary:
	for e in events:
		if e.get("event_type", "") == event_type:
			return e
	return {}
