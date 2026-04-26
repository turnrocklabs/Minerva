extends SceneTree
## Unit tests for AnnotationSchema, AnnotationKind, and AnnotationRegistry.
## Run: godot --headless --script test/test_annotation_substrate.gd
##
## Coverage:
##   AnnotationSchema
##     - Valid full annotation passes
##     - Missing required fields produce structured errors with correct field_path
##     - Bad author value produces enum error
##     - Bad id format produces format error
##     - Bad created_at produces format error
##     - primitives[] array validated recursively; each primitive kind checked
##     - Arrow primitive: valid / missing from / missing to / bad coordinate type
##     - Text primitive: valid / missing content / missing at
##     - Region primitive: valid / too few points / non-array point
##     - Polyline primitive: valid / too few points
##     - Highlight primitive: valid / bad rect
##     - Measure distance: valid / missing fields
##     - Measure angle: valid / missing fields
##     - Measure radius: valid / missing fields
##     - ink_stroke: recognized (post-MVP, no deep validation)
##     - Unknown primitive kind: tolerated (no error)
##     - primitives_optional=true: empty primitives[] accepted
##     - generate_id() format
##     - is_core_kind() / is_valid_plugin_kind_name()
##
##   AnnotationKind (base class)
##     - bounds_from_primitives() covers all known primitive shapes
##     - bounds_from_primitives() with unknown kind returns zero Rect2
##     - Default hit_test() delegates to bounds()
##
##   AnnotationRegistry
##     - register / get / list / count / has_kind
##     - Duplicate registration rejected (returns false, kind not overwritten)
##     - 2d_* prefix rejected for non-core plugins
##     - Core may register 2d_* kinds
##     - deregister returns true / false appropriately
##     - deregister fires signal
##     - register fires signal
##     - dispatch_bounds() for known kind
##     - dispatch_bounds() for unknown kind falls back to primitives AABB
##     - dispatch_hit_test() for unknown kind falls back to bounds AABB
##     - dispatch_validate() for unknown kind returns empty array

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Annotation Substrate Tests ===\n")

	# AnnotationSchema
	print("-- AnnotationSchema: envelope --")
	test_valid_annotation_passes()
	test_missing_id_fails()
	test_missing_kind_fails()
	test_missing_view_context_fails()
	test_missing_created_at_fails()
	test_missing_author_fails()
	test_bad_author_enum_fails()
	test_bad_id_format_fails()
	test_bad_created_at_format_fails()
	test_bad_updated_at_format_fails()
	test_missing_primitives_fails()
	test_primitives_not_array_fails()
	test_primitives_optional_empty_passes()

	print("\n-- AnnotationSchema: arrow primitive --")
	test_arrow_valid()
	test_arrow_missing_from()
	test_arrow_missing_to()
	test_arrow_bad_from_type()
	test_arrow_bad_coordinate_type()
	test_arrow_optional_head_size()

	print("\n-- AnnotationSchema: text primitive --")
	test_text_valid()
	test_text_missing_at()
	test_text_missing_content()

	print("\n-- AnnotationSchema: region primitive --")
	test_region_valid()
	test_region_too_few_points()
	test_region_non_array_point()

	print("\n-- AnnotationSchema: polyline primitive --")
	test_polyline_valid()
	test_polyline_too_few_points()

	print("\n-- AnnotationSchema: highlight primitive --")
	test_highlight_valid()
	test_highlight_bad_rect()
	test_highlight_missing_rect()

	print("\n-- AnnotationSchema: measure_distance primitive --")
	test_measure_distance_valid()
	test_measure_distance_missing_from()

	print("\n-- AnnotationSchema: measure_angle primitive --")
	test_measure_angle_valid()
	test_measure_angle_missing_b()

	print("\n-- AnnotationSchema: measure_radius primitive --")
	test_measure_radius_valid()
	test_measure_radius_missing_center()

	print("\n-- AnnotationSchema: ink_stroke primitive (post-MVP) --")
	test_ink_stroke_recognized()
	test_ink_stroke_missing_points()

	print("\n-- AnnotationSchema: unknown primitive kind --")
	test_unknown_primitive_kind_tolerated()

	print("\n-- AnnotationSchema: anchored_to field --")
	test_anchored_to_accepted()
	test_anchored_to_absent_still_valid()
	test_anchored_to_non_string_rejected()
	test_get_anchored_to_helper()

	print("\n-- AnnotationSchema: generate_id / namespace helpers --")
	test_generate_id_format()
	test_is_core_kind()
	test_is_valid_plugin_kind_name()

	print("\n-- AnnotationKind: bounds_from_primitives --")
	test_bounds_arrow()
	test_bounds_text()
	test_bounds_region()
	test_bounds_polyline()
	test_bounds_highlight()
	test_bounds_measure_distance()
	test_bounds_measure_angle()
	test_bounds_measure_radius()
	test_bounds_ink_stroke_4col()
	test_bounds_unknown_primitive()
	test_bounds_empty_primitives()
	test_default_hit_test_uses_bounds()

	print("\n-- AnnotationRegistry --")
	test_registry_register_get()
	test_registry_list_count()
	test_registry_has_kind()
	test_registry_duplicate_rejected()
	test_registry_core_2d_prefix_allowed()
	test_registry_plugin_2d_prefix_rejected()
	test_registry_deregister()
	test_registry_deregister_nonexistent()
	test_registry_register_fires_signal()
	test_registry_deregister_fires_signal()
	test_registry_dispatch_bounds_known()
	test_registry_dispatch_bounds_unknown()
	test_registry_dispatch_hit_test_unknown()
	test_registry_dispatch_validate_unknown()

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


# ── Fixture helpers ───────────────────────────────────────────────────────────

func _valid_annotation() -> Dictionary:
	return {
		"id":           "ann_abc123",
		"author":       "human",
		"kind":         "2d_arrow",
		"view_context": "pcb",
		"primitives":   [_valid_arrow()],
		"created_at":   "2026-04-23T14:22:01Z",
	}


func _valid_arrow() -> Dictionary:
	return {"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0]}


func _valid_text() -> Dictionary:
	return {"kind": "text", "at": [5.0, 5.0], "content": "hello"}


func _valid_region() -> Dictionary:
	return {"kind": "region", "points": [[0.0, 0.0], [10.0, 0.0], [5.0, 8.0]]}


func _valid_polyline() -> Dictionary:
	return {"kind": "polyline", "points": [[0.0, 0.0], [5.0, 5.0], [10.0, 0.0]]}


func _valid_highlight() -> Dictionary:
	return {"kind": "highlight", "rect": [1.0, 2.0, 8.0, 4.0]}


func _valid_measure_distance() -> Dictionary:
	return {"kind": "measure_distance", "from": [0.0, 0.0], "to": [10.0, 0.0]}


func _valid_measure_angle() -> Dictionary:
	return {"kind": "measure_angle",
		"a": [0.0, 0.0], "b": [5.0, 5.0], "c": [10.0, 0.0]}


func _valid_measure_radius() -> Dictionary:
	return {"kind": "measure_radius", "center": [5.0, 5.0], "edge": [10.0, 5.0]}


func _has_error_for(result: AnnotationSchema.ValidationResult, field: String) -> bool:
	for e in result.errors:
		if field in e.field_path:
			return true
	return false


func _error_code_for(result: AnnotationSchema.ValidationResult, field: String) -> String:
	for e in result.errors:
		if field in e.field_path:
			return e.code
	return ""


# ── AnnotationSchema: envelope tests ─────────────────────────────────────────

func test_valid_annotation_passes() -> void:
	print("test_valid_annotation_passes:")
	var r := AnnotationSchema.validate_annotation(_valid_annotation())
	check("valid annotation has no errors", not r.has_errors())


func test_missing_id_fails() -> void:
	print("test_missing_id_fails:")
	var ann := _valid_annotation()
	ann.erase("id")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing id → has_errors", r.has_errors())
	check("missing id → error on 'id'", _has_error_for(r, "id"))
	check("missing id → code=required", _error_code_for(r, "id") == "required")


func test_missing_kind_fails() -> void:
	print("test_missing_kind_fails:")
	var ann := _valid_annotation()
	ann.erase("kind")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing kind → has_errors", r.has_errors())
	check("missing kind → error on 'kind'", _has_error_for(r, "kind"))


func test_missing_view_context_fails() -> void:
	print("test_missing_view_context_fails:")
	var ann := _valid_annotation()
	ann.erase("view_context")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing view_context → has_errors", r.has_errors())
	check("missing view_context → error on 'view_context'", _has_error_for(r, "view_context"))


func test_missing_created_at_fails() -> void:
	print("test_missing_created_at_fails:")
	var ann := _valid_annotation()
	ann.erase("created_at")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing created_at → has_errors", r.has_errors())
	check("missing created_at → error on 'created_at'", _has_error_for(r, "created_at"))


func test_missing_author_fails() -> void:
	print("test_missing_author_fails:")
	var ann := _valid_annotation()
	ann.erase("author")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing author → has_errors", r.has_errors())
	check("missing author → error on 'author'", _has_error_for(r, "author"))


func test_bad_author_enum_fails() -> void:
	print("test_bad_author_enum_fails:")
	var ann := _valid_annotation()
	ann["author"] = "robot"
	var r := AnnotationSchema.validate_annotation(ann)
	check("bad author → has_errors", r.has_errors())
	check("bad author → code=enum", _error_code_for(r, "author") == "enum")


func test_bad_id_format_fails() -> void:
	print("test_bad_id_format_fails:")
	var ann := _valid_annotation()
	ann["id"] = "wrong_prefix_123"
	var r := AnnotationSchema.validate_annotation(ann)
	check("bad id prefix → has_errors", r.has_errors())
	check("bad id prefix → code=format", _error_code_for(r, "id") == "format")


func test_bad_created_at_format_fails() -> void:
	print("test_bad_created_at_format_fails:")
	var ann := _valid_annotation()
	ann["created_at"] = "not-a-date"
	var r := AnnotationSchema.validate_annotation(ann)
	check("bad created_at → has_errors", r.has_errors())
	check("bad created_at → error on created_at", _has_error_for(r, "created_at"))
	check("bad created_at → code=format", _error_code_for(r, "created_at") == "format")


func test_bad_updated_at_format_fails() -> void:
	print("test_bad_updated_at_format_fails:")
	var ann := _valid_annotation()
	ann["updated_at"] = "2026/04/23"
	var r := AnnotationSchema.validate_annotation(ann)
	check("bad updated_at → has_errors", r.has_errors())
	check("bad updated_at → error on updated_at", _has_error_for(r, "updated_at"))


func test_missing_primitives_fails() -> void:
	print("test_missing_primitives_fails:")
	var ann := _valid_annotation()
	ann.erase("primitives")
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing primitives (not optional) → has_errors", r.has_errors())
	check("missing primitives → error on 'primitives'", _has_error_for(r, "primitives"))


func test_primitives_not_array_fails() -> void:
	print("test_primitives_not_array_fails:")
	var ann := _valid_annotation()
	ann["primitives"] = "not-an-array"
	var r := AnnotationSchema.validate_annotation(ann)
	check("primitives not array → has_errors", r.has_errors())
	check("primitives not array → code=type", _error_code_for(r, "primitives") == "type")


func test_primitives_optional_empty_passes() -> void:
	print("test_primitives_optional_empty_passes:")
	var ann := _valid_annotation()
	ann["primitives"] = []
	var r := AnnotationSchema.validate_annotation(ann, true)
	check("empty primitives[] with optional=true → no errors", not r.has_errors())

	# And absent primitives with optional=true also passes
	var ann2 := _valid_annotation()
	ann2.erase("primitives")
	var r2 := AnnotationSchema.validate_annotation(ann2, true)
	check("absent primitives with optional=true → no errors", not r2.has_errors())


# ── Arrow primitive tests ─────────────────────────────────────────────────────

func test_arrow_valid() -> void:
	print("test_arrow_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_arrow())
	check("valid arrow → no errors", not r.has_errors())


func test_arrow_missing_from() -> void:
	print("test_arrow_missing_from:")
	var p := {"kind": "arrow", "to": [10.0, 10.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing from → has_errors", r.has_errors())
	check("missing from → error on 'from'", _has_error_for(r, "from"))


func test_arrow_missing_to() -> void:
	print("test_arrow_missing_to:")
	var p := {"kind": "arrow", "from": [0.0, 0.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing to → has_errors", r.has_errors())
	check("missing to → error on 'to'", _has_error_for(r, "to"))


func test_arrow_bad_from_type() -> void:
	print("test_arrow_bad_from_type:")
	var p := {"kind": "arrow", "from": "not-a-point", "to": [10.0, 10.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("bad from type → has_errors", r.has_errors())
	check("bad from type → code=type", _error_code_for(r, "from") == "type")


func test_arrow_bad_coordinate_type() -> void:
	print("test_arrow_bad_coordinate_type:")
	var p := {"kind": "arrow", "from": ["x", "y"], "to": [10.0, 10.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("bad coord type in from → has_errors", r.has_errors())


func test_arrow_optional_head_size() -> void:
	print("test_arrow_optional_head_size:")
	var p := {"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0], "head_size": 2.0}
	var r := AnnotationSchema.validate_primitive(p)
	check("arrow with head_size → no errors", not r.has_errors())

	var p2 := {"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0], "head_size": -1.0}
	var r2 := AnnotationSchema.validate_primitive(p2)
	check("arrow with negative head_size → has_errors", r2.has_errors())
	check("negative head_size → code=range", _error_code_for(r2, "head_size") == "range")


# ── Text primitive tests ──────────────────────────────────────────────────────

func test_text_valid() -> void:
	print("test_text_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_text())
	check("valid text → no errors", not r.has_errors())


func test_text_missing_at() -> void:
	print("test_text_missing_at:")
	var p := {"kind": "text", "content": "hello"}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing at → has_errors", r.has_errors())
	check("missing at → error on 'at'", _has_error_for(r, "at"))


func test_text_missing_content() -> void:
	print("test_text_missing_content:")
	var p := {"kind": "text", "at": [0.0, 0.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing content → has_errors", r.has_errors())
	check("missing content → error on 'content'", _has_error_for(r, "content"))


# ── Region primitive tests ────────────────────────────────────────────────────

func test_region_valid() -> void:
	print("test_region_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_region())
	check("valid region → no errors", not r.has_errors())


func test_region_too_few_points() -> void:
	print("test_region_too_few_points:")
	var p := {"kind": "region", "points": [[0.0, 0.0], [1.0, 1.0]]}
	var r := AnnotationSchema.validate_primitive(p)
	check("2-point region → has_errors (need ≥3)", r.has_errors())
	check("2-point region → code=range", _error_code_for(r, "points") == "range")


func test_region_non_array_point() -> void:
	print("test_region_non_array_point:")
	var p := {"kind": "region", "points": [[0.0, 0.0], "bad", [5.0, 5.0]]}
	var r := AnnotationSchema.validate_primitive(p)
	check("non-array point → has_errors", r.has_errors())


# ── Polyline primitive tests ──────────────────────────────────────────────────

func test_polyline_valid() -> void:
	print("test_polyline_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_polyline())
	check("valid polyline → no errors", not r.has_errors())


func test_polyline_too_few_points() -> void:
	print("test_polyline_too_few_points:")
	var p := {"kind": "polyline", "points": [[0.0, 0.0]]}
	var r := AnnotationSchema.validate_primitive(p)
	check("1-point polyline → has_errors (need ≥2)", r.has_errors())


# ── Highlight primitive tests ─────────────────────────────────────────────────

func test_highlight_valid() -> void:
	print("test_highlight_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_highlight())
	check("valid highlight → no errors", not r.has_errors())


func test_highlight_bad_rect() -> void:
	print("test_highlight_bad_rect:")
	var p := {"kind": "highlight", "rect": [1.0, 2.0, 3.0]}  # only 3 elements
	var r := AnnotationSchema.validate_primitive(p)
	check("3-element rect → has_errors", r.has_errors())
	check("3-element rect → code=type", _error_code_for(r, "rect") == "type")


func test_highlight_missing_rect() -> void:
	print("test_highlight_missing_rect:")
	var p := {"kind": "highlight"}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing rect → has_errors", r.has_errors())
	check("missing rect → code=required", _error_code_for(r, "rect") == "required")


# ── Measure_distance primitive tests ─────────────────────────────────────────

func test_measure_distance_valid() -> void:
	print("test_measure_distance_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_measure_distance())
	check("valid measure_distance → no errors", not r.has_errors())


func test_measure_distance_missing_from() -> void:
	print("test_measure_distance_missing_from:")
	var p := {"kind": "measure_distance", "to": [10.0, 0.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing from → has_errors", r.has_errors())
	check("missing from → error on 'from'", _has_error_for(r, "from"))


# ── Measure_angle primitive tests ─────────────────────────────────────────────

func test_measure_angle_valid() -> void:
	print("test_measure_angle_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_measure_angle())
	check("valid measure_angle → no errors", not r.has_errors())


func test_measure_angle_missing_b() -> void:
	print("test_measure_angle_missing_b:")
	var p := {"kind": "measure_angle", "a": [0.0, 0.0], "c": [10.0, 0.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing b → has_errors", r.has_errors())
	check("missing b → error on 'b'", _has_error_for(r, ".b"))


# ── Measure_radius primitive tests ────────────────────────────────────────────

func test_measure_radius_valid() -> void:
	print("test_measure_radius_valid:")
	var r := AnnotationSchema.validate_primitive(_valid_measure_radius())
	check("valid measure_radius → no errors", not r.has_errors())


func test_measure_radius_missing_center() -> void:
	print("test_measure_radius_missing_center:")
	var p := {"kind": "measure_radius", "edge": [10.0, 5.0]}
	var r := AnnotationSchema.validate_primitive(p)
	check("missing center → has_errors", r.has_errors())
	check("missing center → error on 'center'", _has_error_for(r, "center"))


# ── ink_stroke primitive tests ────────────────────────────────────────────────

func test_ink_stroke_recognized() -> void:
	print("test_ink_stroke_recognized:")
	var p := {"kind": "ink_stroke", "points": [[0.0, 0.0, 0.5, 0], [5.0, 5.0, 0.8, 100]]}
	var r := AnnotationSchema.validate_primitive(p)
	check("valid ink_stroke → no errors (post-MVP, shallow validation)", not r.has_errors())


func test_ink_stroke_missing_points() -> void:
	print("test_ink_stroke_missing_points:")
	var p := {"kind": "ink_stroke"}
	var r := AnnotationSchema.validate_primitive(p)
	check("ink_stroke missing points → has_errors", r.has_errors())
	check("ink_stroke missing points → code=required", _error_code_for(r, "points") == "required")


# ── Unknown primitive kind ────────────────────────────────────────────────────

func test_unknown_primitive_kind_tolerated() -> void:
	print("test_unknown_primitive_kind_tolerated:")
	var p := {"kind": "future_kind_xyz", "data": [1, 2, 3]}
	var r := AnnotationSchema.validate_primitive(p)
	check("unknown primitive kind → no errors (preserved verbatim)", not r.has_errors())


# ── AnnotationSchema: anchored_to field ──────────────────────────────────────

func test_anchored_to_accepted() -> void:
	print("test_anchored_to_accepted:")
	var ann := _valid_annotation()
	ann["anchored_to"] = "comp:R5"
	var r := AnnotationSchema.validate_annotation(ann)
	check("anchored_to string value accepted", not r.has_errors())


func test_anchored_to_absent_still_valid() -> void:
	print("test_anchored_to_absent_still_valid:")
	var ann := _valid_annotation()
	# No anchored_to key at all — must still pass
	var r := AnnotationSchema.validate_annotation(ann)
	check("missing anchored_to is still valid", not r.has_errors())


func test_anchored_to_non_string_rejected() -> void:
	print("test_anchored_to_non_string_rejected:")
	var ann := _valid_annotation()
	ann["anchored_to"] = 42
	var r := AnnotationSchema.validate_annotation(ann)
	check("non-string anchored_to → has_errors", r.has_errors())
	check("non-string anchored_to → error on 'anchored_to'", _has_error_for(r, "anchored_to"))
	check("non-string anchored_to → code=type", _error_code_for(r, "anchored_to") == "type")


func test_get_anchored_to_helper() -> void:
	print("test_get_anchored_to_helper:")
	var ann := _valid_annotation()
	ann["anchored_to"] = "net:VCC"
	check_eq("get_anchored_to returns value when present",
		AnnotationSchema.get_anchored_to(ann), "net:VCC")
	var ann2 := _valid_annotation()
	check_eq("get_anchored_to returns '' when absent",
		AnnotationSchema.get_anchored_to(ann2), "")


# ── generate_id / namespace helpers ──────────────────────────────────────────

func test_generate_id_format() -> void:
	print("test_generate_id_format:")
	var id1 := AnnotationSchema.generate_id()
	var id2 := AnnotationSchema.generate_id()
	check("generated id starts with 'ann_'", id1.begins_with("ann_"))
	check("generated id length >= 10", id1.length() >= 10)
	# IDs should differ (with overwhelming probability for a random 24-bit value)
	check("two generated ids are different", id1 != id2)


func test_is_core_kind() -> void:
	print("test_is_core_kind:")
	check("2d_arrow is core", AnnotationSchema.is_core_kind(&"2d_arrow"))
	check("2d_text is core", AnnotationSchema.is_core_kind(&"2d_text"))
	check("cad_3d_plane is not core", not AnnotationSchema.is_core_kind(&"cad_3d_plane"))
	check("pcb_route_hint is not core", not AnnotationSchema.is_core_kind(&"pcb_route_hint"))


func test_is_valid_plugin_kind_name() -> void:
	print("test_is_valid_plugin_kind_name:")
	check("cad_plane is valid plugin name", AnnotationSchema.is_valid_plugin_kind_name(&"cad_plane"))
	check("2d_arrow is NOT a valid plugin name", not AnnotationSchema.is_valid_plugin_kind_name(&"2d_arrow"))
	check("empty string is not valid", not AnnotationSchema.is_valid_plugin_kind_name(&""))


# ── AnnotationKind: bounds_from_primitives ────────────────────────────────────

func test_bounds_arrow() -> void:
	print("test_bounds_arrow:")
	var prims := [{"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 5.0]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("arrow bounds x=0", b.position.x == 0.0)
	check("arrow bounds y=0", b.position.y == 0.0)
	check("arrow bounds width=10", b.size.x == 10.0)
	check("arrow bounds height=5", b.size.y == 5.0)


func test_bounds_text() -> void:
	print("test_bounds_text:")
	var prims := [{"kind": "text", "at": [3.0, 7.0], "content": "hi"}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("text bounds position x=3", b.position.x == 3.0)
	check("text bounds position y=7", b.position.y == 7.0)
	# size is approximate (50×12) — just check it's non-zero
	check("text bounds non-zero size", b.size.x > 0 and b.size.y > 0)


func test_bounds_region() -> void:
	print("test_bounds_region:")
	var prims := [{"kind": "region", "points": [[0.0, 0.0], [8.0, 0.0], [4.0, 6.0]]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("region bounds width=8", b.size.x == 8.0)
	check("region bounds height=6", b.size.y == 6.0)


func test_bounds_polyline() -> void:
	print("test_bounds_polyline:")
	var prims := [{"kind": "polyline", "points": [[2.0, 2.0], [8.0, 2.0], [5.0, 7.0]]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("polyline bounds x starts at 2", b.position.x == 2.0)
	check("polyline bounds y starts at 2", b.position.y == 2.0)
	check("polyline bounds width=6", b.size.x == 6.0)
	check("polyline bounds height=5", b.size.y == 5.0)


func test_bounds_highlight() -> void:
	print("test_bounds_highlight:")
	var prims := [{"kind": "highlight", "rect": [3.0, 4.0, 9.0, 5.0]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("highlight bounds x=3", b.position.x == 3.0)
	check("highlight bounds y=4", b.position.y == 4.0)
	check("highlight bounds w=9", b.size.x == 9.0)
	check("highlight bounds h=5", b.size.y == 5.0)


func test_bounds_measure_distance() -> void:
	print("test_bounds_measure_distance:")
	var prims := [{"kind": "measure_distance", "from": [1.0, 1.0], "to": [11.0, 6.0]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("measure_distance bounds x=1", b.position.x == 1.0)
	check("measure_distance bounds width=10", b.size.x == 10.0)


func test_bounds_measure_angle() -> void:
	print("test_bounds_measure_angle:")
	var prims := [{"kind": "measure_angle",
		"a": [0.0, 0.0], "b": [5.0, 5.0], "c": [10.0, 0.0]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("measure_angle bounds width=10", b.size.x == 10.0)
	check("measure_angle bounds height=5", b.size.y == 5.0)


func test_bounds_measure_radius() -> void:
	print("test_bounds_measure_radius:")
	var prims := [{"kind": "measure_radius", "center": [5.0, 5.0], "edge": [10.0, 5.0]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	# radius=5, so bounding box is (0,0) 10x10
	check("measure_radius bounds x=0", b.position.x == 0.0)
	check("measure_radius bounds y=0", b.position.y == 0.0)
	check("measure_radius bounds w=10", b.size.x == 10.0)
	check("measure_radius bounds h=10", b.size.y == 10.0)


func test_bounds_ink_stroke_4col() -> void:
	print("test_bounds_ink_stroke_4col:")
	var prims := [{"kind": "ink_stroke",
		"points": [[1.0, 2.0, 0.5, 0], [9.0, 8.0, 0.9, 100]]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	check("ink_stroke bounds x=1", b.position.x == 1.0)
	check("ink_stroke bounds y=2", b.position.y == 2.0)
	check("ink_stroke bounds w=8", b.size.x == 8.0)
	check("ink_stroke bounds h=6", b.size.y == 6.0)


func test_bounds_unknown_primitive() -> void:
	print("test_bounds_unknown_primitive:")
	var prims := [{"kind": "future_prim", "data": [1, 2, 3]}]
	var b := AnnotationKind.bounds_from_primitives(prims)
	# Unknown primitive returns zero Rect2; the array returns zero Rect2 too
	check("unknown primitive → zero Rect2 (no crash)", b.size == Vector2.ZERO and b.position == Vector2.ZERO)


func test_bounds_empty_primitives() -> void:
	print("test_bounds_empty_primitives:")
	var b := AnnotationKind.bounds_from_primitives([])
	check("empty primitives → zero Rect2", b.size == Vector2.ZERO and b.position == Vector2.ZERO)


func test_default_hit_test_uses_bounds() -> void:
	print("test_default_hit_test_uses_bounds:")
	# Use a mock kind that overrides bounds() but not hit_test()
	var kind := _MockKindWithBounds.new()
	# bounds() returns Rect2(0,0,10,10)
	var annotation := {}
	# Point inside the bounds should hit
	check("point inside bounds → hit_test true", kind.hit_test(annotation, Vector2(5, 5), 0))
	# Point outside bounds but within threshold
	check("point at boundary+threshold → hit_test true", kind.hit_test(annotation, Vector2(11, 5), 2))
	# Point clearly outside
	check("point clearly outside → hit_test false", not kind.hit_test(annotation, Vector2(100, 100), 1))


# ── AnnotationRegistry tests ──────────────────────────────────────────────────

func test_registry_register_get() -> void:
	print("test_registry_register_get:")
	var reg := AnnotationRegistry.new()
	var kind := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	var ok := reg.register_annotation_kind(kind)
	check("register returns true", ok)
	var retrieved := reg.get_annotation_kind(&"cad_plane")
	check("get returns registered kind", retrieved == kind)
	check("get unknown returns null", reg.get_annotation_kind(&"nonexistent") == null)


func test_registry_list_count() -> void:
	print("test_registry_list_count:")
	var reg := AnnotationRegistry.new()
	check("empty registry has count=0", reg.count() == 0)
	var k1 := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	var k2 := _make_kind(&"pcb_hint",  "PCB Hint",  &"pcb")
	reg.register_annotation_kind(k1)
	reg.register_annotation_kind(k2)
	check("count=2 after two registrations", reg.count() == 2)
	var kinds := reg.list_annotation_kinds()
	check("list returns 2 items", kinds.size() == 2)
	check("list contains k1", k1 in kinds)
	check("list contains k2", k2 in kinds)


func test_registry_has_kind() -> void:
	print("test_registry_has_kind:")
	var reg := AnnotationRegistry.new()
	var kind := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	reg.register_annotation_kind(kind)
	check("has_kind returns true for registered", reg.has_kind(&"cad_plane"))
	check("has_kind returns false for unregistered", not reg.has_kind(&"nope"))


func test_registry_duplicate_rejected() -> void:
	print("test_registry_duplicate_rejected:")
	var reg := AnnotationRegistry.new()
	var k1 := _make_kind(&"cad_plane", "CAD Plane v1", &"cad")
	var k2 := _make_kind(&"cad_plane", "CAD Plane v2", &"cad")
	reg.register_annotation_kind(k1)
	var ok := reg.register_annotation_kind(k2)
	check("duplicate register returns false", not ok)
	check("original kind preserved (not overwritten)",
		reg.get_annotation_kind(&"cad_plane").display_name == "CAD Plane v1")
	check("count remains 1", reg.count() == 1)


func test_registry_core_2d_prefix_allowed() -> void:
	print("test_registry_core_2d_prefix_allowed:")
	var reg := AnnotationRegistry.new()
	var kind := _make_kind(&"2d_arrow", "Arrow", &"core")
	var ok := reg.register_annotation_kind(kind)
	check("core can register 2d_* kind", ok)


func test_registry_plugin_2d_prefix_rejected() -> void:
	print("test_registry_plugin_2d_prefix_rejected:")
	var reg := AnnotationRegistry.new()
	var kind := _make_kind(&"2d_custom", "Custom", &"myplugin")
	var ok := reg.register_annotation_kind(kind)
	check("plugin cannot register 2d_* kind (returns false)", not ok)
	check("rejected kind is not in registry", reg.get_annotation_kind(&"2d_custom") == null)


func test_registry_deregister() -> void:
	print("test_registry_deregister:")
	var reg := AnnotationRegistry.new()
	var kind := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	reg.register_annotation_kind(kind)
	var ok := reg.deregister_annotation_kind(&"cad_plane")
	check("deregister returns true", ok)
	check("kind no longer in registry", reg.get_annotation_kind(&"cad_plane") == null)
	check("count=0 after deregister", reg.count() == 0)


func test_registry_deregister_nonexistent() -> void:
	print("test_registry_deregister_nonexistent:")
	var reg := AnnotationRegistry.new()
	var ok := reg.deregister_annotation_kind(&"never_registered")
	check("deregister non-existent returns false", not ok)


func test_registry_register_fires_signal() -> void:
	print("test_registry_register_fires_signal:")
	var reg := AnnotationRegistry.new()
	var captured: Array = [&""]  # Array wrapper — GDScript lambdas capture locals by value
	reg.annotation_kind_registered.connect(func(n): captured[0] = n)
	var kind := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	reg.register_annotation_kind(kind)
	check("register fires annotation_kind_registered", captured[0] == &"cad_plane")


func test_registry_deregister_fires_signal() -> void:
	print("test_registry_deregister_fires_signal:")
	var reg := AnnotationRegistry.new()
	var captured: Array = [&""]  # Array wrapper — GDScript lambdas capture locals by value
	reg.annotation_kind_deregistered.connect(func(n): captured[0] = n)
	var kind := _make_kind(&"cad_plane", "CAD Plane", &"cad")
	reg.register_annotation_kind(kind)
	reg.deregister_annotation_kind(&"cad_plane")
	check("deregister fires annotation_kind_deregistered", captured[0] == &"cad_plane")


func test_registry_dispatch_bounds_known() -> void:
	print("test_registry_dispatch_bounds_known:")
	var reg := AnnotationRegistry.new()
	var kind := _MockKindWithBounds.new()
	kind.name = &"mock_kind"
	kind.display_name = "Mock"
	kind.owning_plugin = &"test"
	reg.register_annotation_kind(kind)
	var annotation := {"kind": "mock_kind", "primitives": []}
	var b := reg.dispatch_bounds(annotation)
	check("dispatch_bounds for known kind returns kind.bounds()", b == Rect2(0, 0, 10, 10))


func test_registry_dispatch_bounds_unknown() -> void:
	print("test_registry_dispatch_bounds_unknown:")
	var reg := AnnotationRegistry.new()
	var annotation := {
		"kind": "unknown_kind",
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [6.0, 4.0]}]
	}
	var b := reg.dispatch_bounds(annotation)
	# Should fall back to bounds_from_primitives
	check("dispatch_bounds for unknown falls back to primitives AABB", b.size.x == 6.0)
	check("dispatch_bounds fallback height", b.size.y == 4.0)


func test_registry_dispatch_hit_test_unknown() -> void:
	print("test_registry_dispatch_hit_test_unknown:")
	var reg := AnnotationRegistry.new()
	var annotation := {
		"kind": "unknown_kind",
		"primitives": [{"kind": "highlight", "rect": [0.0, 0.0, 10.0, 10.0]}]
	}
	# Point inside highlight bounds should hit
	check("dispatch_hit_test unknown kind inside bounds → true",
		reg.dispatch_hit_test(annotation, Vector2(5, 5), 0))
	# Point outside should miss
	check("dispatch_hit_test unknown kind outside bounds → false",
		not reg.dispatch_hit_test(annotation, Vector2(100, 100), 0))


func test_registry_dispatch_validate_unknown() -> void:
	print("test_registry_dispatch_validate_unknown:")
	var reg := AnnotationRegistry.new()
	var annotation := {"kind": "unknown_kind", "primitives": []}
	var errors := reg.dispatch_validate(annotation)
	check("dispatch_validate for unknown kind returns empty array", errors.size() == 0)


# ── Mock helpers ──────────────────────────────────────────────────────────────

func _make_kind(p_name: StringName, p_display: String, p_plugin: StringName) -> AnnotationKind:
	var k := AnnotationKind.new()
	k.name           = p_name
	k.display_name   = p_display
	k.owning_plugin  = p_plugin
	return k


## A minimal AnnotationKind subclass that overrides bounds() to return a fixed
## Rect2(0,0,10,10) — used to test default hit_test() delegation.
class _MockKindWithBounds extends AnnotationKind:
	func _init() -> void:
		name          = &"mock_kind"
		display_name  = "Mock"
		owning_plugin = &"test"

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass  # no-op for tests

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(0, 0, 10, 10)
