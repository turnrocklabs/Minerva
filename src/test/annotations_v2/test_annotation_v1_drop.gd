extends SceneTree

const AnnotationSchemaScript = preload("res://Scripts/Services/Annotations/AnnotationSchema.gd")
const AnnotationSidecarIOScript = preload("res://Scripts/Services/Annotations/AnnotationSidecarIO.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_drop ===\n")
	test_cad_edge_number_migrate_returns_drop()
	test_cad_edge_number_not_loaded_from_sidecar()
	test_cad_edge_number_drop_logged_as_diagnostic()
	test_cad_edge_number_drop_count_reported()
	test_other_cad_kinds_not_dropped()
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


func _v1(kind: String, id: String = "ann_v1") -> Dictionary:
	return {"id": id, "kind": kind, "schema_version": 1, "primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}], "metadata": {"author": "human", "view": "editor:main"}}


func test_cad_edge_number_migrate_returns_drop() -> void:
	check("cad_edge_number migrate returns drop", AnnotationSchemaScript.new().migrate_v1_to_v2(_v1("cad_edge_number"), null) == "drop")


func test_cad_edge_number_not_loaded_from_sidecar() -> void:
	var result := AnnotationSidecarIOScript.new().process_annotations([_v1("cad_edge_number"), _v1("2d_text", "ann_good")])
	check("dropped annotation excluded from annotations", result.get("annotations", []).size() == 1)


func test_cad_edge_number_drop_logged_as_diagnostic() -> void:
	var schema := AnnotationSchemaScript.new()
	schema.migrate_v1_to_v2(_v1("cad_edge_number"), null)
	check("drop logged as diagnostic", schema.get_migration_log().size() == 1)


func test_cad_edge_number_drop_count_reported() -> void:
	var result := AnnotationSidecarIOScript.new().process_annotations([_v1("cad_edge_number")])
	check("v1_dropped count reported", result.get("v1_dropped", []).size() == 1)


func test_other_cad_kinds_not_dropped() -> void:
	var result: Variant = AnnotationSchemaScript.new().migrate_v1_to_v2(_v1("cad_edge_note"), null)
	check("cad_edge_note not dropped", not (result is String and result == "drop"))
