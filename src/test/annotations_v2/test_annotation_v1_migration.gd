extends SceneTree

const AnnotationSchemaScript = preload("res://Scripts/Services/Annotations/AnnotationSchema.gd")
const AnnotationV2SchemaScript = preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const AnnotationSidecarIOScript = preload("res://Scripts/Services/Annotations/AnnotationSidecarIO.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_migration ===\n")
	test_v1_detection()
	test_generic_kinds_migrate()
	test_field_mapping()
	test_round_trip()
	test_sidecar_result_shape()
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


func _v1(kind: String, extra_meta: Dictionary = {}) -> Dictionary:
	var meta := {"author": "human_user", "view": "editor:main", "visible_in_views": ["main"], "summary": "Old v1 comment"}
	meta.merge(extra_meta, true)
	return {"id": "ann_v1_001", "kind": kind, "schema_version": 1, "primitives": [{"type": "point", "at": [50.0, 100.0, 0.0]}], "metadata": meta}


func _v1_no_schema(kind: String) -> Dictionary:
	return {"id": "ann_v1_002", "kind": kind, "primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}], "metadata": {}}


func _v2(id: String = "ann_v2") -> Dictionary:
	return {"id": id, "kind": "text", "schema_version": 2, "anchor": {"plugin": "core", "type": "none", "id": id, "snapshot": {"position": [0.0, 0.0]}}, "kind_payload": {}, "lifecycle": "open", "author": {"kind": "human"}, "view_context": "editor:main", "visible_in_views": ["main"], "summary": "v2 annotation", "created_at": "2026-04-29T17:00:00Z", "updated_at": "2026-04-29T17:00:00Z"}


func _migrate(v1: Dictionary) -> Variant:
	return AnnotationSchemaScript.new().migrate_v1_to_v2(v1, null)


func test_v1_detection() -> void:
	var schema := AnnotationSchemaScript.new()
	check("schema_version=1 detected as v1", schema.is_v1_envelope(_v1("2d_arrow")))
	check("missing schema_version with v1 point shape detected", schema.is_v1_envelope(_v1_no_schema("2d_text")))
	check("v2 envelope not detected as v1", not schema.is_v1_envelope(_v2()))


func test_generic_kinds_migrate() -> void:
	for kind in ["2d_arrow", "2d_text", "2d_region", "2d_polyline", "2d_highlight"]:
		var migrated: Variant = _migrate(_v1(kind))
		check("%s migrated to v2" % kind, migrated is Dictionary and migrated.get("schema_version", 0) == 2)


func test_field_mapping() -> void:
	var migrated: Dictionary = _migrate(_v1("2d_text", {"custom_data": "preserved"}))
	check("migrated id preserved", migrated.get("id", "") == "ann_v1_001")
	check("migrated kind preserved", migrated.get("kind", "") == "2d_text")
	check("migrated schema_version=2", migrated.get("schema_version", 0) == 2)
	check("migrated anchor plugin=core", migrated.get("anchor", {}).get("plugin", "") == "core")
	check("migrated anchor type=none", migrated.get("anchor", {}).get("type", "") == "none")
	var pos: Array = migrated.get("anchor", {}).get("snapshot", {}).get("position", [])
	check("migrated snapshot position x", pos.size() >= 2 and abs(float(pos[0]) - 50.0) < 0.001)
	check("migrated snapshot position y", pos.size() >= 2 and abs(float(pos[1]) - 100.0) < 0.001)
	check("migrated lifecycle=open", migrated.get("lifecycle", "") == "open")
	check("migrated author.kind=human", migrated.get("author", {}).get("kind", "") == "human")
	check("migrated author.id from metadata", migrated.get("author", {}).get("id", "") == "human_user")
	var no_author: Dictionary = _migrate(_v1_no_schema("2d_text"))
	check("missing author defaults human", no_author.get("author", {}).get("kind", "") == "human")
	check("missing author id null", no_author.get("author", {}).get("id", "x") == null)
	check("view_context from metadata.view", migrated.get("view_context", "") == "editor:main")
	check("summary from metadata", migrated.get("summary", "") == "Old v1 comment")
	check("custom metadata preserved in payload", migrated.get("kind_payload", {}).get("custom_data", "") == "preserved")
	check("reserved author not in payload", not migrated.get("kind_payload", {}).has("author"))


func test_round_trip() -> void:
	var v2schema := AnnotationV2SchemaScript.new()
	var deserialized: Dictionary = v2schema.deserialize(v2schema.serialize(_migrate(_v1("2d_text"))))
	check("round-trip preserves id", deserialized.get("id", "") == "ann_v1_001")
	check("round-trip preserves kind", deserialized.get("kind", "") == "2d_text")
	check("round-trip preserves lifecycle", deserialized.get("lifecycle", "") == "open")


func test_sidecar_result_shape() -> void:
	var result: Dictionary = AnnotationSidecarIOScript.new().process_annotations([_v1("2d_text"), _v2("ann_existing")])
	check("sidecar result has annotations", result.has("annotations"))
	check("sidecar result has v1_dropped", result.has("v1_dropped"))
	check("sidecar result has v1_failed", result.has("v1_failed"))
	check("mixed sidecar migrates v1 and preserves v2", result.get("annotations", []).size() == 2)
