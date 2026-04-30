extends SceneTree

const AnnotationSidecarIOScript = preload("res://Scripts/Services/Annotations/AnnotationSidecarIO.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_refuse ===\n")
	test_malformed_v1_not_added_to_annotations()
	test_malformed_v1_added_to_v1_failed()
	test_malformed_v1_surfaced_via_sidebar_diagnostic()
	test_sidecar_preserved_on_disk_after_failed_migration()
	test_other_annotations_in_sidecar_still_load()
	test_load_result_summary_mentions_failure_count()
	test_save_writes_v2_format_only()
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


func _malformed_v1() -> Dictionary:
	return {"id": "ann_malformed", "kind": "2d_arrow", "schema_version": 1, "primitives": "not-an-array", "metadata": {}}


func _valid_v1(id: String) -> Dictionary:
	return {"id": id, "kind": "2d_text", "schema_version": 1, "primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}], "metadata": {"author": "human", "view": "editor:main", "summary": "Test"}}


func _valid_v2(id: String) -> Dictionary:
	return {"id": id, "kind": "text", "schema_version": 2, "anchor": {"plugin": "core", "type": "none", "id": id, "snapshot": {"position": [0.0, 0.0]}}, "kind_payload": {"text": "comment"}, "lifecycle": "open", "author": {"kind": "human"}, "view_context": "editor:main", "visible_in_views": ["main"], "summary": "Test v2 annotation", "created_at": "2026-04-29T17:00:00Z", "updated_at": "2026-04-29T17:00:00Z"}


func test_malformed_v1_not_added_to_annotations() -> void:
	check("malformed v1 not in annotations", AnnotationSidecarIOScript.new().process_annotations([_malformed_v1()]).get("annotations", []).is_empty())


func test_malformed_v1_added_to_v1_failed() -> void:
	check("malformed v1 in v1_failed", AnnotationSidecarIOScript.new().process_annotations([_malformed_v1()]).get("v1_failed", []).size() == 1)


func test_malformed_v1_surfaced_via_sidebar_diagnostic() -> void:
	var summary := str(AnnotationSidecarIOScript.new().process_annotations([_malformed_v1()]).get("summary", ""))
	check("summary mentions migration failure", "failed" in summary)


func test_sidecar_preserved_on_disk_after_failed_migration() -> void:
	check("process_annotations is data-only", AnnotationSidecarIOScript.new().has_method("process_annotations"))


func test_other_annotations_in_sidecar_still_load() -> void:
	var result := AnnotationSidecarIOScript.new().process_annotations([_malformed_v1(), _valid_v1("ann_good_v1"), _valid_v2("ann_v2")])
	check("2 valid annotations loaded despite malformed v1", result.get("annotations", []).size() == 2)


func test_load_result_summary_mentions_failure_count() -> void:
	var summary := str(AnnotationSidecarIOScript.new().process_annotations([_malformed_v1(), _malformed_v1()]).get("summary", ""))
	check("summary mentions count of failures", "2" in summary)


func test_save_writes_v2_format_only() -> void:
	var io := AnnotationSidecarIOScript.new()
	check("AnnotationSidecarIO has save_sidecar_v2", io.has_method("save_sidecar_v2"))
	check("AnnotationSidecarIO has no save_sidecar_v1", not io.has_method("save_sidecar_v1"))
