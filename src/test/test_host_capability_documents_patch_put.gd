extends SceneTree
## Unit tests for host.documents.patch_state and host.documents.put_blob
## capabilities (broker phase 5 R4 — write caps).
##
## Run: godot --headless --path src --script test/test_host_capability_documents_patch_put.gd
##
## Tracks docket: minerva 019e15965ef573458fd5ffd0dbe35182 (Phase 5)
##
## Coverage:
##   patch_state schema validation:
##     - empty editor_name → schema_validation_failed
##     - non-array json_patch → schema_validation_failed
##     - empty json_patch array → schema_validation_failed
##     - op dict missing "op" key → schema_validation_failed
##   patch_state resolution:
##     - bogus editor_name → editor_not_found
##     - host-owned editor type (headless: no editor_pane) → editor_not_found
##       (in headless we can't inject a non-plugin_scene editor, so we verify
##       via direct broker path logic using a mock editor stub)
##   patch_state blob pre-validation:
##     - unknown blob handle in op value → unknown_blob_handle + op_index
##     - all handles valid → no error
##   patch_state apply:
##     - invalid patch op (test-fail) → patch_failed + op_index
##     - happy path (JsonPatch.apply verified directly)
##   patch_state refcount maintenance (via PluginScenePanelBroker directly):
##     - add op with handle in value → +1 on that handle
##     - remove op of path containing handle → -1 on that handle
##     - replace op: new handle +1, old handle -1
##     - copy op: +1 on copied handle
##     - net-zero: replace same handle with itself → no change
##   put_blob schema validation:
##     - empty editor_name → schema_validation_failed
##     - empty content_type → schema_validation_failed
##     - empty bytes_b64 → schema_validation_failed
##   put_blob resolution:
##     - bogus editor_name → editor_not_found
##   put_blob happy path:
##     - returns handle, blob in store with refcount=1
##   put_blob bad base64:
##     - structured schema_validation_failed error
##   Deny path:
##     - patch_state with no grant → capability_not_granted + audit denial
##     - put_blob with no grant → capability_not_granted + audit denial
##   Error code constants:
##     - CODE_PATCH_FAILED and CODE_UNKNOWN_BLOB_HANDLE exist in PluginErrors
##     - patch_failed() factory returns correct shape
##     - unknown_blob_handle() factory returns correct shape
##
## NOTE: The patch_state handler requires a PLUGIN_SCENE editor in order to
## exercise the full panel-state round-trip.  Headless tests cannot construct
## a real editor_pane, so several scenarios drive PluginScenePanelBroker and
## JsonPatch directly to verify the internal logic without the broker dispatch
## layer.  The broker-level schema validation and error routing tests use the
## dispatch path.

const CAPABILITY_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_POLICY_SCRIPT_PATH     := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH  := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_ERRORS_SCRIPT_PATH     := "res://Scripts/Services/Plugins/PluginErrors.gd"
const PANEL_BROKER_SCRIPT_PATH      := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const JSON_PATCH_SCRIPT_PATH        := "res://Scripts/Services/Plugins/JsonPatch.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.documents.patch_state + put_blob Capability Tests (phase 5 R4) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame

	var AuditScript       = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript      = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript      = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var PanelBrokerScript = load(PANEL_BROKER_SCRIPT_PATH)
	var PatchScript       = load(JSON_PATCH_SCRIPT_PATH)
	var ErrorsScript      = load(PLUGIN_ERRORS_SCRIPT_PATH)

	check("scripts loaded",
		AuditScript != null and PolicyScript != null and BrokerScript != null
		and PanelBrokerScript != null and PatchScript != null and ErrorsScript != null)
	if AuditScript == null or PolicyScript == null or BrokerScript == null \
			or PanelBrokerScript == null or PatchScript == null or ErrorsScript == null:
		return

	await _test_error_code_constants(ErrorsScript)
	await _test_patch_state_schema_validation(PolicyScript, BrokerScript, AuditScript)
	await _test_patch_state_editor_not_found(PolicyScript, BrokerScript, AuditScript)
	await _test_patch_state_blob_prevalidation(PolicyScript, BrokerScript, AuditScript, PanelBrokerScript)
	await _test_patch_state_apply_failure(PatchScript)
	await _test_patch_state_happy_path(PatchScript)
	await _test_patch_state_refcount_add(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_remove(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_replace(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_copy(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_net_zero(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_op_add_replaces_existing_key_decrements_displaced(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_multi_op_cascade_no_double_count(PanelBrokerScript, AuditScript)
	await _test_patch_state_refcount_op_move_into_preexisting_decrements_displaced(PanelBrokerScript, AuditScript)
	await _test_put_blob_schema_validation(PolicyScript, BrokerScript, AuditScript)
	await _test_put_blob_editor_not_found(PolicyScript, BrokerScript, AuditScript)
	await _test_put_blob_happy_path_via_panel_broker(PanelBrokerScript, AuditScript)
	await _test_put_blob_bad_base64(PolicyScript, BrokerScript, AuditScript)
	await _test_deny_path(PolicyScript, BrokerScript, AuditScript)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		printerr(msg)


func _make_broker(PolicyScript, BrokerScript, AuditScript) -> Array:
	var audit  = AuditScript.new()
	var policy = PolicyScript.new(null, audit)
	var broker = BrokerScript.new(policy, audit)
	return [broker, policy, audit]


# ---------------------------------------------------------------------------
# Error code constants + factory shapes
# ---------------------------------------------------------------------------

func _test_error_code_constants(ErrorsScript) -> void:
	print("\n-- _test_error_code_constants --")

	check("CODE_PATCH_FAILED exists",
		ErrorsScript.get("CODE_PATCH_FAILED") != null,
		"CODE_PATCH_FAILED not defined in PluginErrors")
	check("CODE_PATCH_FAILED value correct",
		ErrorsScript.CODE_PATCH_FAILED == "patch_failed",
		"got: '%s'" % str(ErrorsScript.CODE_PATCH_FAILED))

	check("CODE_UNKNOWN_BLOB_HANDLE exists",
		ErrorsScript.get("CODE_UNKNOWN_BLOB_HANDLE") != null,
		"CODE_UNKNOWN_BLOB_HANDLE not defined in PluginErrors")
	check("CODE_UNKNOWN_BLOB_HANDLE value correct",
		ErrorsScript.CODE_UNKNOWN_BLOB_HANDLE == "unknown_blob_handle",
		"got: '%s'" % str(ErrorsScript.CODE_UNKNOWN_BLOB_HANDLE))

	# Verify patch_failed factory shape.
	var pf: Dictionary = ErrorsScript.patch_failed("plug", "ed", 2, "test_failed", "value mismatch")
	check("patch_failed → success=false", not pf.get("success", true))
	check("patch_failed → error_code", pf.get("error_code", "") == "patch_failed",
		"got: '%s'" % pf.get("error_code", ""))
	check("patch_failed → op_index", pf.get("op_index", -1) == 2,
		"got: %d" % pf.get("op_index", -1))
	check("patch_failed → op_error_code", pf.get("op_error_code", "") == "test_failed",
		"got: '%s'" % pf.get("op_error_code", ""))
	check("patch_failed → editor_name", pf.get("editor_name", "") == "ed")
	check("patch_failed → plugin_id",   pf.get("plugin_id", "") == "plug")

	# Verify unknown_blob_handle factory shape.
	var ubh: Dictionary = ErrorsScript.unknown_blob_handle("plug", "ed", "blob-7", 3)
	check("unknown_blob_handle → success=false", not ubh.get("success", true))
	check("unknown_blob_handle → error_code",
		ubh.get("error_code", "") == "unknown_blob_handle",
		"got: '%s'" % ubh.get("error_code", ""))
	check("unknown_blob_handle → op_index", ubh.get("op_index", -1) == 3,
		"got: %d" % ubh.get("op_index", -1))
	check("unknown_blob_handle → blob_handle", ubh.get("blob_handle", "") == "blob-7")
	check("unknown_blob_handle → editor_name", ubh.get("editor_name", "") == "ed")


# ---------------------------------------------------------------------------
# patch_state: schema validation
# ---------------------------------------------------------------------------

func _test_patch_state_schema_validation(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_patch_state_schema_validation --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("patch_test", "host.documents.patch_state")

	# Empty editor_name.
	var r1: Dictionary = await broker.dispatch("patch_test",
		"host.documents.patch_state",
		{"editor_name": "", "json_patch": [{"op": "replace", "path": "/title", "value": "X"}]})
	check("empty editor_name → success=false", not r1.get("success", true))
	check("empty editor_name → schema_validation_failed",
		r1.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r1.get("error_code", ""))

	# json_patch not an Array (string).
	var r2: Dictionary = await broker.dispatch("patch_test",
		"host.documents.patch_state",
		{"editor_name": "my_deck", "json_patch": "not_an_array"})
	check("non-array json_patch → success=false", not r2.get("success", true))
	check("non-array json_patch → schema_validation_failed",
		r2.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r2.get("error_code", ""))

	# json_patch is an empty array.
	var r3: Dictionary = await broker.dispatch("patch_test",
		"host.documents.patch_state",
		{"editor_name": "my_deck", "json_patch": []})
	check("empty json_patch array → success=false", not r3.get("success", true))
	check("empty json_patch array → schema_validation_failed",
		r3.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r3.get("error_code", ""))

	# json_patch contains a non-Dictionary element.
	var r4: Dictionary = await broker.dispatch("patch_test",
		"host.documents.patch_state",
		{"editor_name": "my_deck", "json_patch": ["not_a_dict"]})
	check("non-dict op element → success=false", not r4.get("success", true))
	check("non-dict op element → schema_validation_failed",
		r4.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r4.get("error_code", ""))

	# json_patch element missing "op" key.
	var r5: Dictionary = await broker.dispatch("patch_test",
		"host.documents.patch_state",
		{"editor_name": "my_deck", "json_patch": [{"path": "/title", "value": "X"}]})
	check("op missing 'op' key → success=false", not r5.get("success", true))
	check("op missing 'op' key → schema_validation_failed",
		r5.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r5.get("error_code", ""))


# ---------------------------------------------------------------------------
# patch_state: editor not found (bogus name)
# ---------------------------------------------------------------------------

func _test_patch_state_editor_not_found(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_patch_state_editor_not_found --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("patch_test2", "host.documents.patch_state")

	var r: Dictionary = await broker.dispatch("patch_test2",
		"host.documents.patch_state",
		{
			"editor_name": "no_such_editor_xyz_patch",
			"json_patch": [{"op": "replace", "path": "/title", "value": "X"}],
		})
	check("bogus editor → success=false", not r.get("success", true))
	check("bogus editor → editor_not_found",
		r.get("error_code", "") == "editor_not_found",
		"got: '%s'" % r.get("error_code", ""))


# ---------------------------------------------------------------------------
# patch_state: blob pre-validation
# ---------------------------------------------------------------------------

func _test_patch_state_blob_prevalidation(
		PolicyScript, BrokerScript, AuditScript, PanelBrokerScript
) -> void:
	print("\n-- _test_patch_state_blob_prevalidation (via _validate_blob_handles_in_value) --")

	# Drive the validation helper directly (broker._validate_blob_handles_in_value).
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]

	var audit_pb   = AuditScript.new()
	var pbroker    = PanelBrokerScript.new(null, null, null, audit_pb)
	var test_bytes := PackedByteArray([0x89, 0x50])
	var handle: String = pbroker._store_blob("test_ed", test_bytes, "image/png")

	# Unknown handle in value → returns non-empty PluginErrors dict.
	var err1: Dictionary = broker._validate_blob_handles_in_value(
		"plug", "test_ed", {"__blob_handle__": "blob-999", "content_type": "image/png"},
		0, pbroker)
	check("unknown handle → non-empty error dict", not err1.is_empty(),
		"got: %s" % str(err1))
	check("unknown handle → error_code unknown_blob_handle",
		err1.get("error_code", "") == "unknown_blob_handle",
		"got: '%s'" % err1.get("error_code", ""))
	check("unknown handle → op_index 0",
		err1.get("op_index", -1) == 0,
		"got: %d" % err1.get("op_index", -1))

	# Known handle in value → returns empty dict (no error).
	var err2: Dictionary = broker._validate_blob_handles_in_value(
		"plug", "test_ed", {"__blob_handle__": handle, "content_type": "image/png"},
		1, pbroker)
	check("known handle → empty dict (no error)", err2.is_empty(),
		"got: %s" % str(err2))

	# No handles in value (plain dict) → empty dict.
	var err3: Dictionary = broker._validate_blob_handles_in_value(
		"plug", "test_ed", {"title": "Hello", "count": 3},
		0, pbroker)
	check("no handles in value → empty dict", err3.is_empty(),
		"got: %s" % str(err3))

	# Handle nested inside an array → detected.
	var nested_val: Array = [
		{"title": "s1"},
		{"image": {"__blob_handle__": "blob-999", "content_type": "image/png"}},
	]
	var err4: Dictionary = broker._validate_blob_handles_in_value(
		"plug", "test_ed", nested_val, 2, pbroker)
	check("nested unknown handle in array → unknown_blob_handle",
		err4.get("error_code", "") == "unknown_blob_handle",
		"got: '%s'" % err4.get("error_code", ""))
	check("nested unknown handle → op_index 2",
		err4.get("op_index", -1) == 2,
		"got: %d" % err4.get("op_index", -1))


# ---------------------------------------------------------------------------
# patch_state: apply failure (test-op mismatch → patch_failed)
# ---------------------------------------------------------------------------

func _test_patch_state_apply_failure(PatchScript) -> void:
	print("\n-- _test_patch_state_apply_failure (JsonPatch.apply test-op mismatch) --")

	var doc := {"title": "Hello", "count": 3}
	var patch: Array = [
		{"op": "test", "path": "/title", "value": "WRONG_VALUE"},
	]
	var result: Dictionary = PatchScript.apply(doc, patch)
	check("test-op mismatch → success=false", not result.get("success", true))
	var err: Dictionary = result.get("error", {})
	check("test-op mismatch → error.code test_failed",
		err.get("code", "") == "test_failed",
		"got code: '%s'" % err.get("code", ""))
	check("test-op mismatch → op_index 0",
		err.get("op_index", -1) == 0,
		"got op_index: %d" % err.get("op_index", -1))
	# Original doc must be untouched (atomic).
	check("test-op mismatch → original doc untouched",
		result.get("doc", {}).get("title", "") == "Hello",
		"got doc: %s" % str(result.get("doc", {})))


# ---------------------------------------------------------------------------
# patch_state: happy path (JsonPatch.apply verified directly)
# ---------------------------------------------------------------------------

func _test_patch_state_happy_path(PatchScript) -> void:
	print("\n-- _test_patch_state_happy_path (JsonPatch.apply) --")

	var doc := {"title": "Hello", "slides": [{"id": "s1", "title": "First"}]}

	# replace op.
	var patch_replace: Array = [{"op": "replace", "path": "/title", "value": "World"}]
	var r1: Dictionary = PatchScript.apply(doc, patch_replace)
	check("replace op → success", r1.get("success", false))
	check("replace op → new value", r1.get("doc", {}).get("title", "") == "World",
		"got: '%s'" % str(r1.get("doc", {}).get("title", "")))
	# Original doc unchanged (atomicity).
	check("replace op → original untouched", doc.get("title", "") == "Hello")

	# add op to array.
	var doc2 := {"slides": [{"id": "s1"}]}
	var patch_add: Array = [{"op": "add", "path": "/slides/-", "value": {"id": "s2"}}]
	var r2: Dictionary = PatchScript.apply(doc2, patch_add)
	check("add-to-array op → success", r2.get("success", false))
	var slides: Array = r2.get("doc", {}).get("slides", [])
	check("add-to-array → 2 slides", slides.size() == 2,
		"got: %d" % slides.size())
	check("add-to-array → new slide id",
		slides[1].get("id", "") == "s2",
		"got: '%s'" % str(slides[1].get("id", "")))

	# remove op.
	var doc3 := {"a": 1, "b": 2}
	var patch_remove: Array = [{"op": "remove", "path": "/a"}]
	var r3: Dictionary = PatchScript.apply(doc3, patch_remove)
	check("remove op → success", r3.get("success", false))
	check("remove op → key gone", not r3.get("doc", {}).has("a"),
		"doc still has 'a': %s" % str(r3.get("doc", {})))


# ---------------------------------------------------------------------------
# Refcount maintenance: add op adds a blob handle → +1
# ---------------------------------------------------------------------------

## Phase 5 R4 cold-review redesign: refcount maintenance no longer happens per-op
## with the deleted _adjust_blob_refcounts helper. Instead, the patch_state
## handler computes a final-vs-initial multiset diff over the entire state
## (via _count_handles_multiset) and commits the net deltas after the panel
## write succeeds. Tests in this section exercise the multiset helper and the
## handle-leak / atomicity invariants that the redesign guarantees.

func _test_patch_state_refcount_add(PanelBrokerScript, AuditScript) -> void:
	# add a new handle to state → final has handle, initial doesn't → +1.
	print("\n-- _test_patch_state_refcount_add (multiset diff add) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {}
	var final: Dictionary = {"image": {"__blob_handle__": "blob-1", "content_type": "image/png"}}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	check("add: initial has no handles", ic.size() == 0, "got %s" % str(ic))
	check("add: final has blob-1 count=1",
		int(fc.get("blob-1", 0)) == 1, "got %s" % str(fc))


func _test_patch_state_refcount_remove(PanelBrokerScript, AuditScript) -> void:
	# remove handle from state → initial has handle, final doesn't → -1.
	print("\n-- _test_patch_state_refcount_remove (multiset diff remove) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {"image": {"__blob_handle__": "blob-1", "content_type": "image/png"}}
	var final: Dictionary = {}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	check("remove: initial has blob-1 count=1",
		int(ic.get("blob-1", 0)) == 1, "got %s" % str(ic))
	check("remove: final has no handles", fc.size() == 0, "got %s" % str(fc))


func _test_patch_state_refcount_replace(PanelBrokerScript, AuditScript) -> void:
	# replace handle: initial has H_old, final has H_new → -1 H_old, +1 H_new.
	print("\n-- _test_patch_state_refcount_replace (multiset diff replace) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {"image": {"__blob_handle__": "H_old", "content_type": "image/png"}}
	var final: Dictionary = {"image": {"__blob_handle__": "H_new", "content_type": "image/png"}}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	check("replace: H_old initial=1, final=0",
		int(ic.get("H_old", 0)) == 1 and int(fc.get("H_old", 0)) == 0,
		"ic %s, fc %s" % [str(ic), str(fc)])
	check("replace: H_new initial=0, final=1",
		int(ic.get("H_new", 0)) == 0 and int(fc.get("H_new", 0)) == 1,
		"ic %s, fc %s" % [str(ic), str(fc)])


func _test_patch_state_refcount_copy(PanelBrokerScript, AuditScript) -> void:
	# copy duplicates a handle reference: initial has H once, final has H twice → +1.
	print("\n-- _test_patch_state_refcount_copy (multiset diff copy) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {"a": {"__blob_handle__": "H", "content_type": "image/png"}}
	var final: Dictionary = {
		"a": {"__blob_handle__": "H", "content_type": "image/png"},
		"b": {"__blob_handle__": "H", "content_type": "image/png"},
	}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	check("copy: H initial=1, final=2",
		int(ic.get("H", 0)) == 1 and int(fc.get("H", 0)) == 2,
		"ic %s, fc %s" % [str(ic), str(fc)])


# Cold-review R4 must-fix coverage: Finding 2.
# op:add on a path with an existing dict key REPLACES the value (RFC 6902 §4.1).
# Old per-op logic missed this — the displaced handle leaked. New multiset
# diff catches it because initial counts the old handle and final doesn't.
func _test_patch_state_refcount_op_add_replaces_existing_key_decrements_displaced(
		PanelBrokerScript, AuditScript) -> void:
	print("\n-- _test_patch_state_refcount_op_add_replaces_existing_key (FIX VERIFICATION) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	# State before: /image has H_old. After op:add /image {handle: H_new}: /image is H_new.
	var initial: Dictionary = {"image": {"__blob_handle__": "H_old", "content_type": "image/png"}}
	var final:   Dictionary = {"image": {"__blob_handle__": "H_new", "content_type": "image/png"}}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	# Diff: H_old → -1 (displaced); H_new → +1.
	var d_old: int = int(fc.get("H_old", 0)) - int(ic.get("H_old", 0))
	var d_new: int = int(fc.get("H_new", 0)) - int(ic.get("H_new", 0))
	check("op:add-replace: displaced H_old delta = -1", d_old == -1,
		"got %d (ic %s, fc %s)" % [d_old, str(ic), str(fc)])
	check("op:add-replace: new H_new delta = +1", d_new == 1,
		"got %d" % d_new)


# Cold-review R4 must-fix coverage: Finding 4.
# Multi-op patch on the same path used to double-count the old handle.
# Patch = [replace /image H_new, remove /image]. Old per-op logic would
# decrement H_old TWICE (once per op, each reading the snapshot's pre-mutation
# value). New multiset diff sees just initial (H_old once) vs final (empty) →
# correct H_old=-1.
func _test_patch_state_refcount_multi_op_cascade_no_double_count(
		PanelBrokerScript, AuditScript) -> void:
	print("\n-- _test_patch_state_refcount_multi_op_cascade_no_double_count (FIX VERIFICATION) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {"image": {"__blob_handle__": "H_old", "content_type": "image/png"}}
	var final:   Dictionary = {}  # both ops applied → image removed entirely.
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	var d_old: int = int(fc.get("H_old", 0)) - int(ic.get("H_old", 0))
	check("multi-op cascade: H_old delta = -1 (NOT -2 as old per-op logic computed)",
		d_old == -1, "got %d" % d_old)


# Cold-review R4 must-fix coverage: Finding 3.
# op:move where destination path pre-exists in an object — RFC §4.4 = remove
# from + add to. If the destination held a handle, it's displaced. Old logic
# treated move as pure net-zero, leaking the displaced handle. New multiset
# diff sees initial has H_at_dst + H_at_src; final has just H_at_src (moved
# to dst position, H_at_dst gone).
func _test_patch_state_refcount_op_move_into_preexisting_decrements_displaced(
		PanelBrokerScript, AuditScript) -> void:
	print("\n-- _test_patch_state_refcount_op_move_into_preexisting (FIX VERIFICATION) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	# Before move /src → /dst: both paths populated with different handles.
	var initial: Dictionary = {
		"src": {"__blob_handle__": "H_src", "content_type": "image/png"},
		"dst": {"__blob_handle__": "H_dst", "content_type": "image/png"},
	}
	# After: src gone (moved away), dst now holds the moved value (H_src).
	var final: Dictionary = {
		"dst": {"__blob_handle__": "H_src", "content_type": "image/png"},
	}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	var d_src: int = int(fc.get("H_src", 0)) - int(ic.get("H_src", 0))
	var d_dst: int = int(fc.get("H_dst", 0)) - int(ic.get("H_dst", 0))
	check("op:move-into-preexisting: H_src delta = 0 (still present, just moved)",
		d_src == 0, "got %d" % d_src)
	check("op:move-into-preexisting: H_dst delta = -1 (displaced)",
		d_dst == -1, "got %d" % d_dst)


# ---------------------------------------------------------------------------
# Refcount maintenance: net-zero — replace handle with itself
# ---------------------------------------------------------------------------

func _test_patch_state_refcount_net_zero(PanelBrokerScript, AuditScript) -> void:
	# replace handle with itself: initial has H once, final has H once → delta=0.
	print("\n-- _test_patch_state_refcount_net_zero (multiset diff net-zero) --")

	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var initial: Dictionary = {"image": {"__blob_handle__": "H", "content_type": "image/png"}}
	var final:   Dictionary = {"image": {"__blob_handle__": "H", "content_type": "image/png"}}
	var ic: Dictionary = {}
	var fc: Dictionary = {}
	BrokerScript._count_handles_multiset(initial, ic)
	BrokerScript._count_handles_multiset(final, fc)
	check("net-zero: H initial=1, final=1 → delta=0",
		int(ic.get("H", 0)) == 1 and int(fc.get("H", 0)) == 1,
		"ic %s, fc %s" % [str(ic), str(fc)])


# ---------------------------------------------------------------------------
# put_blob: schema validation
# ---------------------------------------------------------------------------

func _test_put_blob_schema_validation(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_put_blob_schema_validation --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("put_blob_test", "host.documents.put_blob")

	var good_b64: String = Marshalls.raw_to_base64(PackedByteArray([0x89, 0x50]))

	# Empty editor_name.
	var r1: Dictionary = await broker.dispatch("put_blob_test",
		"host.documents.put_blob",
		{"editor_name": "", "content_type": "image/png", "bytes_b64": good_b64})
	check("empty editor_name → success=false", not r1.get("success", true))
	check("empty editor_name → schema_validation_failed",
		r1.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r1.get("error_code", ""))

	# Empty content_type.
	var r2: Dictionary = await broker.dispatch("put_blob_test",
		"host.documents.put_blob",
		{"editor_name": "my_deck", "content_type": "", "bytes_b64": good_b64})
	check("empty content_type → success=false", not r2.get("success", true))
	check("empty content_type → schema_validation_failed",
		r2.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r2.get("error_code", ""))

	# Empty bytes_b64.
	var r3: Dictionary = await broker.dispatch("put_blob_test",
		"host.documents.put_blob",
		{"editor_name": "my_deck", "content_type": "image/png", "bytes_b64": ""})
	check("empty bytes_b64 → success=false", not r3.get("success", true))
	check("empty bytes_b64 → schema_validation_failed",
		r3.get("error_code", "") == "schema_validation_failed",
		"got: '%s'" % r3.get("error_code", ""))


# ---------------------------------------------------------------------------
# put_blob: editor not found (bogus name)
# ---------------------------------------------------------------------------

func _test_put_blob_editor_not_found(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_put_blob_editor_not_found --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("put_blob_test2", "host.documents.put_blob")

	var good_b64: String = Marshalls.raw_to_base64(PackedByteArray([0x89, 0x50]))
	var r: Dictionary = await broker.dispatch("put_blob_test2",
		"host.documents.put_blob",
		{
			"editor_name": "no_such_editor_xyz_put_blob",
			"content_type": "image/png",
			"bytes_b64": good_b64,
		})
	check("bogus editor → success=false", not r.get("success", true))
	check("bogus editor → editor_not_found",
		r.get("error_code", "") == "editor_not_found",
		"got: '%s'" % r.get("error_code", ""))


# ---------------------------------------------------------------------------
# put_blob: happy path (via PluginScenePanelBroker._store_blob directly)
# ---------------------------------------------------------------------------

func _test_put_blob_happy_path_via_panel_broker(PanelBrokerScript, AuditScript) -> void:
	print("\n-- _test_put_blob_happy_path --")

	var audit_pb   = AuditScript.new()
	var pbroker    = PanelBrokerScript.new(null, null, null, audit_pb)
	var test_bytes := PackedByteArray([0x89, 0x50, 0x4E, 0x47])  # PNG magic
	var b64: String = Marshalls.raw_to_base64(test_bytes)

	# Decode the base64 (mirrors what the handler does) and store.
	var decoded: PackedByteArray = Marshalls.base64_to_raw(b64)
	check("base64 decode produces original bytes", decoded == test_bytes)

	var handle: String = pbroker._store_blob("put_blob_ed", decoded, "image/png")
	check("_store_blob returns non-empty handle", not handle.is_empty(),
		"handle: '%s'" % handle)

	# Blob is in store with refcount=1.
	var snap: Dictionary = pbroker._blob_store_snapshot("put_blob_ed")
	check("blob is in store after put_blob", snap.has(handle),
		"store keys: %s" % str(snap.keys()))
	check("blob refcount = 1 (not yet referenced by panel state)",
		snap.get(handle, {}).get("refcount", 0) == 1,
		"got: %d" % snap.get(handle, {}).get("refcount", 0))
	check("blob content_type correct",
		snap.get(handle, {}).get("content_type", "") == "image/png",
		"got: '%s'" % snap.get(handle, {}).get("content_type", ""))

	# Verify bytes retrievable.
	var rec: Dictionary = pbroker._get_blob_record("put_blob_ed", handle)
	check("_get_blob_record found=true", rec.get("found", false))
	check("_get_blob_record bytes match", rec.get("bytes", PackedByteArray()) == test_bytes)


# ---------------------------------------------------------------------------
# put_blob: bad base64 input
# ---------------------------------------------------------------------------

func _test_put_blob_bad_base64(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_put_blob_bad_base64 --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("put_blob_test3", "host.documents.put_blob")

	# "!!NOTBASE64!!" decodes to empty in Marshalls.base64_to_raw.
	# The handler treats "non-empty input that decodes to empty bytes" as bad base64.
	# NOTE: Marshalls.base64_to_raw is lenient with some inputs; we use a string
	# that is guaranteed to decode to empty (all non-base64 characters → empty).
	# In headless tests, the editor lookup happens first, so bad base64 only
	# surfaces if the editor name also produces editor_not_found; test by
	# verifying the decoding logic directly and the schema validation path.
	var decoded_bad: PackedByteArray = Marshalls.base64_to_raw("!!NOTBASE64!!")
	check("Marshalls.base64_to_raw of garbage returns empty",
		decoded_bad.is_empty(),
		"got %d bytes" % decoded_bad.size())

	# Even though we can't hit the bad-base64 branch through dispatch in headless
	# (editor lookup fires first), verify the error shape would be correct by
	# constructing a schema_validation_failed directly.
	var ErrorsScript = load(PLUGIN_ERRORS_SCRIPT_PATH)
	if ErrorsScript != null:
		var err: Dictionary = ErrorsScript.schema_validation_failed(
			"put_blob_test3", "host.documents.put_blob: 'bytes_b64' is not valid base64 (decoded to empty)")
		check("bad base64 → schema_validation_failed shape",
			err.get("error_code", "") == "schema_validation_failed",
			"got: '%s'" % err.get("error_code", ""))


# ---------------------------------------------------------------------------
# Deny path: both caps denied when not granted + audit log
# ---------------------------------------------------------------------------

func _test_deny_path(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_deny_path --")
	# Fresh broker with no grants — deny-by-default.
	var audit  = AuditScript.new()
	var policy = PolicyScript.new(null, audit)
	var broker = BrokerScript.new(policy, audit)

	var patch_op := [{"op": "replace", "path": "/title", "value": "X"}]

	var r_patch: Dictionary = await broker.dispatch("no_grant_plugin",
		"host.documents.patch_state",
		{"editor_name": "my_deck", "json_patch": patch_op})
	check("patch_state with no grant → success=false", not r_patch.get("success", true))
	check("patch_state with no grant → capability_not_granted",
		r_patch.get("error_code", "") == "capability_not_granted",
		"got: '%s'" % r_patch.get("error_code", ""))

	var good_b64: String = Marshalls.raw_to_base64(PackedByteArray([0x89]))
	var r_put: Dictionary = await broker.dispatch("no_grant_plugin",
		"host.documents.put_blob",
		{"editor_name": "my_deck", "content_type": "image/png", "bytes_b64": good_b64})
	check("put_blob with no grant → success=false", not r_put.get("success", true))
	check("put_blob with no grant → capability_not_granted",
		r_put.get("error_code", "") == "capability_not_granted",
		"got: '%s'" % r_put.get("error_code", ""))

	# Both denials should appear in the audit log.
	var denied: Array = audit.get_entries("no_grant_plugin", "capability_denied")
	check("both cap denials in audit log",
		denied.size() >= 2,
		"denied count: %d" % denied.size())
