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
