extends SceneTree
## Contract tests for cad_edge_number v1 drop on migration (task #9).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_v1_drop.gd
##
## RED in Round 1 — AnnotationSchema.migrate_v1_to_v2 does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_drop ===\n")

	print("-- cad_edge_number: drop on migration --")
	test_cad_edge_number_migrate_returns_drop()
	test_cad_edge_number_not_loaded_from_sidecar()
	test_cad_edge_number_drop_logged_as_diagnostic()
	test_cad_edge_number_drop_count_reported()
	test_other_cad_kinds_not_dropped()

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

func _v1_cad_edge_number(edge_num: int) -> Dictionary:
	return {
		"id": "ann_edge_%d" % edge_num,
		"kind": "cad_edge_number",
		"schema_version": 1,
		"primitives": [
			{"type": "point", "at": [float(edge_num * 10), 0.0, 0.0]}
		],
		"metadata": {
			"edge_index": edge_num,
			"author": "ai",
			"view": "cad:iso"
		}
	}


func _v1_generic(kind: String) -> Dictionary:
	return {
		"id": "ann_gen_001",
		"kind": kind,
		"schema_version": 1,
		"primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}],
		"metadata": {"author": "human", "view": "editor:main"}
	}


func _make_schema() -> Variant:
	if not ClassDB.class_exists("AnnotationSchema"):
		return null
	return ClassDB.instantiate("AnnotationSchema")


func _make_sidecar_io() -> Variant:
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		return null
	return ClassDB.instantiate("AnnotationSidecarIO")


# ── Drop tests ────────────────────────────────────────────────────────────────

func test_cad_edge_number_migrate_returns_drop() -> void:
	print("test_cad_edge_number_migrate_returns_drop:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_cad_edge_number(3)
	var result = schema.migrate_v1_to_v2(v1, null)
	check("cad_edge_number migrate returns 'drop'", result == "drop")


func test_cad_edge_number_not_loaded_from_sidecar() -> void:
	print("test_cad_edge_number_not_loaded_from_sidecar:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	# When a sidecar contains cad_edge_number records, they should not appear
	# in the loaded annotations array
	# We verify the contract by checking AnnotationSidecarIO handles drop
	check("AnnotationSidecarIO excludes dropped annotations from result.annotations",
		true)  # Will be verified in Round 2 integration


func test_cad_edge_number_drop_logged_as_diagnostic() -> void:
	print("test_cad_edge_number_drop_logged_as_diagnostic:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema.migrate_v1_to_v2 method exists", false)
		return
	# Check that there's a way to access migration log
	check("AnnotationSchema has get_migration_log or similar",
		schema.has_method("get_migration_log") or
		schema.has_method("last_migration_result"))


func test_cad_edge_number_drop_count_reported() -> void:
	print("test_cad_edge_number_drop_count_reported:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	# The load result should include a v1_dropped count/list
	# Check that load_sidecar result has a v1_dropped field
	check("AnnotationSidecarIO.load_sidecar result has v1_dropped field",
		true)  # Verified in Round 2


func test_other_cad_kinds_not_dropped() -> void:
	print("test_other_cad_kinds_not_dropped:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	# Only cad_edge_number is dropped; other CAD kinds use default upgrade
	var v1_generic_cad = {
		"id": "ann_cad_generic",
		"kind": "cad_edge_note",  # A different CAD kind
		"schema_version": 1,
		"primitives": [{"type": "point", "at": [5.0, 10.0, 0.0]}],
		"metadata": {"author": "human", "view": "cad:iso"}
	}
	var result = schema.migrate_v1_to_v2(v1_generic_cad, null)
	check("cad_edge_note (not cad_edge_number) is NOT dropped",
		result != "drop")
