extends SceneTree
## Behavioral tests for built-in core anchor types (task #2).
## Covers: core/text.range, core/text.selection, core/graphics.region, core/graphics.layer
## Run: godot --headless --path src --script test/annotations_v2/test_core_anchors.gd

const AnnotationAnchorRegistryScript = preload("res://Scripts/Services/Annotations/AnnotationAnchorRegistry.gd")
const CoreAnchorsScript = preload("res://Scripts/Services/Annotations/CoreAnchors.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_core_anchors ===\n")

	print("-- core/text.range --")
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
	test_graphics_region_rect_wrong_length_fails()
	test_graphics_region_summary_format()

	print("\n-- core/graphics.layer --")
	test_graphics_layer_valid_anchor_passes()
	test_graphics_layer_missing_id_fails()
	test_graphics_layer_summary_format()

	print("\n-- core anchors registered at startup --")
	test_core_anchors_registered_in_registry()
	test_core_anchor_repair_returns_null()
	test_unknown_core_anchor_returns_null()

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


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s - expected %s, got %s" % [description, str(expected), str(actual)])


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


func _get_resolver(type_name: String) -> Object:
	return CoreAnchorsScript.new().get_resolver_for(type_name)


func test_text_range_valid_anchor_passes() -> void:
	print("test_text_range_valid_anchor_passes:")
	var errors: Array = _get_resolver("text.range").validate(_text_range_anchor(10, 25))
	check("valid text.range anchor has no errors", errors.is_empty())


func test_text_range_missing_start_fails() -> void:
	print("test_text_range_missing_start_fails:")
	var anchor := _text_range_anchor(0, 10)
	anchor["id"] = {"end": 10}
	check("text.range missing start errors", _get_resolver("text.range").validate(anchor).size() > 0)


func test_text_range_missing_end_fails() -> void:
	print("test_text_range_missing_end_fails:")
	var anchor := _text_range_anchor(0, 10)
	anchor["id"] = {"start": 0}
	check("text.range missing end errors", _get_resolver("text.range").validate(anchor).size() > 0)


func test_text_range_start_not_int_fails() -> void:
	print("test_text_range_start_not_int_fails:")
	var anchor := _text_range_anchor(0, 10)
	anchor["id"] = {"start": "bad", "end": 10}
	check("text.range start=string errors", _get_resolver("text.range").validate(anchor).size() > 0)


func test_text_range_end_not_int_fails() -> void:
	print("test_text_range_end_not_int_fails:")
	var anchor := _text_range_anchor(0, 10)
	anchor["id"] = {"start": 0, "end": "bad"}
	check("text.range end=string errors", _get_resolver("text.range").validate(anchor).size() > 0)


func test_text_range_summary_format() -> void:
	print("test_text_range_summary_format:")
	var summary: String = _get_resolver("text.range").summary(_text_range_anchor(10, 25), null)
	check("text.range summary is non-empty", not summary.is_empty())
	check("text.range summary mentions positions", "10" in summary and "25" in summary)


func test_text_selection_valid_anchor_passes() -> void:
	print("test_text_selection_valid_anchor_passes:")
	check("valid text.selection anchor has no errors", _get_resolver("text.selection").validate(_text_selection_anchor(0, 15)).is_empty())


func test_text_selection_missing_start_fails() -> void:
	print("test_text_selection_missing_start_fails:")
	var anchor := _text_selection_anchor(0, 15)
	anchor["id"] = {"end": 15}
	check("text.selection missing start errors", _get_resolver("text.selection").validate(anchor).size() > 0)


func test_text_selection_missing_end_fails() -> void:
	print("test_text_selection_missing_end_fails:")
	var anchor := _text_selection_anchor(0, 15)
	anchor["id"] = {"start": 0}
	check("text.selection missing end errors", _get_resolver("text.selection").validate(anchor).size() > 0)


func test_text_selection_summary_format() -> void:
	print("test_text_selection_summary_format:")
	var summary: String = _get_resolver("text.selection").summary(_text_selection_anchor(3, 12), null)
	check("text.selection summary non-empty", not summary.is_empty())
	check("text.selection summary mentions selection", "selection" in summary)


func test_graphics_region_valid_anchor_passes() -> void:
	print("test_graphics_region_valid_anchor_passes:")
	check("valid graphics.region anchor has no errors", _get_resolver("graphics.region").validate(_graphics_region_anchor()).is_empty())


func test_graphics_region_missing_rect_fails() -> void:
	print("test_graphics_region_missing_rect_fails:")
	var anchor := _graphics_region_anchor()
	anchor["snapshot"].erase("rect")
	check("graphics.region missing rect errors", _get_resolver("graphics.region").validate(anchor).size() > 0)


func test_graphics_region_rect_wrong_type_fails() -> void:
	print("test_graphics_region_rect_wrong_type_fails:")
	var anchor := _graphics_region_anchor()
	anchor["snapshot"]["rect"] = "not-an-array"
	check("graphics.region rect=string errors", _get_resolver("graphics.region").validate(anchor).size() > 0)


func test_graphics_region_rect_wrong_length_fails() -> void:
	print("test_graphics_region_rect_wrong_length_fails:")
	var anchor := _graphics_region_anchor()
	anchor["snapshot"]["rect"] = [1.0, 2.0]
	check("graphics.region rect wrong length errors", _get_resolver("graphics.region").validate(anchor).size() > 0)


func test_graphics_region_summary_format() -> void:
	print("test_graphics_region_summary_format:")
	var summary: String = _get_resolver("graphics.region").summary(_graphics_region_anchor(), null)
	check("graphics.region summary non-empty", not summary.is_empty())
	check("graphics.region summary mentions region", "region" in summary)


func test_graphics_layer_valid_anchor_passes() -> void:
	print("test_graphics_layer_valid_anchor_passes:")
	check("valid graphics.layer anchor has no errors", _get_resolver("graphics.layer").validate(_graphics_layer_anchor("layer_bg")).is_empty())


func test_graphics_layer_missing_id_fails() -> void:
	print("test_graphics_layer_missing_id_fails:")
	var anchor := _graphics_layer_anchor("layer_bg")
	anchor.erase("id")
	check("graphics.layer missing id errors", _get_resolver("graphics.layer").validate(anchor).size() > 0)


func test_graphics_layer_summary_format() -> void:
	print("test_graphics_layer_summary_format:")
	var summary: String = _get_resolver("graphics.layer").summary(_graphics_layer_anchor("layer_fg"), null)
	check("graphics.layer summary non-empty", not summary.is_empty())
	check("graphics.layer summary mentions layer id", "layer_fg" in summary)


func test_core_anchors_registered_in_registry() -> void:
	print("test_core_anchors_registered_in_registry:")
	var reg := AnnotationAnchorRegistryScript.new()
	CoreAnchorsScript.new().register_all(reg)
	check("text.range registered", reg.get_resolver("core", "text.range") != null)
	check("text.selection registered", reg.get_resolver("core", "text.selection") != null)
	check("graphics.region registered", reg.get_resolver("core", "graphics.region") != null)
	check("graphics.layer registered", reg.get_resolver("core", "graphics.layer") != null)
	check_eq("known core anchors count", reg.known_anchors_for("core").size(), 4)


func test_core_anchor_repair_returns_null() -> void:
	print("test_core_anchor_repair_returns_null:")
	var result: Variant = _get_resolver("text.range").repair(_text_range_anchor(0, 5), null)
	check("core text.range repair returns null", result == null)


func test_unknown_core_anchor_returns_null() -> void:
	print("test_unknown_core_anchor_returns_null:")
	check("unknown core anchor resolver is null", _get_resolver("unknown") == null)
