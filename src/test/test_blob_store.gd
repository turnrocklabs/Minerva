extends SceneTree
## Unit tests for PluginScenePanelBroker internal blob store (Phase 5 R1).
##
## Run: godot --headless --path src --script test/test_blob_store.gd
##
## Tracks docket: minerva 019e15965ef573458fd5ffd0dbe35182 (Phase 5)
##
## Coverage:
##   _store_blob        — monotonic handles, per-editor isolation, audit event
##   _get_blob_record   — found/not-found shapes, no refcount mutation
##   _inc_blob_refcount — increments; rejects unknown handle
##   _dec_blob_refcount — decrements; GCs at zero; rejects underflow; rejects unknown
##   _clear_blobs_for_editor — drops all, idempotent on missing editor
##   _blob_store_snapshot   — returns refcount-per-handle; empty for missing editor
##   Audit log          — EVENT_BLOB_STORED and EVENT_BLOB_GC recorded correctly

const PANEL_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const AUDIT_SCRIPT_PATH        := "res://Scripts/Services/Plugins/PluginAuditLog.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _PanelBroker = null
var _Audit       = null


func _init() -> void:
	print("=== Blob Store Unit Tests (Phase 5 R1) ===\n")

	_PanelBroker = load(PANEL_BROKER_SCRIPT_PATH)
	_Audit       = load(AUDIT_SCRIPT_PATH)

	_test_store_returns_monotonic_handles()
	_test_store_isolates_per_editor()
	_test_get_blob_record_for_unknown_handle_returns_not_found()
	_test_inc_dec_balances_to_zero_then_gc()
	_test_dec_below_zero_rejected()
	_test_inc_unknown_handle_rejected()
	_test_clear_editor_drops_all_blobs_and_resets_counter_no()
	_test_clear_unknown_editor_returns_zero()
	_test_audit_log_records_store_and_gc_events()

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


func _make_broker_with_audit() -> Array:
	var audit = _Audit.new()
	var broker = _PanelBroker.new(null, null, null, audit)
	return [broker, audit]


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
# Tests
# ---------------------------------------------------------------------------

func _test_store_returns_monotonic_handles() -> void:
	print("\n-- _test_store_returns_monotonic_handles --")
	var broker = _make_broker()
	var bytes := PackedByteArray([1, 2, 3])

	var h1: String = broker._store_blob("editor_a", bytes, "image/png")
	var h2: String = broker._store_blob("editor_a", bytes, "image/jpeg")
	var h3: String = broker._store_blob("editor_a", bytes, "image/png")

	check_eq("first handle is blob-1", h1, "blob-1")
	check_eq("second handle is blob-2", h2, "blob-2")
	check_eq("third handle is blob-3", h3, "blob-3")
	check("handles are unique", h1 != h2 and h2 != h3 and h1 != h3)

	# After GC, counter must not reuse.
	broker._dec_blob_refcount("editor_a", h1)  # GC h1 (refcount was 1)
	var h4: String = broker._store_blob("editor_a", bytes, "image/png")
	check_eq("handle after GC does not reuse blob-1", h4, "blob-4")
	check("h4 != h1", h4 != h1)


func _test_store_isolates_per_editor() -> void:
	print("\n-- _test_store_isolates_per_editor --")
	var broker = _make_broker()
	var bytes := PackedByteArray([10, 20])

	var ha1: String = broker._store_blob("editor_a", bytes, "image/png")
	var hb1: String = broker._store_blob("editor_b", bytes, "image/png")
	var ha2: String = broker._store_blob("editor_a", bytes, "image/png")
	var hb2: String = broker._store_blob("editor_b", bytes, "image/png")

	# Both editors start their own counter at 1.
	check_eq("editor_a first handle", ha1, "blob-1")
	check_eq("editor_b first handle", hb1, "blob-1")
	check_eq("editor_a second handle", ha2, "blob-2")
	check_eq("editor_b second handle", hb2, "blob-2")

	# Snapshots are independent.
	var snap_a: Dictionary = broker._blob_store_snapshot("editor_a")
	var snap_b: Dictionary = broker._blob_store_snapshot("editor_b")
	check_eq("editor_a has 2 blobs", snap_a.size(), 2)
	check_eq("editor_b has 2 blobs", snap_b.size(), 2)

	# Clearing one editor does not affect the other.
	broker._clear_blobs_for_editor("editor_a")
	var snap_a_after: Dictionary = broker._blob_store_snapshot("editor_a")
	var snap_b_after: Dictionary = broker._blob_store_snapshot("editor_b")
	check_eq("editor_a empty after clear", snap_a_after.size(), 0)
	check_eq("editor_b unaffected after editor_a clear", snap_b_after.size(), 2)


func _test_get_blob_record_for_unknown_handle_returns_not_found() -> void:
	print("\n-- _test_get_blob_record_for_unknown_handle_returns_not_found --")
	var broker = _make_broker()

	# Unknown editor.
	var r1: Dictionary = broker._get_blob_record("no_such_editor", "blob-1")
	check("unknown editor: found=false", not r1["found"])
	check_eq("unknown editor: refcount=0", r1["refcount"], 0)
	check_eq("unknown editor: content_type empty", r1["content_type"], "")

	# Known editor, unknown handle.
	var bytes := PackedByteArray([5])
	broker._store_blob("editor_x", bytes, "image/png")
	var r2: Dictionary = broker._get_blob_record("editor_x", "blob-999")
	check("known editor, unknown handle: found=false", not r2["found"])
	check_eq("known editor, unknown handle: refcount=0", r2["refcount"], 0)

	# Known editor, known handle.
	var r3: Dictionary = broker._get_blob_record("editor_x", "blob-1")
	check("known handle: found=true", r3["found"])
	check_eq("known handle: refcount=1", r3["refcount"], 1)
	check_eq("known handle: content_type", r3["content_type"], "image/png")
	check_eq("known handle: bytes size", r3["bytes"].size(), 1)

	# get_blob_record does NOT mutate refcount.
	var r4: Dictionary = broker._get_blob_record("editor_x", "blob-1")
	check_eq("refcount unchanged after two get calls", r4["refcount"], 1)


func _test_inc_dec_balances_to_zero_then_gc() -> void:
	print("\n-- _test_inc_dec_balances_to_zero_then_gc --")
	var broker = _make_broker()
	var bytes := PackedByteArray([99])

	var handle: String = broker._store_blob("ed", bytes, "application/octet-stream")
	check_eq("initial refcount=1", broker._get_blob_record("ed", handle)["refcount"], 1)

	# Two inc: refcount goes to 3.
	var ok1: bool = broker._inc_blob_refcount("ed", handle)
	var ok2: bool = broker._inc_blob_refcount("ed", handle)
	check("inc 1 returned true", ok1)
	check("inc 2 returned true", ok2)
	check_eq("refcount after 2 incs = 3", broker._get_blob_record("ed", handle)["refcount"], 3)

	# Dec back to 2.
	var d1: bool = broker._dec_blob_refcount("ed", handle)
	check("dec 1 returned true", d1)
	check_eq("refcount after dec = 2", broker._get_blob_record("ed", handle)["refcount"], 2)

	# Dec to 1.
	broker._dec_blob_refcount("ed", handle)
	check_eq("refcount after 2nd dec = 1", broker._get_blob_record("ed", handle)["refcount"], 1)

	# Dec to 0 — triggers GC.
	var d3: bool = broker._dec_blob_refcount("ed", handle)
	check("dec to 0 returned true", d3)

	# Entry must be gone.
	var r_after: Dictionary = broker._get_blob_record("ed", handle)
	check("entry GC'd: found=false", not r_after["found"])

	# Snapshot confirms empty.
	var snap: Dictionary = broker._blob_store_snapshot("ed")
	check_eq("snapshot empty after GC", snap.size(), 0)


func _test_dec_below_zero_rejected() -> void:
	print("\n-- _test_dec_below_zero_rejected --")
	var broker = _make_broker()
	var bytes := PackedByteArray([7])

	var handle: String = broker._store_blob("ed2", bytes, "image/gif")
	# Decrement once to GC it.
	broker._dec_blob_refcount("ed2", handle)
	var r1: Dictionary = broker._get_blob_record("ed2", handle)
	check("entry removed after dec to 0", not r1["found"])

	# Second dec on now-missing handle must return false (handle gone from store).
	var d2: bool = broker._dec_blob_refcount("ed2", handle)
	check("dec on GC'd handle returns false", not d2)

	# Also test: store, manually force refcount to 0 via snapshot inspection,
	# then call dec again. We do this by storing, doing one dec (GC), then
	# re-storing with same editor (new handle) and trying to dec the old handle.
	var handle2: String = broker._store_blob("ed2", bytes, "image/gif")
	check("new handle after GC is different", handle2 != handle)
	# Old handle is gone, dec must return false.
	var d3: bool = broker._dec_blob_refcount("ed2", handle)
	check("dec on old GC'd handle still returns false", not d3)
	# New handle still present.
	check("new handle still alive", broker._get_blob_record("ed2", handle2)["found"])


func _test_inc_unknown_handle_rejected() -> void:
	print("\n-- _test_inc_unknown_handle_rejected --")
	var broker = _make_broker()

	# Unknown editor.
	var ok1: bool = broker._inc_blob_refcount("no_editor", "blob-1")
	check("inc on unknown editor returns false", not ok1)

	# Known editor, unknown handle.
	var bytes := PackedByteArray([3])
	broker._store_blob("ed3", bytes, "text/plain")
	var ok2: bool = broker._inc_blob_refcount("ed3", "blob-999")
	check("inc on unknown handle returns false", not ok2)

	# Known editor, known handle — succeeds.
	var ok3: bool = broker._inc_blob_refcount("ed3", "blob-1")
	check("inc on known handle returns true", ok3)
	check_eq("refcount incremented to 2", broker._get_blob_record("ed3", "blob-1")["refcount"], 2)


func _test_clear_editor_drops_all_blobs_and_resets_counter_no() -> void:
	## Intentional test name: counter does NOT reset (collision safety).
	print("\n-- _test_clear_editor_drops_all_blobs_and_resets_counter_no --")
	var broker = _make_broker()
	var bytes := PackedByteArray([1])

	# Store 3 blobs.
	broker._store_blob("ed4", bytes, "image/png")
	broker._store_blob("ed4", bytes, "image/png")
	broker._store_blob("ed4", bytes, "image/png")
	check_eq("3 blobs before clear", broker._blob_store_snapshot("ed4").size(), 3)

	var dropped: int = broker._clear_blobs_for_editor("ed4")
	check_eq("clear returned 3", dropped, 3)
	check_eq("snapshot empty after clear", broker._blob_store_snapshot("ed4").size(), 0)

	# Counter must NOT have reset: next blob should be blob-4, not blob-1.
	var h_new: String = broker._store_blob("ed4", bytes, "image/png")
	check_eq("handle after re-open is blob-4 (counter not reset)", h_new, "blob-4")
	check("handle not blob-1", h_new != "blob-1")


func _test_clear_unknown_editor_returns_zero() -> void:
	print("\n-- _test_clear_unknown_editor_returns_zero --")
	var broker = _make_broker()

	var count: int = broker._clear_blobs_for_editor("no_such_editor")
	check_eq("clear on unknown editor returns 0", count, 0)

	# Also idempotent: call twice on a real editor that's already clear.
	var bytes := PackedByteArray([5])
	broker._store_blob("ed5", bytes, "image/png")
	broker._clear_blobs_for_editor("ed5")
	var count2: int = broker._clear_blobs_for_editor("ed5")
	check_eq("second clear on cleared editor returns 0", count2, 0)


func _test_audit_log_records_store_and_gc_events() -> void:
	print("\n-- _test_audit_log_records_store_and_gc_events --")
	var pair: Array = _make_broker_with_audit()
	var broker = pair[0]
	var audit  = pair[1]

	var bytes := PackedByteArray([1, 2, 3, 4])
	var handle: String = broker._store_blob("ed_audit", bytes, "image/png")

	# Audit log should have one BLOB_STORED event.
	var stored_entries: Array = audit.get_entries("", "blob_stored", 10)
	check_eq("one blob_stored event", stored_entries.size(), 1)
	var se: Dictionary = stored_entries[0]
	check_eq("blob_stored: editor_name", str(se["detail"].get("editor_name", "")), "ed_audit")
	check_eq("blob_stored: handle", str(se["detail"].get("handle", "")), handle)
	check_eq("blob_stored: content_type", str(se["detail"].get("content_type", "")), "image/png")
	check_eq("blob_stored: bytes_len", int(se["detail"].get("bytes_len", -1)), 4)

	# No GC event yet.
	var gc_before: Array = audit.get_entries("", "blob_gc", 10)
	check_eq("no blob_gc event before dec", gc_before.size(), 0)

	# Dec to 0 — should fire GC event.
	broker._dec_blob_refcount("ed_audit", handle)
	var gc_after: Array = audit.get_entries("", "blob_gc", 10)
	check_eq("one blob_gc event after dec-to-zero", gc_after.size(), 1)
	var ge: Dictionary = gc_after[0]
	check_eq("blob_gc: editor_name", str(ge["detail"].get("editor_name", "")), "ed_audit")
	check_eq("blob_gc: handle", str(ge["detail"].get("handle", "")), handle)
	check_eq("blob_gc: content_type", str(ge["detail"].get("content_type", "")), "image/png")

	# Test BLOBS_CLEARED event via _clear_blobs_for_editor.
	var bytes2 := PackedByteArray([9])
	broker._store_blob("ed_clear", bytes2, "text/plain")
	broker._store_blob("ed_clear", bytes2, "text/plain")
	broker._clear_blobs_for_editor("ed_clear")
	var cleared_entries: Array = audit.get_entries("", "blobs_cleared", 10)
	check_eq("one blobs_cleared event", cleared_entries.size(), 1)
	var ce: Dictionary = cleared_entries[0]
	check_eq("blobs_cleared: editor_name", str(ce["detail"].get("editor_name", "")), "ed_clear")
	check_eq("blobs_cleared: count_dropped", int(ce["detail"].get("count_dropped", -1)), 2)

	# _clear_blobs_for_editor on empty/missing editor does NOT emit blobs_cleared.
	broker._clear_blobs_for_editor("ed_never_existed")
	var cleared_entries2: Array = audit.get_entries("", "blobs_cleared", 10)
	check_eq("no extra blobs_cleared for empty-editor clear", cleared_entries2.size(), 1)
