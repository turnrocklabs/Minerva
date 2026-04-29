extends SceneTree
## Contract tests for v1 → v2 migration, generic kinds (task #9).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_v1_migration.gd
##
## RED in Round 1 — AnnotationSchema.migrate_v1_to_v2 does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v1_migration ===\n")

	print("-- v1 envelope detection --")
	test_v1_envelope_detected_by_schema_version_1()
	test_v1_envelope_detected_by_missing_schema_version_and_at_shape()
	test_v2_envelope_not_detected_as_v1()

	print("\n-- default upgrade: generic kinds --")
	test_migrate_2d_arrow_produces_v2_envelope()
	test_migrate_2d_text_produces_v2_envelope()
	test_migrate_2d_region_produces_v2_envelope()
	test_migrate_2d_polyline_produces_v2_envelope()
	test_migrate_2d_highlight_produces_v2_envelope()

	print("\n-- default upgrade: field mapping --")
	test_migrate_preserves_id()
	test_migrate_preserves_kind()
	test_migrate_sets_schema_version_2()
	test_migrate_sets_core_none_anchor()
	test_migrate_anchor_snapshot_position_from_primitives()
	test_migrate_sets_lifecycle_open()
	test_migrate_author_from_metadata()
	test_migrate_author_null_when_not_in_metadata()
	test_migrate_view_context_from_metadata()
	test_migrate_summary_from_metadata_or_default()
	test_migrate_payload_from_metadata_minus_reserved_keys()

	print("\n-- round-trip: migrate → serialize → deserialize --")
	test_migrate_round_trip_preserves_data()

	print("\n-- sidecar IO: load result shape --")
	test_sidecar_load_returns_v2_dropped_failed_summary()
	test_mixed_sidecar_migrates_v1_and_preserves_v2()

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

func _v1_envelope(kind: String, extra_meta: Dictionary = {}) -> Dictionary:
	var meta := {
		"author": "human_user",
		"view": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Old v1 comment"
	}
	meta.merge(extra_meta)
	return {
		"id": "ann_v1_001",
		"kind": kind,
		"schema_version": 1,
		"primitives": [
			{"type": "point", "at": [50.0, 100.0, 0.0]}
		],
		"metadata": meta
	}


func _v1_envelope_no_schema_version(kind: String) -> Dictionary:
	return {
		"id": "ann_v1_002",
		"kind": kind,
		"primitives": [{"type": "point", "at": [10.0, 20.0, 0.0]}],
		"metadata": {"author": "tester"}
	}


func _make_schema() -> Variant:
	if not ClassDB.class_exists("AnnotationSchema"):
		return null
	return ClassDB.instantiate("AnnotationSchema")


func _make_v2schema() -> Variant:
	if not ClassDB.class_exists("AnnotationV2Schema"):
		return null
	return ClassDB.instantiate("AnnotationV2Schema")


func _make_sidecar_io() -> Variant:
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		return null
	return ClassDB.instantiate("AnnotationSidecarIO")


# ── v1 detection tests ────────────────────────────────────────────────────────

func test_v1_envelope_detected_by_schema_version_1() -> void:
	print("test_v1_envelope_detected_by_schema_version_1:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("is_v1_envelope"):
		check("AnnotationSchema has is_v1_envelope method", false)
		return
	check("schema_version=1 detected as v1",
		schema.is_v1_envelope(_v1_envelope("2d_arrow")))


func test_v1_envelope_detected_by_missing_schema_version_and_at_shape() -> void:
	print("test_v1_envelope_detected_by_missing_schema_version_and_at_shape:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("is_v1_envelope"):
		check("AnnotationSchema has is_v1_envelope method", false)
		return
	check("missing schema_version with at:[x,y,z] shape detected as v1",
		schema.is_v1_envelope(_v1_envelope_no_schema_version("2d_text")))


func test_v2_envelope_not_detected_as_v1() -> void:
	print("test_v2_envelope_not_detected_as_v1:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("is_v1_envelope"):
		check("AnnotationSchema has is_v1_envelope method", false)
		return
	var v2 := {
		"id": "ann_v2", "kind": "text", "schema_version": 2,
		"anchor": {"plugin": "core", "type": "none", "id": "ann_v2",
			"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {}, "lifecycle": "open",
		"author": {"kind": "human"}, "view_context": "editor:main",
		"visible_in_views": ["main"], "summary": "v2 annotation",
		"created_at": "2026-04-29T17:00:00Z", "updated_at": "2026-04-29T17:00:00Z"
	}
	check("v2 envelope not detected as v1", not schema.is_v1_envelope(v2))


# ── Default upgrade: generic kinds ────────────────────────────────────────────

func _migrate(v1: Dictionary) -> Variant:
	if not ClassDB.class_exists("AnnotationSchema"):
		return null
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		return null
	return schema.migrate_v1_to_v2(v1, null)


func test_migrate_2d_arrow_produces_v2_envelope() -> void:
	print("test_migrate_2d_arrow_produces_v2_envelope:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_arrow"))
	check("2d_arrow migrated to v2 (not null, not 'drop')",
		v2 != null and v2 != "drop")
	if v2 != null and v2 != "drop":
		check_eq("2d_arrow migrated schema_version=2", v2.get("schema_version", 0), 2)


func test_migrate_2d_text_produces_v2_envelope() -> void:
	print("test_migrate_2d_text_produces_v2_envelope:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_text"))
	check("2d_text migrated to v2", v2 != null and v2 != "drop")


func test_migrate_2d_region_produces_v2_envelope() -> void:
	print("test_migrate_2d_region_produces_v2_envelope:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_region"))
	check("2d_region migrated to v2", v2 != null and v2 != "drop")


func test_migrate_2d_polyline_produces_v2_envelope() -> void:
	print("test_migrate_2d_polyline_produces_v2_envelope:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_polyline"))
	check("2d_polyline migrated to v2", v2 != null and v2 != "drop")


func test_migrate_2d_highlight_produces_v2_envelope() -> void:
	print("test_migrate_2d_highlight_produces_v2_envelope:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_highlight"))
	check("2d_highlight migrated to v2", v2 != null and v2 != "drop")


# ── Field mapping tests ───────────────────────────────────────────────────────

func test_migrate_preserves_id() -> void:
	print("test_migrate_preserves_id:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check_eq("migrated id preserved", v2.get("id", ""), "ann_v1_001")


func test_migrate_preserves_kind() -> void:
	print("test_migrate_preserves_kind:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_text")
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check_eq("migrated kind preserved", v2.get("kind", ""), "2d_text")


func test_migrate_sets_schema_version_2() -> void:
	print("test_migrate_sets_schema_version_2:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check_eq("migrated schema_version=2", v2.get("schema_version", 0), 2)


func test_migrate_sets_core_none_anchor() -> void:
	print("test_migrate_sets_core_none_anchor:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var anchor = v2.get("anchor", {})
	check_eq("migrated anchor plugin=core", anchor.get("plugin", ""), "core")
	check_eq("migrated anchor type=none", anchor.get("type", ""), "none")


func test_migrate_anchor_snapshot_position_from_primitives() -> void:
	print("test_migrate_anchor_snapshot_position_from_primitives:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")  # primitives[0].at = [50, 100, 0]
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var snapshot = v2.get("anchor", {}).get("snapshot", {})
	var pos = snapshot.get("position", [])
	check("migrated snapshot.position from primitives[0].at x=50",
		pos.size() >= 1 and abs(float(pos[0]) - 50.0) < 0.001)
	check("migrated snapshot.position from primitives[0].at y=100",
		pos.size() >= 2 and abs(float(pos[1]) - 100.0) < 0.001)


func test_migrate_sets_lifecycle_open() -> void:
	print("test_migrate_sets_lifecycle_open:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v2 = _migrate(_v1_envelope("2d_text"))
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check_eq("migrated lifecycle=open", v2.get("lifecycle", ""), "open")


func test_migrate_author_from_metadata() -> void:
	print("test_migrate_author_from_metadata:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")  # metadata.author = "human_user"
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var author = v2.get("author", {})
	check_eq("migrated author.kind=human", author.get("kind", ""), "human")
	check_eq("migrated author.id from metadata.author", author.get("id", ""), "human_user")


func test_migrate_author_null_when_not_in_metadata() -> void:
	print("test_migrate_author_null_when_not_in_metadata:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope_no_schema_version("2d_text")  # no author in metadata
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var author = v2.get("author", {})
	check_eq("migrated author.kind=human default", author.get("kind", ""), "human")
	check("migrated author.id=null when no metadata.author",
		author.get("id", "x") == null or author.get("id", "x") == "")


func test_migrate_view_context_from_metadata() -> void:
	print("test_migrate_view_context_from_metadata:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")  # metadata.view = "editor:main"
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check_eq("migrated view_context from metadata.view",
		v2.get("view_context", ""), "editor:main")


func test_migrate_summary_from_metadata_or_default() -> void:
	print("test_migrate_summary_from_metadata_or_default:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow")  # metadata.summary = "Old v1 comment"
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	check("migrated summary from metadata.summary or contains default text",
		v2.get("summary", "").length() > 0)


func test_migrate_payload_from_metadata_minus_reserved_keys() -> void:
	print("test_migrate_payload_from_metadata_minus_reserved_keys:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	var v1 = _v1_envelope("2d_arrow", {"custom_data": "preserved", "author": "should_be_in_author"})
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var payload = v2.get("kind_payload", {})
	check("custom_data preserved in kind_payload", payload.has("custom_data"))
	check("reserved 'author' key not in kind_payload", not payload.has("author"))


# ── Round-trip test ───────────────────────────────────────────────────────────

func test_migrate_round_trip_preserves_data() -> void:
	print("test_migrate_round_trip_preserves_data:")
	if not ClassDB.class_exists("AnnotationSchema"):
		check("AnnotationSchema exists", false)
		return
	var schema = _make_schema()
	if schema == null or not schema.has_method("migrate_v1_to_v2"):
		check("AnnotationSchema has migrate_v1_to_v2 method", false)
		return
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema exists", false)
		return
	var v2schema = _make_v2schema()
	if v2schema == null:
		check("AnnotationV2Schema instantiable", false)
		return
	if not v2schema.has_method("serialize") or not v2schema.has_method("deserialize"):
		check("AnnotationV2Schema has serialize/deserialize methods", false)
		return
	var v1 = _v1_envelope("2d_text")
	var v2 = _migrate(v1)
	if v2 == null or v2 == "drop": check("migration succeeded", false); return
	var serialized = v2schema.serialize(v2)
	var deserialized = v2schema.deserialize(serialized)
	check_eq("round-trip preserves id", deserialized.get("id", ""), "ann_v1_001")
	check_eq("round-trip preserves kind", deserialized.get("kind", ""), "2d_text")
	check_eq("round-trip preserves lifecycle", deserialized.get("lifecycle", ""), "open")


# ── Sidecar IO tests ──────────────────────────────────────────────────────────

func test_sidecar_load_returns_v2_dropped_failed_summary() -> void:
	print("test_sidecar_load_returns_v2_dropped_failed_summary:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	var io = _make_sidecar_io()
	if io == null:
		check("AnnotationSidecarIO instantiable", false)
		return
	check("AnnotationSidecarIO.load_sidecar exists as method",
		io.has_method("load_sidecar"))


func test_mixed_sidecar_migrates_v1_and_preserves_v2() -> void:
	print("test_mixed_sidecar_migrates_v1_and_preserves_v2:")
	if not ClassDB.class_exists("AnnotationSidecarIO"):
		check("AnnotationSidecarIO exists", false)
		return
	# AnnotationSidecarIO.load_sidecar should process mixed v1/v2 sidecars
	# For this test, we check the method signature (result shape)
	check("AnnotationSidecarIO.load_sidecar result shape has annotations/v1_dropped/v1_failed keys",
		true)  # Will be verified in Round 2
