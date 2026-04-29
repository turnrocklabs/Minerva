extends SceneTree
## Contract tests for kind/anchor compatibility policy (task #6).
## Run: godot --headless --path src --script test/annotations_v2/test_kind_anchor_compat.gd
##
## RED in Round 1 — AnnotationKind.accepted_anchor_types() and BuiltinKinds do not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_kind_anchor_compat ===\n")

	print("-- AnnotationKind: accepted_anchor_types virtual --")
	test_annotation_kind_has_accepted_anchor_types_method()
	test_annotation_kind_default_returns_empty_array()

	print("\n-- BuiltinKinds: class existence --")
	test_builtin_kinds_class_exists()

	print("\n-- built-in generic kinds accept core/* --")
	test_builtin_text_kind_accepts_core_wildcard()
	test_builtin_arrow_kind_accepts_core_wildcard()
	test_builtin_region_kind_accepts_core_wildcard()
	test_builtin_polyline_kind_accepts_core_wildcard()
	test_builtin_highlight_kind_accepts_core_wildcard()

	print("\n-- AnnotationV2Schema: class existence --")
	test_annotation_v2_schema_class_exists()

	print("\n-- schema validation: policy table --")
	test_generic_text_with_core_text_range_valid()
	test_generic_arrow_with_core_graphics_region_valid()
	test_generic_text_with_cad_edge_invalid()
	test_generic_arrow_with_pcb_net_invalid()
	test_plugin_kind_with_matching_anchor_valid()
	test_plugin_kind_with_wrong_anchor_invalid()
	test_plugin_kind_cad_edge_note_with_core_anchor_invalid()

	print("\n-- wildcard match semantics --")
	test_core_wildcard_matches_core_text_range()
	test_core_wildcard_matches_core_graphics_region()
	test_core_wildcard_does_not_match_cad_edge()
	test_core_wildcard_does_not_match_pcb_net()

	print("\n-- multiple accepted anchor types --")
	test_plugin_kind_can_declare_multiple_anchor_types()

	print("\n-- core/none for migrated v1 --")
	test_generic_kind_accepts_core_none_anchor()

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


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _make_envelope(kind: String, anchor_plugin: String, anchor_type: String) -> Dictionary:
	return {
		"id": "ann_test",
		"kind": kind,
		"schema_version": 2,
		"anchor": {
			"plugin": anchor_plugin,
			"type": anchor_type,
			"id": 1,
			"snapshot": {"position": [0.0, 0.0]}
		},
		"kind_payload": {"text": "test"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "test:main",
		"visible_in_views": ["main"],
		"summary": "test summary",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _make_schema() -> Variant:
	if not ClassDB.class_exists("AnnotationV2Schema"):
		return null
	return ClassDB.instantiate("AnnotationV2Schema")


func _make_registry() -> Variant:
	if not ClassDB.class_exists("AnnotationRegistry"):
		return null
	return ClassDB.instantiate("AnnotationRegistry")


func _make_builtin_kinds() -> Variant:
	if not ClassDB.class_exists("BuiltinKinds"):
		return null
	return ClassDB.instantiate("BuiltinKinds")


# ── accepted_anchor_types virtual ────────────────────────────────────────────

func test_annotation_kind_has_accepted_anchor_types_method() -> void:
	print("test_annotation_kind_has_accepted_anchor_types_method:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null:
		check("AnnotationKind instantiable", false)
		return
	check("AnnotationKind has accepted_anchor_types method",
		kind.has_method("accepted_anchor_types"))


func test_annotation_kind_default_returns_empty_array() -> void:
	print("test_annotation_kind_default_returns_empty_array:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("accepted_anchor_types"):
		check("AnnotationKind has accepted_anchor_types", false)
		return
	var types = kind.accepted_anchor_types()
	check("default accepted_anchor_types returns [] (rejects all)",
		types is Array and types.size() == 0)


# ── BuiltinKinds class existence ──────────────────────────────────────────────

func test_builtin_kinds_class_exists() -> void:
	print("test_builtin_kinds_class_exists:")
	check("BuiltinKinds class exists", ClassDB.class_exists("BuiltinKinds"))


# ── Built-in generic kinds ────────────────────────────────────────────────────

func test_builtin_text_kind_accepts_core_wildcard() -> void:
	print("test_builtin_text_kind_accepts_core_wildcard:")
	if not ClassDB.class_exists("BuiltinKinds"):
		check("BuiltinKinds exists", false)
		return
	var bk = _make_builtin_kinds()
	if bk == null or not bk.has_method("get_kind"):
		check("BuiltinKinds has get_kind method", false)
		return
	var kind = bk.get_kind("text")
	if kind == null:
		check("BuiltinKinds.get_kind('text') returns a kind", false)
		return
	var types = kind.accepted_anchor_types() if kind.has_method("accepted_anchor_types") else []
	check("text kind accepted_anchor_types contains core/*", "core/*" in types)


func test_builtin_arrow_kind_accepts_core_wildcard() -> void:
	print("test_builtin_arrow_kind_accepts_core_wildcard:")
	if not ClassDB.class_exists("BuiltinKinds"):
		check("BuiltinKinds exists", false)
		return
	var bk = _make_builtin_kinds()
	if bk == null or not bk.has_method("get_kind"):
		check("BuiltinKinds has get_kind method", false)
		return
	var kind = bk.get_kind("arrow")
	if kind == null:
		check("BuiltinKinds.get_kind('arrow') returns a kind", false)
		return
	var types = kind.accepted_anchor_types() if kind.has_method("accepted_anchor_types") else []
	check("arrow kind accepts core/*", "core/*" in types)


func test_builtin_region_kind_accepts_core_wildcard() -> void:
	print("test_builtin_region_kind_accepts_core_wildcard:")
	if not ClassDB.class_exists("BuiltinKinds"):
		check("BuiltinKinds exists", false)
		return
	var bk = _make_builtin_kinds()
	if bk == null or not bk.has_method("get_kind"):
		check("BuiltinKinds has get_kind method", false)
		return
	var kind = bk.get_kind("region")
	if kind == null:
		check("BuiltinKinds.get_kind('region') returns a kind", false)
		return
	var types = kind.accepted_anchor_types() if kind.has_method("accepted_anchor_types") else []
	check("region kind accepts core/*", "core/*" in types)


func test_builtin_polyline_kind_accepts_core_wildcard() -> void:
	print("test_builtin_polyline_kind_accepts_core_wildcard:")
	if not ClassDB.class_exists("BuiltinKinds"):
		check("BuiltinKinds exists", false)
		return
	var bk = _make_builtin_kinds()
	if bk == null or not bk.has_method("get_kind"):
		check("BuiltinKinds has get_kind method", false)
		return
	var kind = bk.get_kind("polyline")
	if kind == null:
		check("BuiltinKinds.get_kind('polyline') returns a kind", false)
		return
	var types = kind.accepted_anchor_types() if kind.has_method("accepted_anchor_types") else []
	check("polyline kind accepts core/*", "core/*" in types)


func test_builtin_highlight_kind_accepts_core_wildcard() -> void:
	print("test_builtin_highlight_kind_accepts_core_wildcard:")
	if not ClassDB.class_exists("BuiltinKinds"):
		check("BuiltinKinds exists", false)
		return
	var bk = _make_builtin_kinds()
	if bk == null or not bk.has_method("get_kind"):
		check("BuiltinKinds has get_kind method", false)
		return
	var kind = bk.get_kind("highlight")
	if kind == null:
		check("BuiltinKinds.get_kind('highlight') returns a kind", false)
		return
	var types = kind.accepted_anchor_types() if kind.has_method("accepted_anchor_types") else []
	check("highlight kind accepts core/*", "core/*" in types)


# ── AnnotationV2Schema class existence ───────────────────────────────────────

func test_annotation_v2_schema_class_exists() -> void:
	print("test_annotation_v2_schema_class_exists:")
	check("AnnotationV2Schema class exists", ClassDB.class_exists("AnnotationV2Schema"))


# ── Schema validation policy table ───────────────────────────────────────────

func test_generic_text_with_core_text_range_valid() -> void:
	print("test_generic_text_with_core_text_range_valid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate"):
		check("AnnotationV2Schema has validate method", false)
		return
	if not ClassDB.class_exists("AnnotationRegistry"):
		check("AnnotationRegistry exists for kind lookup", false)
		return
	var env = _make_envelope("text", "core", "text.range")
	var result = schema.validate(env)
	check("text kind + core/text.range anchor → valid", not result.has_errors())


func test_generic_arrow_with_core_graphics_region_valid() -> void:
	print("test_generic_arrow_with_core_graphics_region_valid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate"):
		check("AnnotationV2Schema has validate method", false)
		return
	var env = _make_envelope("arrow", "core", "graphics.region")
	var result = schema.validate(env)
	check("arrow kind + core/graphics.region anchor → valid", not result.has_errors())


func test_generic_text_with_cad_edge_invalid() -> void:
	print("test_generic_text_with_cad_edge_invalid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate"):
		check("AnnotationV2Schema has validate method", false)
		return
	var env = _make_envelope("text", "cad", "edge")
	var result = schema.validate(env)
	check("text kind + cad/edge anchor → invalid (generic rejects non-core)",
		result.has_errors())


func test_generic_arrow_with_pcb_net_invalid() -> void:
	print("test_generic_arrow_with_pcb_net_invalid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate"):
		check("AnnotationV2Schema has validate method", false)
		return
	var env = _make_envelope("arrow", "pcb", "net")
	var result = schema.validate(env)
	check("arrow kind + pcb/net anchor → invalid (generic rejects non-core)",
		result.has_errors())


func test_plugin_kind_with_matching_anchor_valid() -> void:
	print("test_plugin_kind_with_matching_anchor_valid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate_with_registry"):
		check("AnnotationV2Schema has validate_with_registry method", false)
		return
	if not ClassDB.class_exists("AnnotationRegistry"):
		check("AnnotationRegistry exists for kind lookup", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register_annotation_kind"):
		check("AnnotationRegistry has register_annotation_kind method", false)
		return
	var cad_kind = _CadEdgeNoteKind.new()
	reg.register_annotation_kind(cad_kind)
	var env = _make_envelope("cad_edge_note", "cad", "edge")
	var result = schema.validate_with_registry(env, reg)
	check("cad_edge_note kind + cad/edge anchor → valid",
		not result.has_errors())


func test_plugin_kind_with_wrong_anchor_invalid() -> void:
	print("test_plugin_kind_with_wrong_anchor_invalid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate_with_registry"):
		check("AnnotationV2Schema has validate_with_registry method", false)
		return
	if not ClassDB.class_exists("AnnotationRegistry"):
		check("AnnotationRegistry exists for kind lookup", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register_annotation_kind"):
		check("AnnotationRegistry has register_annotation_kind method", false)
		return
	var cad_kind = _CadEdgeNoteKind.new()
	reg.register_annotation_kind(cad_kind)
	var env = _make_envelope("cad_edge_note", "pcb", "net")
	var result = schema.validate_with_registry(env, reg)
	check("cad_edge_note kind + pcb/net anchor → invalid", result.has_errors())


func test_plugin_kind_cad_edge_note_with_core_anchor_invalid() -> void:
	print("test_plugin_kind_cad_edge_note_with_core_anchor_invalid:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate_with_registry"):
		check("AnnotationV2Schema has validate_with_registry method", false)
		return
	if not ClassDB.class_exists("AnnotationRegistry"):
		check("AnnotationRegistry exists for kind lookup", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register_annotation_kind"):
		check("AnnotationRegistry has register_annotation_kind method", false)
		return
	var cad_kind = _CadEdgeNoteKind.new()
	reg.register_annotation_kind(cad_kind)
	var env = _make_envelope("cad_edge_note", "core", "text.range")
	var result = schema.validate_with_registry(env, reg)
	check("cad_edge_note kind + core/text.range anchor → invalid", result.has_errors())


# ── Wildcard match semantics ──────────────────────────────────────────────────

func test_core_wildcard_matches_core_text_range() -> void:
	print("test_core_wildcard_matches_core_text_range:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("anchor_type_matches_pattern"):
		check("AnnotationV2Schema has anchor_type_matches_pattern method", false)
		return
	check("core/* matches core/text.range",
		schema.anchor_type_matches_pattern("core/text.range", "core/*"))


func test_core_wildcard_matches_core_graphics_region() -> void:
	print("test_core_wildcard_matches_core_graphics_region:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("anchor_type_matches_pattern"):
		check("AnnotationV2Schema has anchor_type_matches_pattern method", false)
		return
	check("core/* matches core/graphics.region",
		schema.anchor_type_matches_pattern("core/graphics.region", "core/*"))


func test_core_wildcard_does_not_match_cad_edge() -> void:
	print("test_core_wildcard_does_not_match_cad_edge:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("anchor_type_matches_pattern"):
		check("AnnotationV2Schema has anchor_type_matches_pattern method", false)
		return
	check("core/* does NOT match cad/edge",
		not schema.anchor_type_matches_pattern("cad/edge", "core/*"))


func test_core_wildcard_does_not_match_pcb_net() -> void:
	print("test_core_wildcard_does_not_match_pcb_net:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("anchor_type_matches_pattern"):
		check("AnnotationV2Schema has anchor_type_matches_pattern method", false)
		return
	check("core/* does NOT match pcb/net",
		not schema.anchor_type_matches_pattern("pcb/net", "core/*"))


# ── Multiple accepted anchor types ───────────────────────────────────────────

func test_plugin_kind_can_declare_multiple_anchor_types() -> void:
	print("test_plugin_kind_can_declare_multiple_anchor_types:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate_with_registry"):
		check("AnnotationV2Schema has validate_with_registry method", false)
		return
	if not ClassDB.class_exists("AnnotationRegistry"):
		check("AnnotationRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register_annotation_kind"):
		check("AnnotationRegistry has register_annotation_kind method", false)
		return
	var multi_kind = _MultiAnchorKind.new()
	reg.register_annotation_kind(multi_kind)
	var env_edge = _make_envelope("multi_cad_kind", "cad", "edge")
	var env_face = _make_envelope("multi_cad_kind", "cad", "face")
	var env_net = _make_envelope("multi_cad_kind", "pcb", "net")
	check("multi-anchor kind + cad/edge → valid",
		not schema.validate_with_registry(env_edge, reg).has_errors())
	check("multi-anchor kind + cad/face → valid",
		not schema.validate_with_registry(env_face, reg).has_errors())
	check("multi-anchor kind + pcb/net → invalid",
		schema.validate_with_registry(env_net, reg).has_errors())


# ── core/none for migrated v1 ─────────────────────────────────────────────────

func test_generic_kind_accepts_core_none_anchor() -> void:
	print("test_generic_kind_accepts_core_none_anchor:")
	var schema = _make_schema()
	if schema == null or not schema.has_method("validate"):
		check("AnnotationV2Schema has validate method", false)
		return
	var env = _make_envelope("text", "core", "none")
	var result = schema.validate(env)
	check("generic text kind + core/none anchor → valid (migrated v1)", not result.has_errors())


# ── Mock kind helpers — extend AnnotationKind (exists as v1 class) ─────────────

class _CadEdgeNoteKind extends AnnotationKind:
	func _init() -> void:
		name = &"cad_edge_note"
		display_name = "CAD Edge Note"
		owning_plugin = &"cad"

	func render(_ctx, _ann: Dictionary) -> void: pass

	func accepted_anchor_types() -> Array:
		return ["cad/edge"]


class _MultiAnchorKind extends AnnotationKind:
	func _init() -> void:
		name = &"multi_cad_kind"
		display_name = "Multi CAD Kind"
		owning_plugin = &"cad"

	func render(_ctx, _ann: Dictionary) -> void: pass

	func accepted_anchor_types() -> Array:
		return ["cad/edge", "cad/face"]
