extends SceneTree
## Unit + integration tests for Phase 5 R3 blob substitution in
## PluginScenePanelBroker (outbound strip + inbound rehydrate).
##
## Run: godot --headless --path src --script test/test_panel_state_blob_substitution.gd
##
## Tracks docket: minerva 019e15965ef573458fd5ffd0dbe35182 (Phase 5)
##
## Coverage:
##   _strip_blobs_for_outbound:
##     - empty state passes through unchanged (noop)
##     - state with no blob wrappers passes through unchanged
##     - single {__blob__: true, content_type, bytes} at root replaced with handle
##     - nested blob in array replaced correctly
##     - multiple distinct blobs get distinct handles
##     - stored blob has refcount = 1
##   _rehydrate_blobs_for_inbound:
##     - unknown handle returns structured error with path
##     - partial failure is atomic (no partial state mutation visible)
##     - known handle round-trips bytes
##     - multi-handle state fully resolved
##   Round-trip:
##     - outbound strip then inbound rehydrate preserves state
##   Refcount lifecycle:
##     - strip stores at refcount 1
##     - rehydrate increments; apply_panel_state decrements after (net 0)
##     - failed rehydrate leaves refcounts unchanged

const PANEL_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const AUDIT_SCRIPT_PATH        := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_DB_SCRIPT_PATH    := "res://Scripts/Services/Plugins/PluginDB.gd"
const PLUGIN_DEF_SCRIPT_PATH   := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID  := "blob_sub_probe"
const TEST_PANEL_NAME := "blob_sub_panel"
const TEST_EDITOR     := TEST_PANEL_NAME  # panel_name == editor_name in broker

var _pass_count: int = 0
var _fail_count: int = 0
var _root: Node = null

var _PanelBroker = null
var _Audit       = null
var _DB          = null
var _Def         = null


func _init() -> void:
	print("=== Panel State Blob Substitution Tests (Phase 5 R3) ===\n")
	_root = Node.new()
	get_root().add_child(_root)

	_PanelBroker = load(PANEL_BROKER_SCRIPT_PATH)
	_Audit       = load(AUDIT_SCRIPT_PATH)
	_DB          = load(PLUGIN_DB_SCRIPT_PATH)
	_Def         = load(PLUGIN_DEF_SCRIPT_PATH)

	await _run_tests()

	_root.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_broker() -> Object:
	var audit = _Audit.new()
	return _PanelBroker.new(null, null, null, audit)


## Stub panel that echoes back a fixed canned_state on get-requests and
## acks set-requests, storing the received state for inspection.
class StubPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)
	var canned_state: Dictionary = {}
	var last_set_state: Dictionary = {}

	func receive(channel: String, payload: Dictionary) -> void:
		var request_id: String = str(payload.get("request_id", ""))
		if channel == "host_owned_save.get_request":
			request.emit("host_owned_save.response", {
				"request_id": request_id,
				"success": true,
				"state": canned_state.duplicate(true),
			}, "")
		elif channel == "host_owned_save.set_request":
			last_set_state = (payload.get("state", {}) as Dictionary).duplicate(true)
			request.emit("host_owned_save.response", {
				"request_id": request_id,
				"success": true,
			}, "")


class StubManager extends RefCounted:
	var db = null
	func get_db():
		return db


func _make_panel_broker_with_panel() -> Array:
	# Returns [panel_broker, stub_panel]
	var def = _Def.new(TEST_PLUGIN_ID)
	var ui_panels: Array[Dictionary] = [{
		"name": TEST_PANEL_NAME,
		"kind": "godot_scene",
		"entry_scene": "ui/Stub.tscn",
		"scripts": ["ui/stub.gd"],
	}]
	def.ui_panels = ui_panels
	var msgs: Array[String] = ["host_owned_save.response"]
	def.ui_ipc_messages = msgs

	var db = _DB.new()
	db._plugins[TEST_PLUGIN_ID] = def

	var mgr = StubManager.new()
	mgr.db = db

	var audit = _Audit.new()
	var broker = _PanelBroker.new(mgr, null, null, audit)

	var panel := StubPanel.new()
	_root.add_child(panel)
	var declared: PackedStringArray = ["host_owned_save.response"]
	broker.register_panel(panel, TEST_PLUGIN_ID, TEST_PANEL_NAME, declared)
	# Flush the call_deferred wiring from register_panel.
	await process_frame

	return [broker, panel]


func _find_packed_byte_arrays(value: Variant, path: String = "") -> Array[String]:
	## Recursively find paths where a PackedByteArray lives.
	## Used to assert outbound state has no raw bytes remaining.
	var found: Array[String] = []
	if value is PackedByteArray:
		found.append(path if not path.is_empty() else "/")
	elif value is Dictionary:
		for k in (value as Dictionary).keys():
			var sub := _find_packed_byte_arrays((value as Dictionary)[k], path + "/" + str(k))
			found.append_array(sub)
	elif value is Array:
		var arr := value as Array
		for i in arr.size():
			var sub := _find_packed_byte_arrays(arr[i], path + "/" + str(i))
			found.append_array(sub)
	return found


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		print(msg)


func check_eq(label: String, actual, expected) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

func _run_tests() -> void:
	_test_strip_empty_state_is_noop()
	_test_strip_state_without_blob_wrappers_unchanged()
	_test_strip_single_blob_at_root()
	_test_strip_nested_blob_in_array()
	_test_strip_multiple_blobs_distinct_handles()
	_test_strip_creates_blob_store_entry_with_refcount_1()
	_test_rehydrate_unknown_handle_returns_structured_error_with_path()
	_test_rehydrate_partial_failure_leaves_state_unchanged_atomically()
	_test_rehydrate_known_handle_round_trips_bytes()
	_test_rehydrate_multi_handle_state_all_resolved()
	await _test_outbound_then_inbound_round_trip_preserves_state()
	await _test_refcount_lifecycle_strip_sets_refcount_1()
	await _test_refcount_lifecycle_apply_inbound_net_zero()
	_test_refcount_failed_rehydrate_no_change()
	_test_strip_malformed_wrapper_passthrough()
	_test_rehydrate_no_handle_placeholders_passthrough()
	_test_rehydrate_error_path_escapes_rfc6901_reserved_chars()
	_test_strip_string_bytes_creates_handle_with_base64_encoding()
	_test_rehydrate_emits_string_when_stored_as_base64()
	_test_rehydrate_emits_pba_when_stored_as_bytes()
	_test_mixed_encoding_blobs_round_trip_independently()
	_test_blob_wrapper_survives_json_round_trip()


# ---------------------------------------------------------------------------
# _strip_blobs_for_outbound tests
# ---------------------------------------------------------------------------

func _test_strip_empty_state_is_noop() -> void:
	print("\n-- _test_strip_empty_state_is_noop --")
	var broker = _make_broker()
	var state: Dictionary = {}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("empty state returns empty dict", result is Dictionary)
	check_eq("empty state has no keys", (result as Dictionary).size(), 0)
	check_eq("blob store is empty after noop", broker._blob_store_snapshot(TEST_EDITOR).size(), 0)


func _test_strip_state_without_blob_wrappers_unchanged() -> void:
	print("\n-- _test_strip_state_without_blob_wrappers_unchanged --")
	var broker = _make_broker()
	var state: Dictionary = {
		"version": 1,
		"aspect": "16:9",
		"slides": [{"id": "s1", "title": "Hello", "tiles": []}],
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("result is Dictionary", result is Dictionary)
	var d := result as Dictionary
	check_eq("version preserved", int(d.get("version", 0)), 1)
	check_eq("aspect preserved", str(d.get("aspect", "")), "16:9")
	check_eq("slides preserved", (d.get("slides", []) as Array).size(), 1)
	check_eq("no blobs stored", broker._blob_store_snapshot(TEST_EDITOR).size(), 0)
	# No PackedByteArrays in output.
	check("no raw bytes in result", _find_packed_byte_arrays(result).is_empty())


func _test_strip_single_blob_at_root() -> void:
	print("\n-- _test_strip_single_blob_at_root --")
	var broker = _make_broker()
	var bytes := PackedByteArray([0x89, 0x50, 0x4e, 0x47])  # PNG magic
	var state: Dictionary = {
		"version": 1,
		"thumbnail": {"__blob__": true, "content_type": "image/png", "bytes": bytes},
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("result is Dictionary", result is Dictionary)
	var d := result as Dictionary
	check_eq("version preserved", int(d.get("version", 0)), 1)
	check("thumbnail is a dict", d.get("thumbnail") is Dictionary)
	var thumb := d["thumbnail"] as Dictionary
	check("thumbnail has __blob_handle__", thumb.has("__blob_handle__"))
	check("thumbnail has content_type", thumb.has("content_type"))
	check("thumbnail has no bytes", not thumb.has("bytes"))
	check_eq("content_type preserved", str(thumb.get("content_type", "")), "image/png")
	check("handle is non-empty string", not (thumb.get("__blob_handle__", "") as String).is_empty())
	check("no raw bytes anywhere in result", _find_packed_byte_arrays(result).is_empty())
	check_eq("one blob in store", broker._blob_store_snapshot(TEST_EDITOR).size(), 1)


func _test_strip_nested_blob_in_array() -> void:
	print("\n-- _test_strip_nested_blob_in_array --")
	var broker = _make_broker()
	var bytes := PackedByteArray([1, 2, 3, 4])
	var state: Dictionary = {
		"slides": [
			{
				"id": "s1",
				"tiles": [
					{"kind": "text", "text": "hello"},
					{"kind": "image", "__blob__": true, "content_type": "image/jpeg", "bytes": bytes},
				],
			},
		],
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	var slides := (result as Dictionary).get("slides", []) as Array
	check_eq("slides count", slides.size(), 1)
	var tiles := (slides[0] as Dictionary).get("tiles", []) as Array
	check_eq("tiles count", tiles.size(), 2)
	var text_tile := tiles[0] as Dictionary
	var img_tile  := tiles[1] as Dictionary
	check_eq("text tile kind preserved", str(text_tile.get("kind", "")), "text")
	check("img tile has handle", img_tile.has("__blob_handle__"))
	check("img tile has no bytes", not img_tile.has("bytes"))
	check_eq("img tile content_type", str(img_tile.get("content_type", "")), "image/jpeg")
	check("no raw bytes anywhere", _find_packed_byte_arrays(result).is_empty())


func _test_strip_multiple_blobs_distinct_handles() -> void:
	print("\n-- _test_strip_multiple_blobs_distinct_handles --")
	var broker = _make_broker()
	var b1 := PackedByteArray([1, 2])
	var b2 := PackedByteArray([3, 4])
	var b3 := PackedByteArray([5, 6])
	var state: Dictionary = {
		"a": {"__blob__": true, "content_type": "image/png", "bytes": b1},
		"b": {"__blob__": true, "content_type": "image/jpeg", "bytes": b2},
		"c": {"__blob__": true, "content_type": "image/webp", "bytes": b3},
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	var d := result as Dictionary
	var ha: String = (d["a"] as Dictionary).get("__blob_handle__", "")
	var hb: String = (d["b"] as Dictionary).get("__blob_handle__", "")
	var hc: String = (d["c"] as Dictionary).get("__blob_handle__", "")
	check("handle a non-empty", not ha.is_empty())
	check("handle b non-empty", not hb.is_empty())
	check("handle c non-empty", not hc.is_empty())
	check("handles are all distinct", ha != hb and hb != hc and ha != hc)
	check_eq("three blobs in store", broker._blob_store_snapshot(TEST_EDITOR).size(), 3)
	check("no raw bytes anywhere", _find_packed_byte_arrays(result).is_empty())


func _test_strip_creates_blob_store_entry_with_refcount_1() -> void:
	print("\n-- _test_strip_creates_blob_store_entry_with_refcount_1 --")
	var broker = _make_broker()
	var bytes := PackedByteArray([10, 20, 30])
	var state: Dictionary = {
		"img": {"__blob__": true, "content_type": "image/png", "bytes": bytes},
	}
	broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	var snap: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	check_eq("one entry in store", snap.size(), 1)
	var handle: String = snap.keys()[0]
	var entry: Dictionary = snap[handle]
	check_eq("refcount is 1", int(entry.get("refcount", 0)), 1)
	check_eq("content_type recorded", str(entry.get("content_type", "")), "image/png")


# ---------------------------------------------------------------------------
# _rehydrate_blobs_for_inbound tests
# ---------------------------------------------------------------------------

func _test_rehydrate_unknown_handle_returns_structured_error_with_path() -> void:
	print("\n-- _test_rehydrate_unknown_handle_returns_structured_error_with_path --")
	var broker = _make_broker()
	var state: Dictionary = {
		"slides": [
			{
				"tiles": [
					{"__blob_handle__": "blob-999", "content_type": "image/png"},
				],
			},
		],
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("result is failure", not result.get("success", true))
	check_eq("error_code is unknown_blob_handle",
		str(result.get("error_code", "")), "unknown_blob_handle")
	check_eq("handle echoed", str(result.get("handle", "")), "blob-999")
	var path: String = str(result.get("path", ""))
	check("path is non-empty", not path.is_empty())
	check("path contains slides", path.contains("slides"))
	check("path contains tiles", path.contains("tiles"))
	# Walk-path should end with …/0/__blob_handle__ or similar leading to the node.
	# We just require it's non-empty and mentions the problematic key location.
	print("    path reported: %s" % path)


func _test_rehydrate_partial_failure_leaves_state_unchanged_atomically() -> void:
	print("\n-- _test_rehydrate_partial_failure_leaves_state_unchanged_atomically --")
	var broker = _make_broker()
	# Store one real blob.
	var real_bytes := PackedByteArray([0xAB, 0xCD])
	var real_handle: String = broker._store_blob(TEST_EDITOR, real_bytes, "image/png")
	# Snapshot refcount before.
	var snap_before: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	var refcount_before: int = int((snap_before[real_handle] as Dictionary).get("refcount", 0))

	# Build state: one good handle + one unknown handle.
	var state: Dictionary = {
		"good_img": {"__blob_handle__": real_handle, "content_type": "image/png"},
		"bad_img":  {"__blob_handle__": "blob-999",  "content_type": "image/jpeg"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("result is failure", not result.get("success", true))
	check_eq("error_code", str(result.get("error_code", "")), "unknown_blob_handle")

	# Refcount must be back to what it was (atomic rollback).
	var snap_after: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	check("real handle still in store", snap_after.has(real_handle))
	var refcount_after: int = int((snap_after[real_handle] as Dictionary).get("refcount", 0))
	check_eq("refcount unchanged after atomic failure", refcount_after, refcount_before)


func _test_rehydrate_known_handle_round_trips_bytes() -> void:
	print("\n-- _test_rehydrate_known_handle_round_trips_bytes --")
	var broker = _make_broker()
	var original_bytes := PackedByteArray([0x10, 0x20, 0x30, 0x40])
	var handle: String = broker._store_blob(TEST_EDITOR, original_bytes, "image/png")

	var state: Dictionary = {
		"thumbnail": {"__blob_handle__": handle, "content_type": "image/png"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("rehydrate succeeded", result.get("success", false))
	var out_state: Dictionary = result.get("state", {})
	check("thumbnail present", out_state.has("thumbnail"))
	var thumb := out_state["thumbnail"] as Dictionary
	check("has __blob__", thumb.get("__blob__", false) == true or thumb.get("__blob__", 0.0) == 1.0)
	check_eq("content_type", str(thumb.get("content_type", "")), "image/png")
	check("bytes present", thumb.has("bytes"))
	var out_bytes: PackedByteArray = thumb["bytes"] as PackedByteArray
	check_eq("bytes length", out_bytes.size(), original_bytes.size())
	check("bytes equal", out_bytes == original_bytes)


func _test_rehydrate_multi_handle_state_all_resolved() -> void:
	print("\n-- _test_rehydrate_multi_handle_state_all_resolved --")
	var broker = _make_broker()
	var b1 := PackedByteArray([1, 2, 3])
	var b2 := PackedByteArray([4, 5, 6])
	var h1: String = broker._store_blob(TEST_EDITOR, b1, "image/png")
	var h2: String = broker._store_blob(TEST_EDITOR, b2, "image/jpeg")

	var state: Dictionary = {
		"slides": [
			{"img": {"__blob_handle__": h1, "content_type": "image/png"}},
			{"img": {"__blob_handle__": h2, "content_type": "image/jpeg"}},
		],
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("all resolved: success", result.get("success", false))
	var slides := (result.get("state", {}) as Dictionary).get("slides", []) as Array
	check_eq("slides count", slides.size(), 2)
	var img1 := (slides[0] as Dictionary).get("img", {}) as Dictionary
	var img2 := (slides[1] as Dictionary).get("img", {}) as Dictionary
	check("slide 0 img has bytes", img1.has("bytes"))
	check("slide 1 img has bytes", img2.has("bytes"))
	check("slide 0 bytes equal b1", (img1["bytes"] as PackedByteArray) == b1)
	check("slide 1 bytes equal b2", (img2["bytes"] as PackedByteArray) == b2)


# ---------------------------------------------------------------------------
# Round-trip test
# ---------------------------------------------------------------------------

func _test_outbound_then_inbound_round_trip_preserves_state() -> void:
	print("\n-- _test_outbound_then_inbound_round_trip_preserves_state --")
	var arr = await _make_panel_broker_with_panel()
	var broker = arr[0]
	var panel: StubPanel = arr[1]

	# Build panel state with a blob wrapper.
	var original_bytes := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF])
	var panel_state: Dictionary = {
		"version": 2,
		"aspect":  "4:3",
		"slides":  [
			{
				"id":   "slide_1",
				"title": "Round-trip test",
				"tiles": [
					{
						"kind": "image",
						"__blob__": true,
						"content_type": "image/png",
						"bytes": original_bytes,
					},
				],
			},
		],
	}
	panel.canned_state = panel_state

	# Outbound: request_panel_state strips blobs.
	var get_resp: Dictionary = await broker.request_panel_state(TEST_PLUGIN_ID, TEST_PANEL_NAME)
	check("get_state succeeded", get_resp.get("success", false))
	var stripped_state: Dictionary = get_resp.get("state", {})
	check("no raw bytes in outbound state", _find_packed_byte_arrays(stripped_state).is_empty())

	# Verify handle placeholder is in the stripped state.
	var slides_out := (stripped_state.get("slides", []) as Array)
	check_eq("slides in stripped state", slides_out.size(), 1)
	var tile_out := ((slides_out[0] as Dictionary).get("tiles", []) as Array)[0] as Dictionary
	check("tile has __blob_handle__", tile_out.has("__blob_handle__"))
	var handle: String = str(tile_out.get("__blob_handle__", ""))
	check("handle non-empty", not handle.is_empty())

	# Inbound: apply_panel_state rehydrates (uses stripped_state which has handle).
	var set_resp: Dictionary = await broker.apply_panel_state(
		TEST_PLUGIN_ID, TEST_PANEL_NAME, stripped_state)
	check("set_state succeeded", set_resp.get("success", false))

	# The panel received the rehydrated state with bytes back.
	var received := panel.last_set_state
	var slides_in := received.get("slides", []) as Array
	check_eq("panel got slides", slides_in.size(), 1)
	var tile_in := ((slides_in[0] as Dictionary).get("tiles", []) as Array)[0] as Dictionary
	check("rehydrated tile has bytes", tile_in.has("bytes"))
	var received_bytes: PackedByteArray = tile_in["bytes"] as PackedByteArray
	check("bytes round-trip equal", received_bytes == original_bytes)
	check_eq("aspect round-tripped",
		str(received.get("aspect", "")), "4:3")
	check_eq("version round-tripped", int(received.get("version", 0)), 2)


# ---------------------------------------------------------------------------
# Refcount lifecycle tests
# ---------------------------------------------------------------------------

func _test_refcount_lifecycle_strip_sets_refcount_1() -> void:
	print("\n-- _test_refcount_lifecycle_strip_sets_refcount_1 --")
	var arr = await _make_panel_broker_with_panel()
	var broker = arr[0]
	var panel: StubPanel = arr[1]

	var bytes := PackedByteArray([0xAA, 0xBB])
	panel.canned_state = {
		"img": {"__blob__": true, "content_type": "image/png", "bytes": bytes},
	}

	var resp: Dictionary = await broker.request_panel_state(TEST_PLUGIN_ID, TEST_PANEL_NAME)
	check("get succeeded", resp.get("success", false))

	var snap: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	check_eq("one blob stored", snap.size(), 1)
	var handle: String = snap.keys()[0]
	check_eq("refcount after strip = 1",
		int((snap[handle] as Dictionary).get("refcount", 0)), 1)


func _test_refcount_lifecycle_apply_inbound_net_zero() -> void:
	print("\n-- _test_refcount_lifecycle_apply_inbound_net_zero --")
	var arr = await _make_panel_broker_with_panel()
	var broker = arr[0]

	# Pre-store a blob (refcount = 1).
	var bytes := PackedByteArray([0x11, 0x22, 0x33])
	var handle: String = broker._store_blob(TEST_EDITOR, bytes, "image/png")

	# Snapshot before apply.
	var snap_before: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	var rc_before: int = int((snap_before[handle] as Dictionary).get("refcount", 0))
	check_eq("refcount before apply = 1", rc_before, 1)

	# Apply state containing the handle — rehydrate +1, then apply_panel_state -1.
	var state_with_handle: Dictionary = {
		"img": {"__blob_handle__": handle, "content_type": "image/png"},
	}
	var set_resp: Dictionary = await broker.apply_panel_state(
		TEST_PLUGIN_ID, TEST_PANEL_NAME, state_with_handle)
	check("apply succeeded", set_resp.get("success", false))

	# Net change: +1 during rehydrate, -1 after apply → refcount back to 1.
	var snap_after: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	check("handle still in store after apply", snap_after.has(handle))
	var rc_after: int = int((snap_after[handle] as Dictionary).get("refcount", 0))
	check_eq("refcount net zero after apply", rc_after, rc_before)


func _test_refcount_failed_rehydrate_no_change() -> void:
	print("\n-- _test_refcount_failed_rehydrate_no_change --")
	var broker = _make_broker()
	var bytes := PackedByteArray([0xFF, 0xFE])
	var good_handle: String = broker._store_blob(TEST_EDITOR, bytes, "image/png")

	var snap_before: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	var rc_before: int = int((snap_before[good_handle] as Dictionary).get("refcount", 0))

	# State has one good + one unknown handle.
	var state: Dictionary = {
		"a": {"__blob_handle__": good_handle,  "content_type": "image/png"},
		"b": {"__blob_handle__": "blob-never",  "content_type": "image/jpeg"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("failed rehydrate: success=false", not result.get("success", true))

	var snap_after: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	check("good handle still in store", snap_after.has(good_handle))
	var rc_after: int = int((snap_after[good_handle] as Dictionary).get("refcount", 0))
	check_eq("refcount unchanged after failed rehydrate", rc_after, rc_before)


# ---------------------------------------------------------------------------
# Edge-case / passthrough tests
# ---------------------------------------------------------------------------

func _test_strip_malformed_wrapper_passthrough() -> void:
	print("\n-- _test_strip_malformed_wrapper_passthrough --")
	var broker = _make_broker()
	# Malformations under the post-base64 contract:
	#   (1) bytes is wrong type entirely (integer, not PBA, not String)
	#   (2) bytes is empty String (the String acceptance guard rejects empty)
	#   (3) bytes is invalid base64 (non-empty String that decodes to nothing)
	#   (4) __blob__ is not truthy
	#   (5) content_type is not a String
	var state: Dictionary = {
		"bad_int":  {"__blob__": true, "content_type": "image/png", "bytes": 42},
		"bad_empty": {"__blob__": true, "content_type": "image/png", "bytes": ""},
		"bad_b64":   {"__blob__": true, "content_type": "image/png", "bytes": "@@@@@@@@"},
		"bad_flag":  {"__blob__": "yes", "content_type": "image/png", "bytes": PackedByteArray([1, 2])},
		"bad_ct":    {"__blob__": true, "content_type": 42, "bytes": PackedByteArray([1, 2])},
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	var d := result as Dictionary
	for key in ["bad_int", "bad_empty", "bad_b64", "bad_flag", "bad_ct"]:
		var bad := d.get(key, {}) as Dictionary
		check("'%s' passed through (has __blob__)" % key, bad.has("__blob__"))
		check("'%s' not replaced with handle" % key, not bad.has("__blob_handle__"))
	check_eq("no blobs stored for any malformation", broker._blob_store_snapshot(TEST_EDITOR).size(), 0)


# ---------------------------------------------------------------------------
# Base64-String encoding tests (added with broker patch accepting String bytes)
#
# The strip walker now accepts `bytes: String (base64)` in addition to
# `bytes: PackedByteArray`. This is required so the wrapper survives a
# JSON.stringify/parse round-trip (see hint godot/json-stringify-packedbytearray-...).
# The blob store records the source encoding; rehydrate emits in the same
# encoding the caller sent (per-blob round-trip symmetry).
# ---------------------------------------------------------------------------

func _test_strip_string_bytes_creates_handle_with_base64_encoding() -> void:
	print("\n-- _test_strip_string_bytes_creates_handle_with_base64_encoding --")
	var broker = _make_broker()
	var raw := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  # PNG magic
	var b64: String = Marshalls.raw_to_base64(raw)
	var state: Dictionary = {
		"img": {"__blob__": true, "content_type": "image/png", "bytes": b64},
	}
	var result: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	var d := result as Dictionary
	var img := d.get("img", {}) as Dictionary
	check("img has __blob_handle__", img.has("__blob_handle__"))
	check("img has no bytes", not img.has("bytes"))
	check_eq("content_type preserved", str(img.get("content_type", "")), "image/png")
	check_eq("one blob in store", broker._blob_store_snapshot(TEST_EDITOR).size(), 1)
	# Encoding is recorded as "base64" so rehydrate emits base64 back.
	var snap: Dictionary = broker._blob_store_snapshot(TEST_EDITOR)
	var handle: String = snap.keys()[0]
	check_eq("encoding recorded as base64", str((snap[handle] as Dictionary).get("encoding", "")), "base64")


func _test_rehydrate_emits_string_when_stored_as_base64() -> void:
	print("\n-- _test_rehydrate_emits_string_when_stored_as_base64 --")
	var broker = _make_broker()
	var raw := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF])
	var b64_in: String = Marshalls.raw_to_base64(raw)
	# Store via the strip path so encoding is recorded as "base64".
	var state_in: Dictionary = {
		"img": {"__blob__": true, "content_type": "image/png", "bytes": b64_in},
	}
	var stripped: Dictionary = broker._strip_blobs_for_outbound(TEST_EDITOR, state_in, TEST_PLUGIN_ID) as Dictionary
	var handle: String = ((stripped["img"] as Dictionary)["__blob_handle__"]) as String

	# Now rehydrate via a placeholder pointing at that handle.
	var state_out_in: Dictionary = {
		"img": {"__blob_handle__": handle, "content_type": "image/png"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state_out_in, TEST_PLUGIN_ID)
	check("rehydrate succeeded", result.get("success", false))
	var rehydrated_img := ((result.get("state", {}) as Dictionary)["img"]) as Dictionary
	check("has __blob__", rehydrated_img.get("__blob__", false) == true)
	check("bytes is String (base64)", rehydrated_img["bytes"] is String)
	check("bytes is not PackedByteArray", not (rehydrated_img["bytes"] is PackedByteArray))
	check_eq("bytes round-trip equal (base64)", str(rehydrated_img["bytes"]), b64_in)


func _test_rehydrate_emits_pba_when_stored_as_bytes() -> void:
	print("\n-- _test_rehydrate_emits_pba_when_stored_as_bytes --")
	var broker = _make_broker()
	var raw := PackedByteArray([0x01, 0x02, 0x03])
	# Direct _store_blob with default encoding ("bytes") preserves existing
	# contract — rehydrate must emit PackedByteArray, not base64.
	var handle: String = broker._store_blob(TEST_EDITOR, raw, "image/png")
	var state: Dictionary = {
		"img": {"__blob_handle__": handle, "content_type": "image/png"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("rehydrate succeeded", result.get("success", false))
	var img := ((result.get("state", {}) as Dictionary)["img"]) as Dictionary
	check("bytes is PackedByteArray", img["bytes"] is PackedByteArray)
	check("bytes is not String", not (img["bytes"] is String))
	check("bytes round-trip equal (PBA)", (img["bytes"] as PackedByteArray) == raw)


func _test_mixed_encoding_blobs_round_trip_independently() -> void:
	print("\n-- _test_mixed_encoding_blobs_round_trip_independently --")
	var broker = _make_broker()
	var raw_pba := PackedByteArray([0xAA, 0xBB])
	var raw_b64 := PackedByteArray([0xCC, 0xDD, 0xEE])
	var b64_str: String = Marshalls.raw_to_base64(raw_b64)
	var state: Dictionary = {
		"img_pba": {"__blob__": true, "content_type": "image/png", "bytes": raw_pba},
		"img_b64": {"__blob__": true, "content_type": "image/jpeg", "bytes": b64_str},
	}
	var stripped: Dictionary = broker._strip_blobs_for_outbound(TEST_EDITOR, state, TEST_PLUGIN_ID) as Dictionary
	var handle_pba: String = ((stripped["img_pba"] as Dictionary)["__blob_handle__"]) as String
	var handle_b64: String = ((stripped["img_b64"] as Dictionary)["__blob_handle__"]) as String

	var state_in: Dictionary = {
		"img_pba": {"__blob_handle__": handle_pba, "content_type": "image/png"},
		"img_b64": {"__blob_handle__": handle_b64, "content_type": "image/jpeg"},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state_in, TEST_PLUGIN_ID)
	check("rehydrate succeeded", result.get("success", false))
	var out := result.get("state", {}) as Dictionary
	var img_pba := out["img_pba"] as Dictionary
	var img_b64 := out["img_b64"] as Dictionary
	check("PBA blob emits PackedByteArray", img_pba["bytes"] is PackedByteArray)
	check("PBA bytes equal", (img_pba["bytes"] as PackedByteArray) == raw_pba)
	check("base64 blob emits String", img_b64["bytes"] is String)
	check_eq("base64 string round-trip equal", str(img_b64["bytes"]), b64_str)


# This is the disk-survival test — proves the post-option-B save shape
# survives JSON stringify/parse cycle. Critical for the .mdeck on-disk format:
# panel emits base64-encoded wrapper → JSON written to disk → JSON parsed on
# load → fed back to broker → strip recognizes it → handle issued. Pre-patch
# this would silently fail (parsed bytes is String not PBA → walker passes
# through → 58MB on the wire).
func _test_blob_wrapper_survives_json_round_trip() -> void:
	print("\n-- _test_blob_wrapper_survives_json_round_trip --")
	var broker = _make_broker()
	var raw := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	var b64: String = Marshalls.raw_to_base64(raw)
	# Simulate save: build panel state with base64-encoded wrapper, stringify.
	var save_state: Dictionary = {
		"slides": [{
			"tiles": [{
				"kind": "image",
				"src": {"__blob__": true, "content_type": "image/png", "bytes": b64},
			}],
		}],
	}
	var json_text: String = JSON.stringify(save_state)
	# Simulate load: parse JSON back.
	var loaded: Variant = JSON.parse_string(json_text)
	check("JSON parse succeeded", loaded is Dictionary)
	# Now feed the loaded state through strip — must recognize the wrapper
	# even though its `bytes` field is now a String (base64), not PBA.
	var stripped: Variant = broker._strip_blobs_for_outbound(TEST_EDITOR, loaded, TEST_PLUGIN_ID)
	var loaded_tile := (((stripped as Dictionary)["slides"] as Array)[0] as Dictionary)["tiles"] as Array
	var src := (loaded_tile[0] as Dictionary)["src"] as Dictionary
	check("post-JSON wrapper recognized: src has __blob_handle__", src.has("__blob_handle__"))
	check("post-JSON wrapper recognized: src has no bytes", not src.has("bytes"))
	check_eq("post-JSON blob stored in broker",
		broker._blob_store_snapshot(TEST_EDITOR).size(), 1)
	# And the bytes survived correctly through the store.
	var handle: String = str(src["__blob_handle__"])
	var rec: Dictionary = broker._get_blob_record(TEST_EDITOR, handle)
	check("blob bytes equal original", (rec["bytes"] as PackedByteArray) == raw)
	check_eq("encoding recorded as base64", str(rec.get("encoding", "")), "base64")


func _test_rehydrate_no_handle_placeholders_passthrough() -> void:
	print("\n-- _test_rehydrate_no_handle_placeholders_passthrough --")
	var broker = _make_broker()
	var state: Dictionary = {
		"version": 3,
		"slides":  [{"id": "s1", "title": "No blobs here"}],
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("passthrough: success", result.get("success", false))
	var out: Dictionary = result.get("state", {})
	check_eq("version preserved", int(out.get("version", 0)), 3)
	check_eq("slides preserved", (out.get("slides", []) as Array).size(), 1)


# Cold-review R3 follow-up: walk path uses RFC 6901 §4 escaping for `~` and
# `/` in keys so error envelopes remain unambiguous when plugin schemas
# contain reserved characters. Previously the raw key was concatenated, so a
# key `"a/b"` collided with a structural slash.
func _test_rehydrate_error_path_escapes_rfc6901_reserved_chars() -> void:
	print("\n-- _test_rehydrate_error_path_escapes_rfc6901_reserved_chars --")
	var broker = _make_broker()
	# Place a bad handle under a key that contains BOTH reserved chars.
	# RFC 6901 encode: `~` → `~0`, `/` → `~1`. Order matters on encode
	# (must escape `~` first, otherwise `~1` would be double-encoded).
	var state: Dictionary = {
		"a/b~c": {
			"__blob_handle__": "blob-does-not-exist",
			"content_type": "image/png",
		},
	}
	var result: Dictionary = broker._rehydrate_blobs_for_inbound(TEST_EDITOR, state, TEST_PLUGIN_ID)
	check("rehydrate path escape: failure surfaced", not result.get("success", true))
	check_eq("error_code is unknown_blob_handle",
			result.get("error_code", "") as String, "unknown_blob_handle")
	# The walk path should be "/a~1b~0c" — RFC 6901 escaped.
	check_eq("walk path uses RFC 6901 escaping",
			result.get("path", "") as String, "/a~1b~0c")
