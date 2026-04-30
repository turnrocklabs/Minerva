extends SceneTree

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const AnnotationV2SchemaScript = preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const AnnotationRegistryScript = preload("res://Scripts/Services/Annotations/AnnotationRegistry.gd")
const BuiltinKindsScript = preload("res://Scripts/Services/Annotations/BuiltinKinds.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_kind_anchor_compat ===\n")
	test_annotation_kind_default_returns_empty_array()
	test_builtin_kinds_accept_core_wildcard()
	test_generic_text_with_core_text_range_valid()
	test_generic_arrow_with_core_graphics_region_valid()
	test_generic_text_with_cad_edge_invalid()
	test_generic_arrow_with_pcb_net_invalid()
	test_plugin_kind_with_matching_anchor_valid()
	test_plugin_kind_with_wrong_anchor_invalid()
	test_plugin_kind_cad_edge_note_with_core_anchor_invalid()
	test_core_wildcard_matches_core_text_range()
	test_core_wildcard_matches_core_graphics_region()
	test_core_wildcard_does_not_match_cad_edge()
	test_core_wildcard_does_not_match_pcb_net()
	test_plugin_kind_can_declare_multiple_anchor_types()
	test_generic_kind_accepts_core_none_anchor()
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


func _make_envelope(kind: String, anchor_plugin: String, anchor_type: String) -> Dictionary:
	return {
		"id": "ann_test",
		"kind": kind,
		"schema_version": 2,
		"anchor": {"plugin": anchor_plugin, "type": anchor_type, "id": 1, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "test"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "test:main",
		"visible_in_views": ["main"],
		"summary": "test summary",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func test_annotation_kind_default_returns_empty_array() -> void:
	var types: Array = AnnotationKindScript.new().accepted_anchor_types()
	check("default accepted_anchor_types returns []", types.is_empty())


func test_builtin_kinds_accept_core_wildcard() -> void:
	var builtins := BuiltinKindsScript.new()
	for kind_name in ["text", "arrow", "region", "polyline", "highlight", "measure_distance", "measure_angle", "measure_radius"]:
		var kind = builtins.get_kind(kind_name)
		check("%s built-in exists" % kind_name, kind != null)
		if kind != null:
			check("%s accepts core/*" % kind_name, "core/*" in kind.accepted_anchor_types())


func test_generic_text_with_core_text_range_valid() -> void:
	var result = AnnotationV2SchemaScript.new().validate(_make_envelope("text", "core", "text.range"))
	check("text kind + core/text.range anchor valid", not result.has_errors())


func test_generic_arrow_with_core_graphics_region_valid() -> void:
	var result = AnnotationV2SchemaScript.new().validate(_make_envelope("arrow", "core", "graphics.region"))
	check("arrow kind + core/graphics.region anchor valid", not result.has_errors())


func test_generic_text_with_cad_edge_invalid() -> void:
	var result = AnnotationV2SchemaScript.new().validate(_make_envelope("text", "cad", "edge"))
	check("text kind + cad/edge anchor invalid", result.has_errors())


func test_generic_arrow_with_pcb_net_invalid() -> void:
	var result = AnnotationV2SchemaScript.new().validate(_make_envelope("arrow", "pcb", "net"))
	check("arrow kind + pcb/net anchor invalid", result.has_errors())


func test_plugin_kind_with_matching_anchor_valid() -> void:
	var registry := AnnotationRegistryScript.new()
	registry.register_annotation_kind(_CadEdgeNoteKind.new())
	var result = AnnotationV2SchemaScript.new().validate_with_registry(_make_envelope("cad_edge_note", "cad", "edge"), registry)
	check("cad_edge_note kind + cad/edge anchor valid", not result.has_errors())


func test_plugin_kind_with_wrong_anchor_invalid() -> void:
	var registry := AnnotationRegistryScript.new()
	registry.register_annotation_kind(_CadEdgeNoteKind.new())
	var result = AnnotationV2SchemaScript.new().validate_with_registry(_make_envelope("cad_edge_note", "pcb", "net"), registry)
	check("cad_edge_note kind + pcb/net anchor invalid", result.has_errors())


func test_plugin_kind_cad_edge_note_with_core_anchor_invalid() -> void:
	var registry := AnnotationRegistryScript.new()
	registry.register_annotation_kind(_CadEdgeNoteKind.new())
	var result = AnnotationV2SchemaScript.new().validate_with_registry(_make_envelope("cad_edge_note", "core", "text.range"), registry)
	check("cad_edge_note kind + core/text.range anchor invalid", result.has_errors())


func test_core_wildcard_matches_core_text_range() -> void:
	check("core/* matches core/text.range", AnnotationV2SchemaScript.new().anchor_type_matches_pattern("core/text.range", "core/*"))


func test_core_wildcard_matches_core_graphics_region() -> void:
	check("core/* matches core/graphics.region", AnnotationV2SchemaScript.new().anchor_type_matches_pattern("core/graphics.region", "core/*"))


func test_core_wildcard_does_not_match_cad_edge() -> void:
	check("core/* does not match cad/edge", not AnnotationV2SchemaScript.new().anchor_type_matches_pattern("cad/edge", "core/*"))


func test_core_wildcard_does_not_match_pcb_net() -> void:
	check("core/* does not match pcb/net", not AnnotationV2SchemaScript.new().anchor_type_matches_pattern("pcb/net", "core/*"))


func test_plugin_kind_can_declare_multiple_anchor_types() -> void:
	var registry := AnnotationRegistryScript.new()
	registry.register_annotation_kind(_MultiAnchorKind.new())
	var schema := AnnotationV2SchemaScript.new()
	check("multi-anchor kind + cad/edge valid", not schema.validate_with_registry(_make_envelope("multi_cad_kind", "cad", "edge"), registry).has_errors())
	check("multi-anchor kind + cad/face valid", not schema.validate_with_registry(_make_envelope("multi_cad_kind", "cad", "face"), registry).has_errors())
	check("multi-anchor kind + pcb/net invalid", schema.validate_with_registry(_make_envelope("multi_cad_kind", "pcb", "net"), registry).has_errors())


func test_generic_kind_accepts_core_none_anchor() -> void:
	var result = AnnotationV2SchemaScript.new().validate(_make_envelope("text", "core", "none"))
	check("generic text kind + core/none anchor valid", not result.has_errors())


class _CadEdgeNoteKind extends AnnotationKind:
	func _init() -> void:
		name = &"cad_edge_note"
		display_name = "CAD Edge Note"
		owning_plugin = &"cad"

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		pass

	func accepted_anchor_types() -> Array:
		return ["cad/edge"]


class _MultiAnchorKind extends AnnotationKind:
	func _init() -> void:
		name = &"multi_cad_kind"
		display_name = "Multi CAD Kind"
		owning_plugin = &"cad"

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		pass

	func accepted_anchor_types() -> Array:
		return ["cad/edge", "cad/face"]
