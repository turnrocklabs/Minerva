extends SceneTree
## Behavioral tests for AnnotationAnchorRegistry (task #2).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_anchor_registry.gd

const AnnotationAnchorRegistryScript = preload("res://Scripts/Services/Annotations/AnnotationAnchorRegistry.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_anchor_registry ===\n")

	print("-- registry: register/unregister/get --")
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
	test_anchor_registry_validate_missing_id_field_errors()
	test_anchor_registry_validate_missing_snapshot_field_errors()

	print("\n-- registry: summary dispatch --")
	test_anchor_registry_summary_dispatches_to_resolver()
	test_anchor_registry_summary_fallback_for_unknown()

	print("\n-- registry: plugin scoping/isolation --")
	test_anchor_registry_plugin_scoping_no_collision()
	test_anchor_registry_same_type_different_plugin_no_collision()
	test_anchor_registry_validate_routes_by_plugin_and_type()

	print("\n-- registry: repair + introspection --")
	test_anchor_registry_repair_dispatches_to_resolver()
	test_anchor_registry_repair_unknown_returns_null()
	test_anchor_registry_known_anchors_for_plugin()

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


func _valid_anchor(plugin: String, anchor_type: String, id: Variant) -> Dictionary:
	return {
		"plugin": plugin,
		"type": anchor_type,
		"id": id,
		"snapshot": {"position": [0.0, 0.0]}
	}


func _make_registry() -> RefCounted:
	return AnnotationAnchorRegistryScript.new()


func test_anchor_registry_register_and_get_resolver() -> void:
	print("test_anchor_registry_register_and_get_resolver:")
	var reg := _make_registry()
	var resolver := _AlwaysValidResolver.new()
	check("register returns true", reg.register("core", "text.range", resolver))
	check("get_resolver returns registered resolver", reg.get_resolver("core", "text.range") == resolver)


func test_anchor_registry_get_unknown_returns_null() -> void:
	print("test_anchor_registry_get_unknown_returns_null:")
	var reg := _make_registry()
	check("get_resolver for unknown returns null", reg.get_resolver("unknown_plugin", "unknown_type") == null)


func test_anchor_registry_double_register_rejected() -> void:
	print("test_anchor_registry_double_register_rejected:")
	var reg := _make_registry()
	var r1 := _AlwaysValidResolver.new()
	var r2 := _AlwaysValidResolver.new()
	check("first register succeeds", reg.register("core", "text.range", r1))
	check("second register fails", not reg.register("core", "text.range", r2))
	check("double register keeps original resolver", reg.get_resolver("core", "text.range") == r1)


func test_anchor_registry_unregister_removes_entry() -> void:
	print("test_anchor_registry_unregister_removes_entry:")
	var reg := _make_registry()
	var resolver := _AlwaysValidResolver.new()
	reg.register("cad", "edge", resolver)
	reg.unregister("cad", "edge")
	check("unregister removes resolver", reg.get_resolver("cad", "edge") == null)


func test_anchor_registry_unregister_unknown_is_noop() -> void:
	print("test_anchor_registry_unregister_unknown_is_noop:")
	var reg := _make_registry()
	reg.unregister("nonexistent", "nonexistent")
	check("unregister of unknown is no-op", true)


func test_anchor_registry_validate_dispatches_to_resolver() -> void:
	print("test_anchor_registry_validate_dispatches_to_resolver:")
	var reg := _make_registry()
	var resolver := _AlwaysValidResolver.new()
	reg.register("core", "text.range", resolver)
	var errors: Array = reg.validate_anchor(_valid_anchor("core", "text.range", {"start": 0, "end": 10}))
	check("validate_anchor dispatches to resolver", errors.is_empty())
	check("resolver saw validate call", resolver.validate_count == 1)


func test_anchor_registry_validate_unknown_type_returns_error() -> void:
	print("test_anchor_registry_validate_unknown_type_returns_error:")
	var errors: Array = _make_registry().validate_anchor(_valid_anchor("unknown_plugin", "unknown_type", 1))
	check("unknown anchor type returns errors", errors.size() > 0)
	check("error mentions unknown anchor type", str(errors[0]).contains("unknown anchor type"))


func test_anchor_registry_validate_missing_plugin_field_errors() -> void:
	print("test_anchor_registry_validate_missing_plugin_field_errors:")
	var errors: Array = _make_registry().validate_anchor({"type": "text.range", "id": 1, "snapshot": {"position": [0.0, 0.0]}})
	check("anchor missing plugin field returns errors", errors.size() > 0)
	check("error mentions plugin", str(errors[0]).contains("plugin"))


func test_anchor_registry_validate_missing_type_field_errors() -> void:
	print("test_anchor_registry_validate_missing_type_field_errors:")
	var errors: Array = _make_registry().validate_anchor({"plugin": "core", "id": 1, "snapshot": {"position": [0.0, 0.0]}})
	check("anchor missing type field returns errors", errors.size() > 0)
	check("error mentions type", str(errors[0]).contains("type"))


func test_anchor_registry_validate_missing_id_field_errors() -> void:
	print("test_anchor_registry_validate_missing_id_field_errors:")
	var errors: Array = _make_registry().validate_anchor({"plugin": "core", "type": "text.range", "snapshot": {"position": [0.0, 0.0]}})
	check("anchor missing id field returns errors", errors.size() > 0)
	check("error mentions id", "id" in str(errors))


func test_anchor_registry_validate_missing_snapshot_field_errors() -> void:
	print("test_anchor_registry_validate_missing_snapshot_field_errors:")
	var errors: Array = _make_registry().validate_anchor({"plugin": "core", "type": "text.range", "id": 1})
	check("anchor missing snapshot field returns errors", errors.size() > 0)
	check("error mentions snapshot", "snapshot" in str(errors))


func test_anchor_registry_summary_dispatches_to_resolver() -> void:
	print("test_anchor_registry_summary_dispatches_to_resolver:")
	var reg := _make_registry()
	var resolver := _SummaryResolver.new()
	reg.register("core", "text.range", resolver)
	var summary: String = reg.summary(_valid_anchor("core", "text.range", {"start": 5, "end": 20}), null)
	check_eq("summary dispatches to resolver", summary, "text range 5-20")


func test_anchor_registry_summary_fallback_for_unknown() -> void:
	print("test_anchor_registry_summary_fallback_for_unknown:")
	var summary: String = _make_registry().summary(_valid_anchor("myplugin", "mytype", 99), null)
	check_eq("unknown anchor falls back to plugin.type:id format", summary, "myplugin.mytype:99")


func test_anchor_registry_plugin_scoping_no_collision() -> void:
	print("test_anchor_registry_plugin_scoping_no_collision:")
	var reg := _make_registry()
	var r_cad := _AlwaysValidResolver.new()
	var r_pcb := _AlwaysValidResolver.new()
	reg.register("cad", "edge", r_cad)
	reg.register("pcb", "net", r_pcb)
	check("cad/edge resolver isolated", reg.get_resolver("cad", "edge") == r_cad)
	check("pcb/net resolver isolated", reg.get_resolver("pcb", "net") == r_pcb)


func test_anchor_registry_same_type_different_plugin_no_collision() -> void:
	print("test_anchor_registry_same_type_different_plugin_no_collision:")
	var reg := _make_registry()
	var r_cad := _AlwaysValidResolver.new()
	var r_pcb := _AlwaysValidResolver.new()
	check("cad/component registers", reg.register("cad", "component", r_cad))
	check("pcb/component registers independently", reg.register("pcb", "component", r_pcb))
	check("same type name scoped by plugin", reg.get_resolver("cad", "component") != reg.get_resolver("pcb", "component"))


func test_anchor_registry_validate_routes_by_plugin_and_type() -> void:
	print("test_anchor_registry_validate_routes_by_plugin_and_type:")
	var reg := _make_registry()
	var r_cad := _AlwaysValidResolver.new()
	var r_pcb := _AlwaysValidResolver.new()
	reg.register("cad", "edge", r_cad)
	reg.register("pcb", "net", r_pcb)
	check("cad/edge validates via cad resolver", reg.validate_anchor(_valid_anchor("cad", "edge", 5)).is_empty())
	check("pcb/net validates via pcb resolver", reg.validate_anchor(_valid_anchor("pcb", "net", "VCC")).is_empty())
	check_eq("cad resolver called once", r_cad.validate_count, 1)
	check_eq("pcb resolver called once", r_pcb.validate_count, 1)


func test_anchor_registry_repair_dispatches_to_resolver() -> void:
	print("test_anchor_registry_repair_dispatches_to_resolver:")
	var reg := _make_registry()
	var resolver := _RepairResolver.new()
	reg.register("core", "text.range", resolver)
	var repaired: Variant = reg.repair(_valid_anchor("core", "text.range", {"start": 1, "end": 2}), null)
	check("repair dispatches to resolver", repaired is Dictionary)
	check_eq("repair returns updated id", repaired.get("id", {}).get("start", -1), 2)


func test_anchor_registry_repair_unknown_returns_null() -> void:
	print("test_anchor_registry_repair_unknown_returns_null:")
	check("unknown repair returns null", _make_registry().repair(_valid_anchor("missing", "thing", 1), null) == null)


func test_anchor_registry_known_anchors_for_plugin() -> void:
	print("test_anchor_registry_known_anchors_for_plugin:")
	var reg := _make_registry()
	reg.register("cad", "edge", _AlwaysValidResolver.new())
	reg.register("cad", "face", _AlwaysValidResolver.new())
	reg.register("pcb", "net", _AlwaysValidResolver.new())
	var cad_anchors: Array = reg.known_anchors_for("cad")
	check_eq("known_anchors_for cad returns 2 entries", cad_anchors.size(), 2)
	check("cad anchors includes edge", "edge" in cad_anchors)
	check("cad anchors includes face", "face" in cad_anchors)
	check_eq("known_anchors_for pcb returns 1 entry", reg.known_anchors_for("pcb").size(), 1)


class _AlwaysValidResolver extends RefCounted:
	var validate_count := 0

	func validate(_anchor: Dictionary) -> Array:
		validate_count += 1
		return []

	func summary(_anchor: Dictionary, _host: Object) -> String:
		return "valid"

	func repair(_anchor: Dictionary, _host: Object) -> Variant:
		return null


class _SummaryResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array:
		return []

	func summary(anchor: Dictionary, _host: Object) -> String:
		var id: Variant = anchor.get("id", {})
		if id is Dictionary:
			return "text range %d-%d" % [id.get("start", 0), id.get("end", 0)]
		return "text range unknown"


class _RepairResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array:
		return []

	func summary(_anchor: Dictionary, _host: Object) -> String:
		return "repairable"

	func repair(anchor: Dictionary, _host: Object) -> Variant:
		var repaired := anchor.duplicate(true)
		repaired["id"]["start"] = 2
		return repaired
