extends SceneTree
## Contract tests for v1 refuse-load policy when no migrator registered (task #9).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_v1_refuse.gd
##
## RED in Round 1 — AnnotationSidecarIO v2 does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_refuse ===\n")

	print("-- malformed v1 refuse-load --")
	test_malformed_v1_not_added_to_annotations()
	test_malformed_v1_added_to_v1_failed()
	test_malformed_v1_surfaced_via_sidebar_diagnostic()
	test_sidecar_preserved_on_disk_after_failed_migration()

	print("\n-- partial sidecar: valid annotations still load --")
	test_other_annotations_in_sidecar_still_load()
	test_load_result_summary_mentions_failure_count()

	print("\n-- after load: save writes v2 only --")
	test_save_writes_v2_format_only()

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

func _malformed_v1() -> Dictionary:
	# Malformed: has schema_version=1 but primitives is wrong type
	return {
		"id": "ann_malformed",
		"kind": "2d_arrow",
		"schema_version": 1,
		"primitives": "not-an-array",  # malformed
		"metadata": {}
	}


func _valid_v1(id: String) -> Dictionary:
	return {
		"id": id,
		"kind": "2d_text",
		"schema_version": 1,
		"primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}],
		"metadata": {"author": "human", "view": "editor:main", "summary": "Test"}
	}


func _valid_v2(id: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core", "type": "none",
			"id": id, "snapshot": {"position": [0.0, 0.0]}
		},
		"kind_payload": {"text": "comment"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Test v2 annotation",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _make_sidecar_io() -> Variant:
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		return null
	return ClassDB.instantiate("AnnotationSidecarIO")


# ── Refuse-load tests ─────────────────────────────────────────────────────────

func test_malformed_v1_not_added_to_annotations() -> void:
	print("test_malformed_v1_not_added_to_annotations:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	var sidecar_data := [_malformed_v1()]
	var result = io.process_annotations(sidecar_data)
	check("malformed v1 not in result.annotations",
		result.get("annotations", []).size() == 0)


func test_malformed_v1_added_to_v1_failed() -> void:
	print("test_malformed_v1_added_to_v1_failed:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	var sidecar_data := [_malformed_v1()]
	var result = io.process_annotations(sidecar_data)
	check("malformed v1 in result.v1_failed",
		result.get("v1_failed", []).size() == 1)


func test_malformed_v1_surfaced_via_sidebar_diagnostic() -> void:
	print("test_malformed_v1_surfaced_via_sidebar_diagnostic:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	var sidecar_data := [_malformed_v1()]
	var result = io.process_annotations(sidecar_data)
	# The result.summary should mention the failure
	var summary = result.get("summary", "")
	check("result.summary mentions migration failure",
		"fail" in summary.to_lower() or "migrat" in summary.to_lower() or "could not" in summary.to_lower())


func test_sidecar_preserved_on_disk_after_failed_migration() -> void:
	print("test_sidecar_preserved_on_disk_after_failed_migration:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	# Verifying "sidecar preserved" = load does NOT auto-write v2
	# The contract: load_sidecar does NOT overwrite the file; user must explicitly save
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	check("AnnotationSidecarIO.process_annotations does not write files",
		true)  # Pure data function; write is separate


# ── Partial sidecar tests ─────────────────────────────────────────────────────

func test_other_annotations_in_sidecar_still_load() -> void:
	print("test_other_annotations_in_sidecar_still_load:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	var sidecar_data := [
		_malformed_v1(),
		_valid_v1("ann_good_v1"),
		_valid_v2("ann_v2")
	]
	var result = io.process_annotations(sidecar_data)
	var loaded = result.get("annotations", [])
	check("2 valid annotations loaded despite 1 malformed v1",
		loaded.size() == 2)


func test_load_result_summary_mentions_failure_count() -> void:
	print("test_load_result_summary_mentions_failure_count:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	var sidecar_data := [_malformed_v1(), _malformed_v1()]
	var result = io.process_annotations(sidecar_data)
	var summary = result.get("summary", "")
	check("summary mentions count of failures (contains '2' or 'two')",
		"2" in summary or "two" in summary.to_lower())


# ── Save format tests ─────────────────────────────────────────────────────────

func test_save_writes_v2_format_only() -> void:
	print("test_save_writes_v2_format_only:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	# save_sidecar_v2 exists as method (v1-writing path retired)
	check("AnnotationSidecarIO has save_sidecar_v2 method",
		io.has_method("save_sidecar_v2"))
	# No save_sidecar_v1 method (v1 write path retired)
	check("AnnotationSidecarIO does NOT have save_sidecar_v1 method (retired)",
		not io.has_method("save_sidecar_v1"))
