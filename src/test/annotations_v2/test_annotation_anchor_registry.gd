extends SceneTree
## Contract tests for AnnotationAnchorRegistry (task #2).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_anchor_registry.gd
##
## RED in Round 1 — AnnotationAnchorRegistry does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_anchor_registry ===\n")

	print("-- registry: class existence --")
	test_anchor_registry_class_exists()
	test_anchor_registry_methods_exist()

	print("\n-- registry: register/unregister/get --")
	test_anchor_registry_register_and_get_resolver()
	test_anchor_registry_get_unknown_returns_null()
	test_anchor_registry_double_register_rejected()
	test_anchor_registry_unregister_removes_entry()
	test_anchor_registry_unregister_unknown_is_noop()

	print("\n-- registry: validation dispatch --")
	test_anchor_registry_validate_dispatches_to_resolver()
	test_anchor_registry_validate_unknown_type_returns_error()
	test_anchor_registry_validate_missing_plugin_field_errors()
	test_anchor_registry_validate_missing_type_field_errors()

	print("\n-- registry: summary dispatch --")
	test_anchor_registry_summary_dispatches_to_resolver()
	test_anchor_registry_summary_fallback_for_unknown()

	print("\n-- registry: plugin scoping/isolation --")
	test_anchor_registry_plugin_scoping_no_collision()
	test_anchor_registry_validate_routes_by_plugin_and_type()

	print("\n-- registry: introspection --")
	test_anchor_registry_known_anchors_for_plugin()

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


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _valid_anchor(plugin: String, type: String, id: Variant) -> Dictionary:
	return {
		"plugin": plugin,
		"type": type,
		"id": id,
		"snapshot": {"position": [0.0, 0.0]}
	}


func _make_registry() -> Variant:
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		return null
	return ClassDB.instantiate("AnnotationAnchorRegistry")


func _make_resolver() -> Variant:
	# Returns a plain RefCounted mock — the registry protocol is duck-typed
	return _AlwaysValidResolver.new()


# ── Tests: class existence ────────────────────────────────────────────────────

func test_anchor_registry_class_exists() -> void:
	print("test_anchor_registry_class_exists:")
	check("AnnotationAnchorRegistry class exists",
		ClassDB.class_exists("AnnotationAnchorRegistry"))


func test_anchor_registry_methods_exist() -> void:
	print("test_anchor_registry_methods_exist:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null:
		check("AnnotationAnchorRegistry instantiable", false)
		return
	check("register method exists", reg.has_method("register"))
	check("unregister method exists", reg.has_method("unregister"))
	check("get_resolver method exists", reg.has_method("get_resolver"))
	check("validate_anchor method exists", reg.has_method("validate_anchor"))
	check("summary method exists", reg.has_method("summary"))
	check("known_anchors_for method exists", reg.has_method("known_anchors_for"))


# ── Tests: register/unregister/get ────────────────────────────────────────────

func test_anchor_registry_register_and_get_resolver() -> void:
	print("test_anchor_registry_register_and_get_resolver:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("get_resolver"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var resolver = _AlwaysValidResolver.new()
	reg.register("core", "text.range", resolver)
	var retrieved = reg.get_resolver("core", "text.range")
	check("get_resolver returns registered resolver", retrieved == resolver)


func test_anchor_registry_get_unknown_returns_null() -> void:
	print("test_anchor_registry_get_unknown_returns_null:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("get_resolver"):
		check("AnnotationAnchorRegistry instantiable with get_resolver", false)
		return
	var result = reg.get_resolver("unknown_plugin", "unknown_type")
	check("get_resolver for unknown returns null", result == null)


func test_anchor_registry_double_register_rejected() -> void:
	print("test_anchor_registry_double_register_rejected:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("get_resolver"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var r1 = _AlwaysValidResolver.new()
	var r2 = _AlwaysValidResolver.new()
	reg.register("core", "text.range", r1)
	reg.register("core", "text.range", r2)  # second register should be rejected
	var got = reg.get_resolver("core", "text.range")
	check("double register keeps original resolver", got == r1)


func test_anchor_registry_unregister_removes_entry() -> void:
	print("test_anchor_registry_unregister_removes_entry:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("unregister") or not reg.has_method("get_resolver"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var resolver = _AlwaysValidResolver.new()
	reg.register("cad", "edge", resolver)
	reg.unregister("cad", "edge")
	check("unregister removes resolver", reg.get_resolver("cad", "edge") == null)


func test_anchor_registry_unregister_unknown_is_noop() -> void:
	print("test_anchor_registry_unregister_unknown_is_noop:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("unregister"):
		check("AnnotationAnchorRegistry instantiable with unregister", false)
		return
	reg.unregister("nonexistent", "nonexistent")
	check("unregister of unknown is no-op (no crash)", true)


# ── Tests: validation dispatch ────────────────────────────────────────────────

func test_anchor_registry_validate_dispatches_to_resolver() -> void:
	print("test_anchor_registry_validate_dispatches_to_resolver:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("validate_anchor"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var resolver = _AlwaysValidResolver.new()
	reg.register("core", "text.range", resolver)
	var anchor = _valid_anchor("core", "text.range", {"start": 0, "end": 10})
	var errors = reg.validate_anchor(anchor)
	check("validate_anchor dispatches to resolver → empty errors", errors.size() == 0)


func test_anchor_registry_validate_unknown_type_returns_error() -> void:
	print("test_anchor_registry_validate_unknown_type_returns_error:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("validate_anchor"):
		check("AnnotationAnchorRegistry instantiable with validate_anchor", false)
		return
	var anchor = _valid_anchor("unknown_plugin", "unknown_type", 1)
	var errors = reg.validate_anchor(anchor)
	check("unknown anchor type → errors not empty", errors.size() > 0)
	if errors.size() > 0:
		check("error mentions unknown anchor type", errors[0].contains("unknown"))


func test_anchor_registry_validate_missing_plugin_field_errors() -> void:
	print("test_anchor_registry_validate_missing_plugin_field_errors:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("validate_anchor"):
		check("AnnotationAnchorRegistry instantiable with validate_anchor", false)
		return
	var anchor = {"type": "text.range", "id": 1, "snapshot": {"position": [0.0, 0.0]}}
	var errors = reg.validate_anchor(anchor)
	check("anchor missing plugin field → errors", errors.size() > 0)


func test_anchor_registry_validate_missing_type_field_errors() -> void:
	print("test_anchor_registry_validate_missing_type_field_errors:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("validate_anchor"):
		check("AnnotationAnchorRegistry instantiable with validate_anchor", false)
		return
	var anchor = {"plugin": "core", "id": 1, "snapshot": {"position": [0.0, 0.0]}}
	var errors = reg.validate_anchor(anchor)
	check("anchor missing type field → errors", errors.size() > 0)


# ── Tests: summary dispatch ───────────────────────────────────────────────────

func test_anchor_registry_summary_dispatches_to_resolver() -> void:
	print("test_anchor_registry_summary_dispatches_to_resolver:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("summary"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var resolver = _SummaryResolver.new()
	reg.register("core", "text.range", resolver)
	var anchor = _valid_anchor("core", "text.range", {"start": 5, "end": 20})
	var summary = reg.summary(anchor, null)
	check("summary dispatches to resolver", summary == "text range 5-20")


func test_anchor_registry_summary_fallback_for_unknown() -> void:
	print("test_anchor_registry_summary_fallback_for_unknown:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("summary"):
		check("AnnotationAnchorRegistry instantiable with summary", false)
		return
	var anchor = _valid_anchor("myplugin", "mytype", 99)
	var summary = reg.summary(anchor, null)
	# Fallback format: "{plugin}.{type}:{id}"
	check("unknown anchor falls back to plugin.type:id format",
		summary == "myplugin.mytype:99")


# ── Tests: plugin scoping ─────────────────────────────────────────────────────

func test_anchor_registry_plugin_scoping_no_collision() -> void:
	print("test_anchor_registry_plugin_scoping_no_collision:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("get_resolver"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var r_cad = _AlwaysValidResolver.new()
	var r_pcb = _AlwaysValidResolver.new()
	reg.register("cad", "edge", r_cad)
	reg.register("pcb", "net", r_pcb)
	check("cad/edge resolver isolated from pcb/net",
		reg.get_resolver("cad", "edge") == r_cad)
	check("pcb/net resolver isolated from cad/edge",
		reg.get_resolver("pcb", "net") == r_pcb)


func test_anchor_registry_validate_routes_by_plugin_and_type() -> void:
	print("test_anchor_registry_validate_routes_by_plugin_and_type:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("validate_anchor"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	var r_cad = _AlwaysValidResolver.new()
	var r_pcb = _AlwaysValidResolver.new()
	reg.register("cad", "edge", r_cad)
	reg.register("pcb", "net", r_pcb)
	var cad_anchor = _valid_anchor("cad", "edge", 5)
	var pcb_anchor = _valid_anchor("pcb", "net", "VCC")
	check("cad/edge validates via cad resolver",
		reg.validate_anchor(cad_anchor).size() == 0)
	check("pcb/net validates via pcb resolver",
		reg.validate_anchor(pcb_anchor).size() == 0)


# ── Tests: introspection ──────────────────────────────────────────────────────

func test_anchor_registry_known_anchors_for_plugin() -> void:
	print("test_anchor_registry_known_anchors_for_plugin:")
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var reg = _make_registry()
	if reg == null or not reg.has_method("register") or not reg.has_method("known_anchors_for"):
		check("AnnotationAnchorRegistry instantiable with methods", false)
		return
	reg.register("cad", "edge", _AlwaysValidResolver.new())
	reg.register("cad", "face", _AlwaysValidResolver.new())
	reg.register("pcb", "net", _AlwaysValidResolver.new())
	var cad_anchors = reg.known_anchors_for("cad")
	check("known_anchors_for cad returns 2 entries", cad_anchors.size() == 2)
	check("cad anchors includes edge", "edge" in cad_anchors)
	check("cad anchors includes face", "face" in cad_anchors)
	check("known_anchors_for pcb returns 1 entry", reg.known_anchors_for("pcb").size() == 1)


# ── Mock resolver helpers ─────────────────────────────────────────────────────

class _AlwaysValidResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array:
		return []
	func summary(_anchor: Dictionary, _host) -> String:
		return "valid"
	func repair(_anchor: Dictionary, _host) -> Variant:
		return null


class _SummaryResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array:
		return []
	func summary(anchor: Dictionary, _host) -> String:
		var id = anchor.get("id", {})
		if id is Dictionary:
			return "text range %d-%d" % [id.get("start", 0), id.get("end", 0)]
		return "text range unknown"
	func repair(_anchor: Dictionary, _host) -> Variant:
		return null
