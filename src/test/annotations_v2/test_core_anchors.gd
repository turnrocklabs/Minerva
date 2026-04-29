extends SceneTree
## Contract tests for built-in core anchor types (task #2).
## Covers: core/text.range, core/text.selection, core/graphics.region, core/graphics.layer
## Run: godot --headless --path src --script test/annotations_v2/test_core_anchors.gd
##
## RED in Round 1 — CoreAnchors does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_core_anchors ===\n")

	print("-- CoreAnchors: class existence --")
	test_core_anchors_class_exists()
	test_core_anchors_get_resolver_for_exists()

	print("\n-- core/text.range --")
	test_text_range_valid_anchor_passes()
	test_text_range_missing_start_fails()
	test_text_range_missing_end_fails()
	test_text_range_start_not_int_fails()
	test_text_range_end_not_int_fails()
	test_text_range_summary_format()

	print("\n-- core/text.selection --")
	test_text_selection_valid_anchor_passes()
	test_text_selection_missing_start_fails()
	test_text_selection_missing_end_fails()
	test_text_selection_summary_format()

	print("\n-- core/graphics.region --")
	test_graphics_region_valid_anchor_passes()
	test_graphics_region_missing_rect_fails()
	test_graphics_region_rect_wrong_type_fails()
	test_graphics_region_summary_format()

	print("\n-- core/graphics.layer --")
	test_graphics_layer_valid_anchor_passes()
	test_graphics_layer_missing_id_fails()
	test_graphics_layer_summary_format()

	print("\n-- core anchors registered at startup --")
	test_core_anchors_registered_in_registry()
	test_core_anchor_repair_returns_null()

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

func _text_range_anchor(start: int, end: int) -> Dictionary:
	return {
		"plugin": "core",
		"type": "text.range",
		"id": {"start": start, "end": end},
		"snapshot": {
			"position": [0.0, 0.0],
			"text": "sample text",
			"document_revision": 1
		}
	}


func _text_selection_anchor(start: int, end: int) -> Dictionary:
	return {
		"plugin": "core",
		"type": "text.selection",
		"id": {"start": start, "end": end},
		"snapshot": {
			"position": [0.0, 0.0],
			"text": "selected",
			"document_revision": 1
		}
	}


func _graphics_region_anchor() -> Dictionary:
	return {
		"plugin": "core",
		"type": "graphics.region",
		"id": "region_abc123",
		"snapshot": {
			"position": [10.0, 10.0],
			"rect": [10.0, 10.0, 100.0, 80.0],
			"image_revision": "rev_42"
		}
	}


func _graphics_layer_anchor(layer_id: Variant) -> Dictionary:
	return {
		"plugin": "core",
		"type": "graphics.layer",
		"id": layer_id,
		"snapshot": {
			"position": [0.0, 0.0],
			"layer_revision": 7
		}
	}


func _get_resolver(type_name: String) -> Variant:
	if not ClassDB.class_exists("CoreAnchors"):
		return null
	var core = ClassDB.instantiate("CoreAnchors")
	if core == null or not core.has_method("get_resolver_for"):
		return null
	return core.get_resolver_for(type_name)


# ── CoreAnchors class existence ───────────────────────────────────────────────

func test_core_anchors_class_exists() -> void:
	print("test_core_anchors_class_exists:")
	check("CoreAnchors class exists", ClassDB.class_exists("CoreAnchors"))


func test_core_anchors_get_resolver_for_exists() -> void:
	print("test_core_anchors_get_resolver_for_exists:")
	if not ClassDB.class_exists("CoreAnchors"):
		check("CoreAnchors exists", false)
		return
	var core = ClassDB.instantiate("CoreAnchors")
	if core == null:
		check("CoreAnchors instantiable", false)
		return
	check("CoreAnchors has get_resolver_for method",
		core.has_method("get_resolver_for"))


# ── core/text.range tests ─────────────────────────────────────────────────────

func test_text_range_valid_anchor_passes() -> void:
	print("test_text_range_valid_anchor_passes:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("CoreAnchors.get_resolver_for('text.range') returns resolver", false)
		return
	var errors = resolver.validate(_text_range_anchor(10, 25))
	check("valid text.range anchor → no errors", errors.size() == 0)


func test_text_range_missing_start_fails() -> void:
	print("test_text_range_missing_start_fails:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var anchor = _text_range_anchor(0, 10)
	anchor["id"] = {"end": 10}  # missing start
	var errors = resolver.validate(anchor)
	check("text.range missing start in id → errors", errors.size() > 0)


func test_text_range_missing_end_fails() -> void:
	print("test_text_range_missing_end_fails:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var anchor = _text_range_anchor(0, 10)
	anchor["id"] = {"start": 0}  # missing end
	var errors = resolver.validate(anchor)
	check("text.range missing end in id → errors", errors.size() > 0)


func test_text_range_start_not_int_fails() -> void:
	print("test_text_range_start_not_int_fails:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var anchor = _text_range_anchor(0, 10)
	anchor["id"] = {"start": "bad", "end": 10}
	var errors = resolver.validate(anchor)
	check("text.range start=string → errors", errors.size() > 0)


func test_text_range_end_not_int_fails() -> void:
	print("test_text_range_end_not_int_fails:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var anchor = _text_range_anchor(0, 10)
	anchor["id"] = {"start": 0, "end": "bad"}
	var errors = resolver.validate(anchor)
	check("text.range end=string → errors", errors.size() > 0)


func test_text_range_summary_format() -> void:
	print("test_text_range_summary_format:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var summary = resolver.summary(_text_range_anchor(10, 25), null)
	check("text.range summary is non-empty", summary.length() > 0)
	check("text.range summary mentions range or positions",
		"10" in summary or "25" in summary or "range" in summary.to_lower())


# ── core/text.selection tests ─────────────────────────────────────────────────

func test_text_selection_valid_anchor_passes() -> void:
	print("test_text_selection_valid_anchor_passes:")
	var resolver = _get_resolver("text.selection")
	if resolver == null:
		check("CoreAnchors.get_resolver_for('text.selection') returns resolver", false)
		return
	var errors = resolver.validate(_text_selection_anchor(0, 15))
	check("valid text.selection anchor → no errors", errors.size() == 0)


func test_text_selection_missing_start_fails() -> void:
	print("test_text_selection_missing_start_fails:")
	var resolver = _get_resolver("text.selection")
	if resolver == null:
		check("text.selection resolver exists", false)
		return
	var anchor = _text_selection_anchor(0, 15)
	anchor["id"] = {"end": 15}
	var errors = resolver.validate(anchor)
	check("text.selection missing start → errors", errors.size() > 0)


func test_text_selection_missing_end_fails() -> void:
	print("test_text_selection_missing_end_fails:")
	var resolver = _get_resolver("text.selection")
	if resolver == null:
		check("text.selection resolver exists", false)
		return
	var anchor = _text_selection_anchor(0, 15)
	anchor["id"] = {"start": 0}
	var errors = resolver.validate(anchor)
	check("text.selection missing end → errors", errors.size() > 0)


func test_text_selection_summary_format() -> void:
	print("test_text_selection_summary_format:")
	var resolver = _get_resolver("text.selection")
	if resolver == null:
		check("text.selection resolver exists", false)
		return
	var summary = resolver.summary(_text_selection_anchor(3, 12), null)
	check("text.selection summary non-empty", summary.length() > 0)


# ── core/graphics.region tests ────────────────────────────────────────────────

func test_graphics_region_valid_anchor_passes() -> void:
	print("test_graphics_region_valid_anchor_passes:")
	var resolver = _get_resolver("graphics.region")
	if resolver == null:
		check("CoreAnchors.get_resolver_for('graphics.region') returns resolver", false)
		return
	var errors = resolver.validate(_graphics_region_anchor())
	check("valid graphics.region anchor → no errors", errors.size() == 0)


func test_graphics_region_missing_rect_fails() -> void:
	print("test_graphics_region_missing_rect_fails:")
	var resolver = _get_resolver("graphics.region")
	if resolver == null:
		check("graphics.region resolver exists", false)
		return
	var anchor = _graphics_region_anchor()
	anchor["snapshot"].erase("rect")
	var errors = resolver.validate(anchor)
	check("graphics.region missing rect in snapshot → errors", errors.size() > 0)


func test_graphics_region_rect_wrong_type_fails() -> void:
	print("test_graphics_region_rect_wrong_type_fails:")
	var resolver = _get_resolver("graphics.region")
	if resolver == null:
		check("graphics.region resolver exists", false)
		return
	var anchor = _graphics_region_anchor()
	anchor["snapshot"]["rect"] = "not-an-array"
	var errors = resolver.validate(anchor)
	check("graphics.region rect=string → errors", errors.size() > 0)


func test_graphics_region_summary_format() -> void:
	print("test_graphics_region_summary_format:")
	var resolver = _get_resolver("graphics.region")
	if resolver == null:
		check("graphics.region resolver exists", false)
		return
	var summary = resolver.summary(_graphics_region_anchor(), null)
	check("graphics.region summary non-empty", summary.length() > 0)


# ── core/graphics.layer tests ─────────────────────────────────────────────────

func test_graphics_layer_valid_anchor_passes() -> void:
	print("test_graphics_layer_valid_anchor_passes:")
	var resolver = _get_resolver("graphics.layer")
	if resolver == null:
		check("CoreAnchors.get_resolver_for('graphics.layer') returns resolver", false)
		return
	var errors = resolver.validate(_graphics_layer_anchor("layer_bg"))
	check("valid graphics.layer anchor → no errors", errors.size() == 0)


func test_graphics_layer_missing_id_fails() -> void:
	print("test_graphics_layer_missing_id_fails:")
	var resolver = _get_resolver("graphics.layer")
	if resolver == null:
		check("graphics.layer resolver exists", false)
		return
	var anchor = _graphics_layer_anchor("layer_bg")
	anchor.erase("id")
	var errors = resolver.validate(anchor)
	check("graphics.layer missing id → errors", errors.size() > 0)


func test_graphics_layer_summary_format() -> void:
	print("test_graphics_layer_summary_format:")
	var resolver = _get_resolver("graphics.layer")
	if resolver == null:
		check("graphics.layer resolver exists", false)
		return
	var summary = resolver.summary(_graphics_layer_anchor("layer_fg"), null)
	check("graphics.layer summary non-empty", summary.length() > 0)
	check("graphics.layer summary mentions layer id", "layer_fg" in summary or "layer" in summary.to_lower())


# ── Startup registration tests ────────────────────────────────────────────────

func test_core_anchors_registered_in_registry() -> void:
	print("test_core_anchors_registered_in_registry:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	if not ClassDB.class_exists("CoreAnchors"):
		check("CoreAnchors exists", false)
		return
	var reg = ClassDB.instantiate("AnnotationAnchorRegistry")
	if reg == null:
		check("AnnotationAnchorRegistry instantiable", false)
		return
	var core = ClassDB.instantiate("CoreAnchors")
	if core == null or not core.has_method("register_all"):
		check("CoreAnchors has register_all method", false)
		return
	core.register_all(reg)
	check("text.range registered", reg.get_resolver("core", "text.range") != null)
	check("text.selection registered", reg.get_resolver("core", "text.selection") != null)
	check("graphics.region registered", reg.get_resolver("core", "graphics.region") != null)
	check("graphics.layer registered", reg.get_resolver("core", "graphics.layer") != null)


func test_core_anchor_repair_returns_null() -> void:
	print("test_core_anchor_repair_returns_null:")
	var resolver = _get_resolver("text.range")
	if resolver == null:
		check("text.range resolver exists", false)
		return
	var result = resolver.repair(_text_range_anchor(0, 5), null)
	check("core text.range repair returns null (no auto-repair)", result == null)
