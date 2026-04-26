extends SceneTree
## Unit tests for Helloscene_AnnotationHost.
## Run: godot --headless --script test/test_hello_annotation_host.gd
##
## Coverage:
##   - get_registry returns what was set via _registry
##   - add_annotation appends, assigns an id, and returns it
##   - add_annotation does not mutate the caller's dict
##   - get_annotations returns the live list
##   - set_annotations replaces the list (deep-copying entries)
##   - get_view_context() == "hello"
##   - Identity transforms (doc<->screen)
##   - annotations_changed signal fires on add and on set_annotations

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Hello Annotation Host Tests ===\n")

	test_get_registry_returns_what_was_set()
	test_get_registry_null_when_unset()
	test_add_annotation_appends_and_assigns_id()
	test_add_annotation_preserves_explicit_id()
	test_add_annotation_does_not_mutate_caller()
	test_get_annotations_returns_list()
	test_set_annotations_replaces_list()
	test_set_annotations_skips_non_dicts()
	test_view_context_is_hello()
	test_identity_transforms()
	test_annotations_changed_fires_on_add()
	test_annotations_changed_fires_on_set_annotations()
	test_update_annotation_happy_path()
	test_update_annotation_unknown_id_returns_false()
	test_update_annotation_preserves_id()
	test_remove_annotation_happy_path()
	test_remove_annotation_unknown_id_returns_false()
	test_remove_annotation_clears_selection()
	test_set_selected_annotation_id_fires_signal()
	test_set_selected_annotation_id_no_op_same_id()
	test_set_selected_annotation_id_clears_selection()
	test_get_selected_annotation_id_default_and_roundtrip()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

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
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_get_registry_returns_what_was_set() -> void:
	print("test_get_registry_returns_what_was_set:")
	var reg := AnnotationRegistry.new()
	var host := Helloscene_AnnotationHost.new()
	host._registry = reg
	check("host.get_registry() returns the assigned registry", host.get_registry() == reg)


func test_get_registry_null_when_unset() -> void:
	print("test_get_registry_null_when_unset:")
	var host := Helloscene_AnnotationHost.new()
	check("get_registry() is null before _registry is set", host.get_registry() == null)


func test_add_annotation_appends_and_assigns_id() -> void:
	print("test_add_annotation_appends_and_assigns_id:")
	var host := Helloscene_AnnotationHost.new()
	check_eq("annotations empty initially", host.get_annotations().size(), 0)

	var ann := {
		"kind": "2d_arrow",
		"author": "human",
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0]}],
	}
	var id := host.add_annotation(ann)

	check("returned id is non-empty", not id.is_empty())
	check("returned id starts with 'ann_'", id.begins_with("ann_"))
	check_eq("annotations list has one entry", host.get_annotations().size(), 1)

	var stored: Dictionary = host.get_annotations()[0]
	check_eq("stored annotation has matching id", str(stored.get("id", "")), id)
	check_eq("stored kind preserved", str(stored.get("kind", "")), "2d_arrow")


func test_add_annotation_preserves_explicit_id() -> void:
	print("test_add_annotation_preserves_explicit_id:")
	var host := Helloscene_AnnotationHost.new()
	var ann := {"id": "ann_explicit99", "kind": "2d_text"}
	var id := host.add_annotation(ann)
	check_eq("explicit id is preserved", id, "ann_explicit99")
	check_eq("stored entry retains explicit id",
		str((host.get_annotations()[0] as Dictionary).get("id", "")),
		"ann_explicit99")


func test_add_annotation_does_not_mutate_caller() -> void:
	print("test_add_annotation_does_not_mutate_caller:")
	var host := Helloscene_AnnotationHost.new()
	var ann := {"kind": "2d_arrow", "primitives": []}
	host.add_annotation(ann)
	check("caller's dict has no id field after add",
		not ann.has("id"))


func test_get_annotations_returns_list() -> void:
	print("test_get_annotations_returns_list:")
	var host := Helloscene_AnnotationHost.new()
	host.add_annotation({"kind": "2d_arrow"})
	host.add_annotation({"kind": "2d_text"})
	var anns := host.get_annotations()
	check_eq("get_annotations returns 2 entries", anns.size(), 2)
	check_eq("first entry kind", str((anns[0] as Dictionary).get("kind", "")), "2d_arrow")
	check_eq("second entry kind", str((anns[1] as Dictionary).get("kind", "")), "2d_text")


func test_set_annotations_replaces_list() -> void:
	print("test_set_annotations_replaces_list:")
	var host := Helloscene_AnnotationHost.new()
	host.add_annotation({"kind": "2d_arrow"})
	host.add_annotation({"kind": "2d_text"})
	check_eq("two entries after adds", host.get_annotations().size(), 2)

	var replacement: Array = [
		{"id": "ann_x", "kind": "2d_region"},
	]
	host.set_annotations(replacement)
	check_eq("one entry after set_annotations", host.get_annotations().size(), 1)
	check_eq("entry kind matches replacement",
		str((host.get_annotations()[0] as Dictionary).get("kind", "")),
		"2d_region")


func test_set_annotations_skips_non_dicts() -> void:
	print("test_set_annotations_skips_non_dicts:")
	var host := Helloscene_AnnotationHost.new()
	host.set_annotations([
		{"kind": "2d_arrow"},
		"not a dict",
		42,
		{"kind": "2d_text"},
	])
	check_eq("only the two Dictionary entries are kept",
		host.get_annotations().size(), 2)


func test_view_context_is_hello() -> void:
	print("test_view_context_is_hello:")
	var host := Helloscene_AnnotationHost.new()
	check_eq("get_view_context() returns 'hello'", host.get_view_context(), "hello")


func test_identity_transforms() -> void:
	print("test_identity_transforms:")
	var host := Helloscene_AnnotationHost.new()
	var p := Vector2(123.5, -42.0)
	check("doc_to_screen is identity", host.transform_doc_to_screen(p) == p)
	check("screen_to_doc is identity", host.transform_screen_to_doc(p) == p)
	check("round trip is identity",
		host.transform_screen_to_doc(host.transform_doc_to_screen(p)) == p)


func test_annotations_changed_fires_on_add() -> void:
	print("test_annotations_changed_fires_on_add:")
	var host := Helloscene_AnnotationHost.new()
	# Lambda capture by value workaround: wrap counter in an Array.
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	host.add_annotation({"kind": "2d_arrow"})
	check_eq("annotations_changed fired once after first add", fired[0], 1)
	host.add_annotation({"kind": "2d_text"})
	check_eq("annotations_changed fired twice after second add", fired[0], 2)


func test_annotations_changed_fires_on_set_annotations() -> void:
	print("test_annotations_changed_fires_on_set_annotations:")
	var host := Helloscene_AnnotationHost.new()
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	host.set_annotations([{"kind": "2d_arrow"}])
	check_eq("annotations_changed fired once after set_annotations", fired[0], 1)
	host.set_annotations([])
	check_eq("annotations_changed fires even on empty set", fired[0], 2)


func test_update_annotation_happy_path() -> void:
	print("test_update_annotation_happy_path:")
	var host := Helloscene_AnnotationHost.new()
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	var id := host.add_annotation({"kind": "2d_arrow"})
	fired[0] = 0  # reset counter after add

	var result := host.update_annotation(id, {"kind": "2d_text", "extra": "data"})
	check("update_annotation returns true for known id", result == true)
	check_eq("annotations_changed fired once after update", fired[0], 1)
	check_eq("list size unchanged after update", host.get_annotations().size(), 1)
	var stored: Dictionary = host.get_annotations()[0]
	check_eq("kind was mutated", str(stored.get("kind", "")), "2d_text")
	check_eq("extra field present", str(stored.get("extra", "")), "data")


func test_update_annotation_unknown_id_returns_false() -> void:
	print("test_update_annotation_unknown_id_returns_false:")
	var host := Helloscene_AnnotationHost.new()
	host.add_annotation({"kind": "2d_arrow"})
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	var result := host.update_annotation("ann_nonexistent", {"kind": "2d_text"})
	check("update_annotation returns false for unknown id", result == false)
	check_eq("annotations_changed NOT fired for unknown id", fired[0], 0)


func test_update_annotation_preserves_id() -> void:
	print("test_update_annotation_preserves_id:")
	var host := Helloscene_AnnotationHost.new()
	var id := host.add_annotation({"kind": "2d_arrow"})

	# Caller passes a dict without an id field — id must be stamped back on.
	var new_dict := {"kind": "2d_region"}
	var result := host.update_annotation(id, new_dict)
	check("update succeeds", result == true)
	var stored: Dictionary = host.get_annotations()[0]
	check_eq("id is re-stamped onto stored entry", str(stored.get("id", "")), id)
	check("caller's dict was not mutated with id", not new_dict.has("id"))


func test_remove_annotation_happy_path() -> void:
	print("test_remove_annotation_happy_path:")
	var host := Helloscene_AnnotationHost.new()
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	var id := host.add_annotation({"kind": "2d_arrow"})
	fired[0] = 0  # reset after add

	var result := host.remove_annotation(id)
	check("remove_annotation returns true for known id", result == true)
	check_eq("annotations_changed fired once after remove", fired[0], 1)
	check_eq("list is empty after remove", host.get_annotations().size(), 0)


func test_remove_annotation_unknown_id_returns_false() -> void:
	print("test_remove_annotation_unknown_id_returns_false:")
	var host := Helloscene_AnnotationHost.new()
	host.add_annotation({"kind": "2d_arrow"})
	var fired: Array = [0]
	host.annotations_changed.connect(func() -> void: fired[0] += 1)

	var result := host.remove_annotation("ann_does_not_exist")
	check("remove_annotation returns false for unknown id", result == false)
	check_eq("annotations_changed NOT fired for unknown id", fired[0], 0)
	check_eq("list unchanged", host.get_annotations().size(), 1)


func test_remove_annotation_clears_selection() -> void:
	print("test_remove_annotation_clears_selection:")
	var host := Helloscene_AnnotationHost.new()
	var sel_fired: Array = ["unset"]
	host.selection_changed.connect(func(ann_id: String) -> void: sel_fired[0] = ann_id)

	var id := host.add_annotation({"kind": "2d_arrow"})
	host.set_selected_annotation_id(id)
	sel_fired[0] = "unset"  # reset after selection set

	var result := host.remove_annotation(id)
	check("remove returns true", result == true)
	check_eq("selection_changed fired with empty string", sel_fired[0], "")
	check_eq("get_selected_annotation_id returns empty", host.get_selected_annotation_id(), "")


func test_set_selected_annotation_id_fires_signal() -> void:
	print("test_set_selected_annotation_id_fires_signal:")
	var host := Helloscene_AnnotationHost.new()
	var sel_fired: Array = ["unset"]
	host.selection_changed.connect(func(ann_id: String) -> void: sel_fired[0] = ann_id)

	host.set_selected_annotation_id("ann_abc")
	check_eq("selection_changed emitted with new id", sel_fired[0], "ann_abc")
	check_eq("get_selected_annotation_id returns set value",
		host.get_selected_annotation_id(), "ann_abc")


func test_set_selected_annotation_id_no_op_same_id() -> void:
	print("test_set_selected_annotation_id_no_op_same_id:")
	var host := Helloscene_AnnotationHost.new()
	var count: Array = [0]
	host.selection_changed.connect(func(_ann_id: String) -> void: count[0] += 1)

	host.set_selected_annotation_id("ann_abc")
	check_eq("signal fired once on first set", count[0], 1)
	host.set_selected_annotation_id("ann_abc")
	check_eq("signal NOT fired again for same id", count[0], 1)


func test_set_selected_annotation_id_clears_selection() -> void:
	print("test_set_selected_annotation_id_clears_selection:")
	var host := Helloscene_AnnotationHost.new()
	var sel_fired: Array = ["unset"]
	host.selection_changed.connect(func(ann_id: String) -> void: sel_fired[0] = ann_id)

	host.set_selected_annotation_id("ann_abc")
	sel_fired[0] = "unset"  # reset

	host.set_selected_annotation_id("")
	check_eq("selection_changed fired with empty string", sel_fired[0], "")
	check_eq("get_selected_annotation_id returns empty", host.get_selected_annotation_id(), "")


func test_get_selected_annotation_id_default_and_roundtrip() -> void:
	print("test_get_selected_annotation_id_default_and_roundtrip:")
	var host := Helloscene_AnnotationHost.new()
	check_eq("default selected id is empty string", host.get_selected_annotation_id(), "")

	host.set_selected_annotation_id("ann_xyz")
	check_eq("roundtrip: get returns what was set", host.get_selected_annotation_id(), "ann_xyz")

	host.set_selected_annotation_id("")
	check_eq("roundtrip: cleared id returns empty", host.get_selected_annotation_id(), "")
