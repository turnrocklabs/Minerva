extends SceneTree
## Integration test for JsonPointer (RFC 6901) and JsonPatch (RFC 6902).
##
## Run: godot --headless --path src --script test/test_json_patch.gd
##
## Tracks docket task: minerva 019e15965ef573458fd5ffd0dbe35182
## Phase 5 R0 — pure RFC library, no broker coupling.

# preload() at const level so the loaded Script objects are available
# in every function body without dynamic load() calls. This is the
# correct pattern for --script headless tests in this repo (class_name
# declarations from other files are not in scope for the main script).
const JP := preload("res://Scripts/Services/Plugins/JsonPointer.gd")
const JPA := preload("res://Scripts/Services/Plugins/JsonPatch.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== JSON Pointer (RFC 6901) + JSON Patch (RFC 6902) Test ===\n")
	_run_pointer_tests()
	_run_patch_tests()
	print("\n=== Results: PASS:%d FAIL:%d ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# JSON Pointer tests
# ---------------------------------------------------------------------------

func _run_pointer_tests() -> void:
	print("--- JsonPointer ---")

	_test_pointer_root_returns_document()
	_test_pointer_single_key_in_dict()
	_test_pointer_nested_dict_path()
	_test_pointer_array_index()
	_test_pointer_dash_is_end_of_array_target()
	_test_pointer_missing_key_returns_not_found()
	_test_pointer_missing_array_index_returns_not_found()
	_test_pointer_malformed_no_leading_slash()
	_test_pointer_tilde1_escape_decodes_slash()
	_test_pointer_tilde0_escape_decodes_tilde()
	_test_pointer_escape_order_tilde1_before_tilde0()
	_test_pointer_array_in_dict()
	_test_pointer_dict_in_array()
	_test_pointer_leading_zeros_invalid_index()
	_test_pointer_dash_at_nonterminal_returns_not_found()
	_test_pointer_parent_and_key_populated_for_dict()
	_test_pointer_parent_and_key_populated_for_array()


func _test_pointer_root_returns_document() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JP.resolve(doc, "")
	_assert("pointer: empty string returns root document",
			r.found == true and r.value == doc and r.parent == null and r.key == null)


func _test_pointer_single_key_in_dict() -> void:
	var doc := {"foo": "bar"}
	var r: Dictionary = JP.resolve(doc, "/foo")
	_assert("pointer: /foo resolves to 'bar'", r.found == true and r.value == "bar")


func _test_pointer_nested_dict_path() -> void:
	var doc := {"a": {"b": {"c": 42}}}
	var r: Dictionary = JP.resolve(doc, "/a/b/c")
	_assert("pointer: /a/b/c resolves nested dict", r.found == true and r.value == 42)


func _test_pointer_array_index() -> void:
	var doc := {"items": ["x", "y", "z"]}
	var r: Dictionary = JP.resolve(doc, "/items/1")
	_assert("pointer: /items/1 resolves to 'y'", r.found == true and r.value == "y")


func _test_pointer_dash_is_end_of_array_target() -> void:
	var doc: Array = [1, 2, 3]
	var r: Dictionary = JP.resolve(doc, "/-")
	_assert("pointer: /- on array returns found=false with key=size",
			r.found == false and r.reason == "end_of_array" and r.key == 3 and r.parent == doc)


func _test_pointer_missing_key_returns_not_found() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JP.resolve(doc, "/b")
	_assert("pointer: missing key returns found=false", r.found == false)


func _test_pointer_missing_array_index_returns_not_found() -> void:
	var doc: Array = [10, 20]
	var r: Dictionary = JP.resolve(doc, "/5")
	_assert("pointer: out-of-bounds index returns found=false", r.found == false)


func _test_pointer_malformed_no_leading_slash() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JP.resolve(doc, "a/b")
	_assert("pointer: malformed pointer without leading slash returns found=false with reason",
			r.found == false and r.reason == "malformed_pointer")


func _test_pointer_tilde1_escape_decodes_slash() -> void:
	var doc := {"a/b": 99}
	var r: Dictionary = JP.resolve(doc, "/a~1b")
	_assert("pointer: ~1 decodes to / for key lookup", r.found == true and r.value == 99)


func _test_pointer_tilde0_escape_decodes_tilde() -> void:
	var doc := {"a~b": 77}
	var r: Dictionary = JP.resolve(doc, "/a~0b")
	_assert("pointer: ~0 decodes to ~ for key lookup", r.found == true and r.value == 77)


func _test_pointer_escape_order_tilde1_before_tilde0() -> void:
	# RFC 6901 §4: "~1" must be decoded before "~0".
	# The dangerous case: token "~01" should decode to literal "~1" (not "/").
	#   Correct order (~1 first): "~01" → no ~1 match → then ~0→~ → "~1"   ✓
	#   Wrong order  (~0 first):  "~01" → ~0→~ → "~1" → then ~1→"/" → "/"  ✗
	var doc := {"~1": "tilde-one-literal"}
	var r: Dictionary = JP.resolve(doc, "/~01")
	_assert("pointer: ~01 decodes to literal ~1 (not /), verifying ~1-first decode order",
			r.found == true and r.value == "tilde-one-literal")


func _test_pointer_array_in_dict() -> void:
	var doc := {"arr": [10, 20, 30]}
	var r: Dictionary = JP.resolve(doc, "/arr/2")
	_assert("pointer: /arr/2 resolves array element in dict", r.found == true and r.value == 30)


func _test_pointer_dict_in_array() -> void:
	var doc: Array = [{"x": 1}, {"x": 2}]
	var r: Dictionary = JP.resolve(doc, "/1/x")
	_assert("pointer: /1/x resolves dict nested inside array", r.found == true and r.value == 2)


func _test_pointer_leading_zeros_invalid_index() -> void:
	var doc: Array = [1, 2, 3]
	var r: Dictionary = JP.resolve(doc, "/01")
	_assert("pointer: leading-zero index '01' is malformed", r.found == false)


func _test_pointer_dash_at_nonterminal_returns_not_found() -> void:
	# "-" may only appear as the last token; using it mid-path is undefined
	var doc: Array = [[1, 2], [3, 4]]
	var r: Dictionary = JP.resolve(doc, "/-/0")
	_assert("pointer: '-' at non-terminal position is not found", r.found == false)


func _test_pointer_parent_and_key_populated_for_dict() -> void:
	var doc := {"outer": {"inner": "val"}}
	var r: Dictionary = JP.resolve(doc, "/outer/inner")
	_assert("pointer: parent is outer dict and key is 'inner'",
			r.found == true and r.parent == doc["outer"] and r.key == "inner")


func _test_pointer_parent_and_key_populated_for_array() -> void:
	var doc := {"arr": ["a", "b", "c"]}
	var r: Dictionary = JP.resolve(doc, "/arr/0")
	_assert("pointer: parent is the array and key is int 0",
			r.found == true and r.parent == doc["arr"] and r.key == 0)


# ---------------------------------------------------------------------------
# JSON Patch tests
# ---------------------------------------------------------------------------

func _run_patch_tests() -> void:
	print("\n--- JsonPatch ---")

	# --- add ---
	_test_add_new_key_to_dict()
	_test_add_appends_to_array_with_dash()
	_test_add_inserts_at_array_index()
	_test_add_replaces_existing_dict_key()
	_test_add_to_root_replaces_document()
	_test_add_fails_when_parent_path_missing()

	# --- remove ---
	_test_remove_dict_key()
	_test_remove_array_element()
	_test_remove_fails_when_path_missing()

	# --- replace ---
	_test_replace_dict_value()
	_test_replace_array_element()
	_test_replace_fails_when_path_missing()
	_test_replace_root_replaces_document()

	# --- move ---
	_test_move_dict_key_to_new_key()
	_test_move_array_element_to_end()
	_test_move_into_self_rejected()
	_test_move_fails_when_from_missing()
	_test_move_same_path_is_noop()

	# --- copy ---
	_test_copy_dict_value_to_new_key()
	_test_copy_array_element()
	_test_copy_fails_when_from_missing()

	# --- test ---
	_test_test_passes_when_value_matches()
	_test_test_fails_when_value_differs()
	_test_test_fails_when_path_missing()
	_test_test_deep_equality_nested()

	# --- atomicity ---
	_test_atomic_rollback_on_mid_patch_failure()
	_test_atomic_success_applies_all_ops()

	# --- error codes ---
	_test_error_code_malformed_patch_missing_op()
	_test_error_code_unknown_op()
	_test_error_code_malformed_pointer_in_op()
	_test_error_code_from_missing_on_copy()
	_test_error_code_from_missing_on_move()
	_test_error_code_path_missing_on_remove()
	_test_error_code_test_failed()

	# --- dict-root shapes ---
	_test_dict_root_multi_op_patch()

	# --- array-root shapes ---
	_test_array_root_add_and_remove()
	_test_array_root_move()

	# --- review-driven coverage gaps (R0 cold-review notes) ---
	_test_atomic_rollback_on_test_op_failure()
	_test_pointer_root_vs_empty_key_distinct()
	_test_test_int_float_coercion_whole_numbers()
	_test_test_int_float_rejects_fractional_mismatch()


# ---- add ----

func _test_add_new_key_to_dict() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "/b", "value": 2}])
	_assert("patch add: adds new key to dict", r.success and r.doc.get("b") == 2)


func _test_add_appends_to_array_with_dash() -> void:
	var doc := {"arr": [1, 2, 3]}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "/arr/-", "value": 4}])
	_assert("patch add: appends to array with '-'",
			r.success and r.doc["arr"].size() == 4 and r.doc["arr"][3] == 4)


func _test_add_inserts_at_array_index() -> void:
	var doc := {"arr": [1, 3]}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "/arr/1", "value": 2}])
	_assert("patch add: inserts at array index (shifts subsequent)",
			r.success and r.doc["arr"][1] == 2 and r.doc["arr"][2] == 3)


func _test_add_replaces_existing_dict_key() -> void:
	var doc := {"a": "old"}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "/a", "value": "new"}])
	_assert("patch add: replaces existing dict key value",
			r.success and r.doc.get("a") == "new")


func _test_add_to_root_replaces_document() -> void:
	var doc := {"old": true}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "", "value": {"new": true}}])
	_assert("patch add: empty path replaces entire document",
			r.success and r.doc.has("new") and not r.doc.has("old"))


func _test_add_fails_when_parent_path_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "/b/c", "value": 99}])
	_assert("patch add: fails when intermediate parent missing",
			not r.success and r.error.code == JPA.ERR_PATH_MISSING)


# ---- remove ----

func _test_remove_dict_key() -> void:
	var doc := {"a": 1, "b": 2}
	var r: Dictionary = JPA.apply(doc, [{"op": "remove", "path": "/a"}])
	_assert("patch remove: removes dict key", r.success and not r.doc.has("a") and r.doc.has("b"))


func _test_remove_array_element() -> void:
	var doc := {"arr": [10, 20, 30]}
	var r: Dictionary = JPA.apply(doc, [{"op": "remove", "path": "/arr/1"}])
	_assert("patch remove: removes array element at index",
			r.success and r.doc["arr"].size() == 2 and r.doc["arr"][0] == 10 and r.doc["arr"][1] == 30)


func _test_remove_fails_when_path_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "remove", "path": "/z"}])
	_assert("patch remove: fails when path missing",
			not r.success and r.error.code == JPA.ERR_PATH_MISSING)


# ---- replace ----

func _test_replace_dict_value() -> void:
	var doc := {"x": "hello"}
	var r: Dictionary = JPA.apply(doc, [{"op": "replace", "path": "/x", "value": "world"}])
	_assert("patch replace: replaces dict value", r.success and r.doc.get("x") == "world")


func _test_replace_array_element() -> void:
	var doc: Array = [1, 2, 3]
	var r: Dictionary = JPA.apply(doc, [{"op": "replace", "path": "/1", "value": 99}])
	_assert("patch replace: replaces array element", r.success and r.doc[1] == 99)


func _test_replace_fails_when_path_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "replace", "path": "/z", "value": 0}])
	_assert("patch replace: fails when path missing",
			not r.success and r.error.code == JPA.ERR_PATH_MISSING)


func _test_replace_root_replaces_document() -> void:
	var doc := {"old": true}
	var r: Dictionary = JPA.apply(doc, [{"op": "replace", "path": "", "value": [1, 2, 3]}])
	_assert("patch replace: empty path replaces entire document",
			r.success and r.doc is Array and r.doc.size() == 3)


# ---- move ----

func _test_move_dict_key_to_new_key() -> void:
	var doc := {"a": 42, "b": "keep"}
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/a", "path": "/c"}])
	_assert("patch move: moves dict key to new name",
			r.success and not r.doc.has("a") and r.doc.get("c") == 42 and r.doc.get("b") == "keep")


func _test_move_array_element_to_end() -> void:
	var doc := {"arr": [1, 2, 3]}
	# Move first element to end
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/arr/0", "path": "/arr/-"}])
	_assert("patch move: moves array element to end via '-'",
			r.success and r.doc["arr"][0] == 2 and r.doc["arr"][2] == 1)


func _test_move_into_self_rejected() -> void:
	var doc := {"a": {"b": 1}}
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/a", "path": "/a/b"}])
	_assert("patch move: rejected when target is descendant of from",
			not r.success and r.error.code == JPA.ERR_MOVE_INTO_SELF)


func _test_move_fails_when_from_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/z", "path": "/a"}])
	_assert("patch move: fails with from_missing when source absent",
			not r.success and r.error.code == JPA.ERR_FROM_MISSING)


func _test_move_same_path_is_noop() -> void:
	var doc := {"a": 99}
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/a", "path": "/a"}])
	_assert("patch move: move to same path is a no-op success",
			r.success and r.doc.get("a") == 99)


# ---- copy ----

func _test_copy_dict_value_to_new_key() -> void:
	var doc := {"src": {"nested": true}}
	var r: Dictionary = JPA.apply(doc, [{"op": "copy", "from": "/src", "path": "/dst"}])
	_assert("patch copy: copies dict value to new key",
			r.success and r.doc.has("dst") and r.doc["dst"].get("nested") == true)


func _test_copy_array_element() -> void:
	var doc := {"arr": [10, 20, 30], "other": []}
	var r: Dictionary = JPA.apply(doc, [{"op": "copy", "from": "/arr/2", "path": "/other/-"}])
	_assert("patch copy: copies array element to another array",
			r.success and r.doc["other"].size() == 1 and r.doc["other"][0] == 30)


func _test_copy_fails_when_from_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "copy", "from": "/missing", "path": "/b"}])
	_assert("patch copy: fails with from_missing when source absent",
			not r.success and r.error.code == JPA.ERR_FROM_MISSING)


# ---- test ----

func _test_test_passes_when_value_matches() -> void:
	var doc := {"status": "ok"}
	var r: Dictionary = JPA.apply(doc, [{"op": "test", "path": "/status", "value": "ok"}])
	_assert("patch test: passes when value matches", r.success)


func _test_test_fails_when_value_differs() -> void:
	var doc := {"status": "ok"}
	var r: Dictionary = JPA.apply(doc, [{"op": "test", "path": "/status", "value": "fail"}])
	_assert("patch test: fails when value differs",
			not r.success and r.error.code == JPA.ERR_TEST_FAILED)


func _test_test_fails_when_path_missing() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "test", "path": "/missing", "value": 1}])
	_assert("patch test: fails when path missing",
			not r.success and r.error.code == JPA.ERR_PATH_MISSING)


func _test_test_deep_equality_nested() -> void:
	var doc := {"obj": {"x": 1, "y": [2, 3]}}
	var expected := {"x": 1, "y": [2, 3]}
	var r: Dictionary = JPA.apply(doc, [{"op": "test", "path": "/obj", "value": expected}])
	_assert("patch test: deep equality for nested dict+array", r.success)


# ---- atomicity ----

func _test_atomic_rollback_on_mid_patch_failure() -> void:
	# Op 0 succeeds (adds /b=2), op 1 fails (remove /nonexistent).
	# After failure the original doc must be unchanged.
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "add", "path": "/b", "value": 2},
		{"op": "remove", "path": "/nonexistent"},
	])
	_assert("patch atomic: failure in op 1 leaves document unmodified",
			not r.success and
			r.doc.has("a") and not r.doc.has("b") and
			r.error.op_index == 1 and
			r.error.code == JPA.ERR_PATH_MISSING)


func _test_atomic_success_applies_all_ops() -> void:
	var doc := {"a": 1, "b": 2}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "add", "path": "/c", "value": 3},
		{"op": "remove", "path": "/b"},
		{"op": "replace", "path": "/a", "value": 99},
	])
	_assert("patch atomic: all three ops applied on success",
			r.success and r.doc.get("a") == 99 and r.doc.has("c") and not r.doc.has("b"))


# ---- error codes ----

func _test_error_code_malformed_patch_missing_op() -> void:
	var doc := {}
	var r: Dictionary = JPA.apply(doc, [{"path": "/x", "value": 1}])
	_assert("patch error: missing 'op' key -> malformed_patch",
			not r.success and r.error.code == JPA.ERR_MALFORMED_PATCH)


func _test_error_code_unknown_op() -> void:
	var doc := {}
	var r: Dictionary = JPA.apply(doc, [{"op": "frobnicate", "path": "/x"}])
	_assert("patch error: unknown op -> unknown_op",
			not r.success and r.error.code == JPA.ERR_UNKNOWN_OP)


func _test_error_code_malformed_pointer_in_op() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "add", "path": "no-leading-slash", "value": 1}])
	_assert("patch error: pointer without leading slash -> malformed_pointer",
			not r.success and r.error.code == JPA.ERR_MALFORMED_POINTER)


func _test_error_code_from_missing_on_copy() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "copy", "from": "/missing", "path": "/b"}])
	_assert("patch error: copy with absent from -> from_missing",
			not r.success and r.error.code == JPA.ERR_FROM_MISSING)


func _test_error_code_from_missing_on_move() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "move", "from": "/missing", "path": "/b"}])
	_assert("patch error: move with absent from -> from_missing",
			not r.success and r.error.code == JPA.ERR_FROM_MISSING)


func _test_error_code_path_missing_on_remove() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "remove", "path": "/z"}])
	_assert("patch error: remove with absent path -> path_missing",
			not r.success and r.error.code == JPA.ERR_PATH_MISSING)


func _test_error_code_test_failed() -> void:
	var doc := {"a": 1}
	var r: Dictionary = JPA.apply(doc, [{"op": "test", "path": "/a", "value": 999}])
	_assert("patch error: test value mismatch -> test_failed",
			not r.success and r.error.code == JPA.ERR_TEST_FAILED)


# ---- dict-root shapes ----

func _test_dict_root_multi_op_patch() -> void:
	var doc := {"title": "hello", "count": 0, "tags": ["a", "b"]}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "replace", "path": "/title", "value": "world"},
		{"op": "add", "path": "/tags/-", "value": "c"},
		{"op": "replace", "path": "/count", "value": 3},
	])
	_assert("patch dict-root: multi-op patch applies all changes",
			r.success and
			r.doc.get("title") == "world" and
			r.doc["tags"].size() == 3 and r.doc["tags"][2] == "c" and
			r.doc.get("count") == 3)


# ---- array-root shapes ----

func _test_array_root_add_and_remove() -> void:
	var doc: Array = [1, 2, 3]
	var r: Dictionary = JPA.apply(doc, [
		{"op": "add", "path": "/-", "value": 4},
		{"op": "remove", "path": "/0"},
	])
	_assert("patch array-root: add + remove on array-root doc",
			r.success and r.doc.size() == 3 and r.doc[0] == 2 and r.doc[2] == 4)


func _test_array_root_move() -> void:
	var doc: Array = ["a", "b", "c"]
	var r: Dictionary = JPA.apply(doc, [
		{"op": "move", "from": "/0", "path": "/-"},
	])
	_assert("patch array-root: move first element to end",
			r.success and r.doc[0] == "b" and r.doc[2] == "a")


# Cold-review coverage gap: prior tests pinned rollback for op:remove failure.
# A failing op:test mid-batch must also rollback — same invariant, different
# failure source. Without this test, the test-op's atomicity is unverified.
func _test_atomic_rollback_on_test_op_failure() -> void:
	var doc := {"a": 1, "b": 2}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "replace", "path": "/a", "value": 99},
		{"op": "add",     "path": "/c", "value": 3},
		{"op": "test",    "path": "/b", "value": 999},
	])
	_assert("patch atomic: failure on op:test rolls back prior mutations",
			not r.success
			and r.error.get("code", "") == "test_failed"
			and r.error.get("op_index", -1) == 2
			and doc.get("a") == 1
			and doc.get("b") == 2
			and not doc.has("c"))


# Cold-review coverage gap: RFC 6901 distinguishes "" (root) from "/" (key=""
# at root). Pin the distinction with one assertion pair so a future refactor
# can't conflate them.
func _test_pointer_root_vs_empty_key_distinct() -> void:
	var doc := {"": "empty_key_value", "a": "alpha"}
	var root_r: Dictionary = JP.resolve(doc, "")
	var empty_key_r: Dictionary = JP.resolve(doc, "/")
	_assert("pointer: \"\" resolves to root, \"/\" resolves to key=\"\"",
			root_r.value == doc
			and empty_key_r.found == true
			and empty_key_r.value == "empty_key_value")


# Cold-review coverage gap: op:test's deep equality coerces whole-number
# int/float pairs because GDScript's JSON.parse returns all numbers as float.
# Verify 1 == 1.0 passes.
func _test_test_int_float_coercion_whole_numbers() -> void:
	var doc := {"n": 1.0}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "test", "path": "/n", "value": 1},
	])
	_assert("patch test: int 1 equals float 1.0 (whole-number coercion)",
			r.success)


# Cold-review coverage gap: int/float coercion must be gated to whole numbers
# only — 1.5 must not satisfy a test against 1.
func _test_test_int_float_rejects_fractional_mismatch() -> void:
	var doc := {"n": 1.5}
	var r: Dictionary = JPA.apply(doc, [
		{"op": "test", "path": "/n", "value": 1},
	])
	_assert("patch test: float 1.5 does NOT equal int 1 (coercion gate)",
			not r.success
			and r.error.get("code", "") == "test_failed")


# ---------------------------------------------------------------------------
# Assertion helper
# ---------------------------------------------------------------------------

func _assert(label: String, condition: bool) -> void:
	if condition:
		print("PASS: %s" % label)
		_pass_count += 1
	else:
		printerr("FAIL: %s" % label)
		_fail_count += 1
