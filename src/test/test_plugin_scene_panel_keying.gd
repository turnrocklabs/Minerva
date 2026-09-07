extends SceneTree
## The registry key is not the manifest panel name, and everything that used to
## conflate them must keep working.
##
## Run: godot --headless --script test/test_plugin_scene_panel_keying.gd
##      (registered in scripts/run-functional-tests.sh PCB_GUARD_TESTS, beside
##       the other PluginScenePanelBroker suites — `./scripts/run-functional-tests.sh
##       --pcb-guard`, and included in `--all`.)
##
## A panel is registered under a key that is unique per open editor tab, so two
## tabs on the same manifest panel each keep their own registration. Two things
## then stop being the same string, and each has a way to go wrong that no
## existing suite can see, because every other suite registers with the key set
## equal to the manifest name:
##
##   1. The outbound `request` path carries the KEY. The manifest declares the
##      NAME. Checking the key against the manifest denies every request a
##      plugin panel ever makes — total IPC failure, reported as
##      permission_denied. So the request path is driven here through the real
##      signal the broker wires, with a key that is deliberately not a manifest
##      panel name.
##
##   2. The blob store is written by the panel-state path (which holds the key)
##      and read by the host.documents.get_blob capability (which holds the
##      editor tab title). Two names for one panel means the blob is invisible
##      to the reader and its refcount never falls to zero — a silent leak.
##      Both halves are exercised against one store here.
##
## Everything below is the real broker. The plugin manager, audit log and scene
## root are stubs of the same shape the sibling broker suites use.

## A key of the shape Editor builds: the manifest name plus a per-tab suffix.
## It is deliberately NOT a name any manifest declares.
const PANEL_KEY := "cad_panel#40197"
const MANIFEST_PANEL := "cad_panel"
const CHANNEL := "cad.render"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginScenePanelBroker: per-tab key vs manifest name ===\n")
	await process_frame

	print("-- outbound IPC under a key that is not a manifest name --")
	await test_request_under_a_per_tab_key_is_allowed()
	await test_request_under_an_undeclared_manifest_name_is_still_denied()

	print("\n-- the blob store has one identity --")
	await test_blob_written_by_key_is_readable_by_tab_title()
	await test_blob_refcount_reaches_zero_across_both_names()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ===========================================================================
# 1. The request path carries the key; the manifest check needs the name
# ===========================================================================

## The regression this suite exists for: emit the panel's own `request` signal
## and let the broker's own wiring carry it. Whatever identity that wiring
## passes must still find "cad_panel" in the manifest, or every panel request
## is denied.
func test_request_under_a_per_tab_key_is_allowed() -> void:
	print("test_request_under_a_per_tab_key_is_allowed:")
	var parts := _make_broker([MANIFEST_PANEL], [CHANNEL])
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[1]

	var panel := StubSceneRoot.new()
	var editor := StubEditor.new("enclosure-rev4.mcad (1)", "/tmp/enclosure-rev4.mcad")
	broker.register_panel(panel, "cad", PANEL_KEY,
			PackedStringArray([CHANNEL]), MANIFEST_PANEL, editor)

	# The real outbound path: the panel emits, the broker's own deferred
	# trampoline delivers. Two frames so the deferred call runs.
	panel.request.emit(CHANNEL, {}, "reply-key-1")
	await process_frame
	await process_frame

	check("a request from a panel keyed per tab is allowed",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_ALLOWED))
	check("no denial was recorded for it",
		not audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED),
		"denials: %s" % str(audit.reasons()))

	var allowed := audit.first_event(PluginScenePanelBroker.EVENT_SCENE_ALLOWED)
	var detail: Dictionary = allowed.get("detail", {})
	check("the audit names the manifest panel",
		str(detail.get("panel_name", "")) == MANIFEST_PANEL,
		"panel_name = %s" % str(detail.get("panel_name", "")))
	check("the audit also names the registration it came from",
		str(detail.get("panel_key", "")) == PANEL_KEY,
		"panel_key = %s" % str(detail.get("panel_key", "")))

	panel.free()


## The control: the manifest check must still REFUSE a panel the manifest does
## not declare. Passing the manifest name straight through would be the lazy
## way to fix the case above, and it would make this one pass too — so a panel
## whose manifest name is genuinely absent is registered here and must be
## denied on exactly that reason.
func test_request_under_an_undeclared_manifest_name_is_still_denied() -> void:
	print("test_request_under_an_undeclared_manifest_name_is_still_denied:")
	var parts := _make_broker([], [CHANNEL])   # manifest declares NO panels
	var broker: PluginScenePanelBroker = parts[0]
	var audit: StubAuditLog = parts[1]

	var panel := StubSceneRoot.new()
	broker.register_panel(panel, "cad", "unlisted#7",
			PackedStringArray([CHANNEL]), "unlisted_panel")

	panel.request.emit(CHANNEL, {}, "reply-key-2")
	await process_frame
	await process_frame

	check("a panel the manifest never declared is still denied",
		audit.has_event_type(PluginScenePanelBroker.EVENT_SCENE_DENIED))
	check("and denied for the ownership reason, not something incidental",
		audit.reasons().has("panel_ownership_mismatch"),
		"reasons: %s" % str(audit.reasons()))

	panel.free()


# ===========================================================================
# 2. One blob store, reachable by either name for the panel
# ===========================================================================

## The panel-state path writes the store under the key it was called with; the
## capability path reads it under the editor tab title. Both must land on the
## same store.
func test_blob_written_by_key_is_readable_by_tab_title() -> void:
	print("test_blob_written_by_key_is_readable_by_tab_title:")
	var rig := await _blob_rig()
	if rig.is_empty():
		return
	var broker: PluginScenePanelBroker = rig["broker"]
	var handle: String = rig["handle"]
	var title: String = rig["title"]

	check("the panel's blob wrapper became a handle in the returned state",
		not handle.is_empty(),
		"state = %s" % str(rig["state"]))
	if handle.is_empty():
		_teardown_blob_rig(rig)
		return

	# What host.documents.get_blob does: it holds the tab title, nothing else.
	var by_title: Dictionary = broker._get_blob_record(title, handle)
	check("get_blob by the editor tab title finds the blob",
		by_title.get("found", false),
		"record = %s" % str(by_title))
	check("and finds the bytes the panel actually handed over",
		(by_title.get("bytes", PackedByteArray()) as PackedByteArray) == rig["bytes"])

	# And the key the panel-state path holds reaches the same record.
	var by_key: Dictionary = broker._get_blob_record(PANEL_KEY, handle)
	check("the registration key reaches the same record",
		by_key.get("found", false)
			and int(by_key.get("refcount", -1)) == int(by_title.get("refcount", -2)),
		"by_key = %s / by_title = %s" % [str(by_key), str(by_title)])

	_teardown_blob_rig(rig)


## A refcount split across two names never reaches zero, so the bytes are held
## for the life of the process. One decrement under the tab title — what
## patch_state does — must release a blob stored under the key.
func test_blob_refcount_reaches_zero_across_both_names() -> void:
	print("test_blob_refcount_reaches_zero_across_both_names:")
	var rig := await _blob_rig()
	if rig.is_empty():
		return
	var broker: PluginScenePanelBroker = rig["broker"]
	var handle: String = rig["handle"]
	var title: String = rig["title"]
	if handle.is_empty():
		check("blob rig produced a handle", false, "state = %s" % str(rig["state"]))
		_teardown_blob_rig(rig)
		return

	check("the blob starts held by the outbound envelope",
		int(broker._get_blob_record(PANEL_KEY, handle).get("refcount", 0)) == 1)

	# patch_state's commit: refcount deltas applied under the editor tab title.
	var released: bool = broker._dec_blob_refcount(title, handle)
	check("a decrement under the tab title is accepted", released)
	check("the blob is released rather than leaked",
		not broker._get_blob_record(PANEL_KEY, handle).get("found", false),
		"record = %s" % str(broker._get_blob_record(PANEL_KEY, handle)))

	_teardown_blob_rig(rig)


# ===========================================================================
# Test helpers / stubs
# ===========================================================================

## Ask the panel for its state the way host.documents.get_state does, with a
## panel that answers with one blob wrapper. Returns the rig plus the handle
## the broker substituted for it.
func _blob_rig() -> Dictionary:
	var parts := _make_broker([MANIFEST_PANEL], [CHANNEL])
	var broker: PluginScenePanelBroker = parts[0]

	var bytes := PackedByteArray([1, 2, 3, 4, 5])
	var panel := StubStatefulSceneRoot.new()
	panel.broker = broker
	panel.panel_key = PANEL_KEY
	panel.state = {
		"thumbnail": {"__blob__": true, "content_type": "image/png", "bytes": bytes},
	}
	var title := "enclosure-rev4.mcad (1)"
	var editor := StubEditor.new(title, "/tmp/enclosure-rev4.mcad")
	broker.register_panel(panel, "cad", PANEL_KEY,
			PackedStringArray([CHANNEL]), MANIFEST_PANEL, editor)

	# CapabilityBroker calls this with the panel KEY (Editor.plugin_panel_key).
	var reply: Dictionary = await broker.request_panel_state("cad", PANEL_KEY)
	check("the panel answered the state request", reply.get("success", false),
		"reply = %s" % str(reply))
	if not reply.get("success", false):
		panel.free()
		return {}

	var state: Dictionary = reply.get("state", {})
	var thumb: Variant = state.get("thumbnail", null)
	var handle: String = ""
	if thumb is Dictionary:
		handle = str((thumb as Dictionary).get("__blob_handle__", ""))

	return {
		"broker": broker,
		"panel": panel,
		"editor": editor,
		"title": title,
		"bytes": bytes,
		"state": state,
		"handle": handle,
	}


func _teardown_blob_rig(rig: Dictionary) -> void:
	var panel: Node = rig.get("panel", null)
	if panel != null and is_instance_valid(panel):
		panel.free()


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

	func first_event(t: String) -> Dictionary:
		for e in events:
			if e["event_type"] == t:
				return e
		return {}

	## Every denial reason recorded, for a failure message that says WHY.
	func reasons() -> Array:
		var out: Array = []
		for e in events:
			var reason: String = str((e.get("detail", {}) as Dictionary).get("reason", ""))
			if not reason.is_empty():
				out.append(reason)
		return out


## Stands in for Minerva's Editor wrapper: the broker reads only these two
## fields off it, at lookup time.
class StubEditor extends RefCounted:
	var tab_title: String = ""
	var file: String = ""

	func _init(p_title: String, p_file: String) -> void:
		tab_title = p_title
		file = p_file


## Scene root stub: a bare Control with a `request` signal and `receive`.
class StubSceneRoot extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var received_calls: Array[Dictionary] = []

	func receive(channel: String, payload: Dictionary) -> void:
		received_calls.append({"channel": channel, "payload": payload})


## Scene root that answers a host_owned_save get_request with a fixed state.
## It replies deferred, the way a real panel does: the broker is still on its
## way to `await awaiter.completed` when receive() returns, and a synchronous
## reply would resolve the awaiter before anyone is listening.
class StubStatefulSceneRoot extends StubSceneRoot:
	var broker: PluginScenePanelBroker = null
	var panel_key: String = ""
	var state: Dictionary = {}

	func receive(channel: String, payload: Dictionary) -> void:
		super.receive(channel, payload)
		if channel != PluginScenePanelBroker.CHANNEL_HOST_OWNED_SAVE_GET_REQUEST:
			return
		if broker == null:
			return
		broker.call_deferred("handle_scene_request", panel_key,
			PluginScenePanelBroker.CHANNEL_HOST_OWNED_SAVE_RESPONSE,
			{
				"request_id": str(payload.get("request_id", "")),
				"success": true,
				"state": state,
			},
			"")


## Build a PluginDefinition with the given panels and ipc_messages.
func _make_def(plugin_id: String, panel_names: Array, ipc_messages: Array) -> PluginDefinition:
	var typed_panels: Array = []
	for n in panel_names:
		typed_panels.append({
			"name": String(n),
			"kind": "html",
			"entry": "ui/%s.html" % String(n),
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


## Build a broker pre-wired with a "cad" plugin definition.
## Returns [broker, stub_audit].
func _make_broker(panel_names: Array, ipc_messages: Array) -> Array:
	var def := _make_def("cad", panel_names, ipc_messages)
	if def == null:
		push_error("_make_broker: failed to create PluginDefinition")

	var db := StubDB.new()
	if def != null:
		db.definitions["cad"] = def

	var mgr := StubManager.new()
	mgr._db = db

	var audit := StubAuditLog.new()
	var broker := PluginScenePanelBroker.new(
		mgr,    # duck-typed stub; broker calls get_db() and get_connection()
		null,   # no policy needed for these tests
		null,   # no capability broker needed here
		audit as PluginAuditLog
	)
	return [broker, audit]


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
