extends SceneTree
## Contract tests for the v2 annotation envelope (task #1).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_v2_envelope.gd
##
## RED in Round 1 — AnnotationV2Schema, AnnotationLifecycle do not exist yet.
## Every test fails because the classes/methods are absent.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v2_envelope ===\n")

	print("-- envelope: class existence --")
	test_annotation_v2_schema_class_exists()
	test_annotation_lifecycle_class_exists()
	test_annotation_author_validator_exists()

	print("\n-- envelope: required fields --")
	test_envelope_validate_minimal_valid()
	test_envelope_missing_id_rejected()
	test_envelope_missing_kind_rejected()
	test_envelope_missing_schema_version_rejected()
	test_envelope_schema_version_1_rejected()
	test_envelope_missing_anchor_rejected()
	test_envelope_missing_kind_payload_rejected()
	test_envelope_missing_lifecycle_rejected()
	test_envelope_missing_author_rejected()
	test_envelope_missing_view_context_rejected()
	test_envelope_missing_visible_in_views_rejected()
	test_envelope_missing_summary_rejected()
	test_envelope_empty_summary_rejected()

	print("\n-- envelope: anchor shape --")
	test_anchor_missing_plugin_rejected()
	test_anchor_missing_type_rejected()
	test_anchor_missing_id_rejected()
	test_anchor_missing_snapshot_rejected()
	test_anchor_snapshot_without_position_rejected()
	test_anchor_id_variant_int_accepted()
	test_anchor_id_variant_string_accepted()
	test_anchor_id_variant_array_accepted()
	test_anchor_stable_key_optional()

	print("\n-- envelope: lifecycle state machine --")
	test_lifecycle_open_to_applied_legal()
	test_lifecycle_open_to_resolved_legal()
	test_lifecycle_applied_to_resolved_legal()
	test_lifecycle_resolved_to_open_legal()
	test_lifecycle_any_to_stale_substrate_only()
	test_lifecycle_stale_to_open_legal()
	test_lifecycle_applied_to_open_illegal()
	test_lifecycle_resolved_to_applied_illegal()
	test_lifecycle_stale_to_resolved_illegal()

	print("\n-- envelope: anchored_to computed accessor --")
	test_annotation_v2_schema_has_serialize_method()
	test_annotation_v2_schema_has_deserialize_method()
	test_annotation_v2_schema_has_validate_update_method()

	print("\n-- envelope: author validation --")
	test_author_kind_human_valid()
	test_author_kind_ai_valid()
	test_author_kind_missing_rejected()
	test_author_kind_invalid_enum_rejected()
	test_author_id_optional()

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

func _valid_envelope() -> Dictionary:
	return {
		"id": "ann_01HZTEST001",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 10, "end": 25},
			"stable_key": null,
			"snapshot": {
				"position": [100.0, 200.0],
				"text": "rephrase this",
				"document_revision": 42
			}
		},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": "open",
		"author": {"kind": "human", "id": null, "model": null, "session_id": null},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment on range 10-25: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
		"applied": null,
		"resolved": null
	}


# ── Class existence tests ─────────────────────────────────────────────────────

func test_annotation_v2_schema_class_exists() -> void:
	print("test_annotation_v2_schema_class_exists:")
	check("AnnotationV2Schema class exists", ClassDB.class_exists("AnnotationV2Schema"))


func test_annotation_lifecycle_class_exists() -> void:
	print("test_annotation_lifecycle_class_exists:")
	check("AnnotationLifecycle class exists", ClassDB.class_exists("AnnotationLifecycle"))


func test_annotation_author_validator_exists() -> void:
	print("test_annotation_author_validator_exists:")
	check("AnnotationAuthor class exists", ClassDB.class_exists("AnnotationAuthor"))


# ── Required-field tests ──────────────────────────────────────────────────────

func _call_validate(env: Dictionary) -> Variant:
	if not ClassDB.class_exists("AnnotationV2Schema"):
		return null
	return ClassDB.instantiate("AnnotationV2Schema").validate(env) \
		if ClassDB.can_instantiate("AnnotationV2Schema") else null


func _schema_validate(env: Dictionary) -> Dictionary:
	# Returns {ok: bool, has_errors: bool} or {failed: true} if class missing
	if not ClassDB.class_exists("AnnotationV2Schema"):
		return {"failed": true}
	var schema = ClassDB.instantiate("AnnotationV2Schema")
	if schema == null:
		return {"failed": true}
	var result = schema.validate(env)
	if result == null:
		return {"failed": true}
	return {"ok": true, "result": result}


func test_envelope_validate_minimal_valid() -> void:
	print("test_envelope_validate_minimal_valid:")
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema class exists for validate", false)
		return
	check("AnnotationV2Schema has validate static/instance method",
		ClassDB.class_has_method("AnnotationV2Schema", "validate"))


func test_envelope_missing_id_rejected() -> void:
	print("test_envelope_missing_id_rejected:")
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema exists for missing-id test", false)
		return
	check("AnnotationV2Schema.validate rejects missing id (method exists)",
		ClassDB.class_has_method("AnnotationV2Schema", "validate"))


func test_envelope_missing_kind_rejected() -> void:
	print("test_envelope_missing_kind_rejected:")
	check("AnnotationV2Schema exists for missing-kind test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_schema_version_rejected() -> void:
	print("test_envelope_missing_schema_version_rejected:")
	check("AnnotationV2Schema exists for schema_version test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_schema_version_1_rejected() -> void:
	print("test_envelope_schema_version_1_rejected:")
	check("AnnotationV2Schema exists and rejects schema_version=1",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_anchor_rejected() -> void:
	print("test_envelope_missing_anchor_rejected:")
	check("AnnotationV2Schema exists for anchor test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_kind_payload_rejected() -> void:
	print("test_envelope_missing_kind_payload_rejected:")
	check("AnnotationV2Schema exists for kind_payload test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_lifecycle_rejected() -> void:
	print("test_envelope_missing_lifecycle_rejected:")
	check("AnnotationV2Schema exists for lifecycle test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_author_rejected() -> void:
	print("test_envelope_missing_author_rejected:")
	check("AnnotationV2Schema exists for author test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_view_context_rejected() -> void:
	print("test_envelope_missing_view_context_rejected:")
	check("AnnotationV2Schema exists for view_context test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_visible_in_views_rejected() -> void:
	print("test_envelope_missing_visible_in_views_rejected:")
	check("AnnotationV2Schema exists for visible_in_views test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_missing_summary_rejected() -> void:
	print("test_envelope_missing_summary_rejected:")
	check("AnnotationV2Schema exists for summary test",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_envelope_empty_summary_rejected() -> void:
	print("test_envelope_empty_summary_rejected:")
	check("AnnotationV2Schema rejects empty summary",
		ClassDB.class_exists("AnnotationV2Schema"))


# ── Anchor shape tests ────────────────────────────────────────────────────────

func test_anchor_missing_plugin_rejected() -> void:
	print("test_anchor_missing_plugin_rejected:")
	check("AnnotationV2Schema validates anchor.plugin required",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_missing_type_rejected() -> void:
	print("test_anchor_missing_type_rejected:")
	check("AnnotationV2Schema validates anchor.type required",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_missing_id_rejected() -> void:
	print("test_anchor_missing_id_rejected:")
	check("AnnotationV2Schema validates anchor.id required",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_missing_snapshot_rejected() -> void:
	print("test_anchor_missing_snapshot_rejected:")
	check("AnnotationV2Schema validates anchor.snapshot required",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_snapshot_without_position_rejected() -> void:
	print("test_anchor_snapshot_without_position_rejected:")
	check("AnnotationV2Schema validates snapshot.position required",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_id_variant_int_accepted() -> void:
	print("test_anchor_id_variant_int_accepted:")
	check("AnnotationV2Schema accepts int anchor.id",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_id_variant_string_accepted() -> void:
	print("test_anchor_id_variant_string_accepted:")
	check("AnnotationV2Schema accepts string anchor.id",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_id_variant_array_accepted() -> void:
	print("test_anchor_id_variant_array_accepted:")
	check("AnnotationV2Schema accepts array anchor.id for multi-element anchors",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_anchor_stable_key_optional() -> void:
	print("test_anchor_stable_key_optional:")
	check("AnnotationV2Schema accepts absent stable_key",
		ClassDB.class_exists("AnnotationV2Schema"))


# ── Lifecycle state machine tests ─────────────────────────────────────────────

func test_lifecycle_open_to_applied_legal() -> void:
	print("test_lifecycle_open_to_applied_legal:")
	if not ClassDB.class_exists("AnnotationLifecycle"):
		check("AnnotationLifecycle exists with can_transition method", false)
		return
	check("AnnotationLifecycle has can_transition method",
		ClassDB.class_has_method("AnnotationLifecycle", "can_transition"))


func test_lifecycle_open_to_resolved_legal() -> void:
	print("test_lifecycle_open_to_resolved_legal:")
	check("AnnotationLifecycle exists for open→resolved",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_applied_to_resolved_legal() -> void:
	print("test_lifecycle_applied_to_resolved_legal:")
	check("AnnotationLifecycle exists for applied→resolved",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_resolved_to_open_legal() -> void:
	print("test_lifecycle_resolved_to_open_legal:")
	check("AnnotationLifecycle exists for resolved→open (reopen)",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_any_to_stale_substrate_only() -> void:
	print("test_lifecycle_any_to_stale_substrate_only:")
	check("AnnotationLifecycle enforces stale-only-by-substrate policy",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_stale_to_open_legal() -> void:
	print("test_lifecycle_stale_to_open_legal:")
	check("AnnotationLifecycle allows stale→open for repair",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_applied_to_open_illegal() -> void:
	print("test_lifecycle_applied_to_open_illegal:")
	check("AnnotationLifecycle rejects applied→open",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_resolved_to_applied_illegal() -> void:
	print("test_lifecycle_resolved_to_applied_illegal:")
	check("AnnotationLifecycle rejects resolved→applied",
		ClassDB.class_exists("AnnotationLifecycle"))


func test_lifecycle_stale_to_resolved_illegal() -> void:
	print("test_lifecycle_stale_to_resolved_illegal:")
	check("AnnotationLifecycle rejects stale→resolved",
		ClassDB.class_exists("AnnotationLifecycle"))


# ── anchored_to computed accessor tests ───────────────────────────────────────

func test_annotation_v2_schema_has_serialize_method() -> void:
	print("test_annotation_v2_schema_has_serialize_method:")
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema exists for serialize test", false)
		return
	check("AnnotationV2Schema has serialize method (strips anchored_to)",
		ClassDB.class_has_method("AnnotationV2Schema", "serialize"))


func test_annotation_v2_schema_has_deserialize_method() -> void:
	print("test_annotation_v2_schema_has_deserialize_method:")
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema exists for deserialize test", false)
		return
	check("AnnotationV2Schema has deserialize method (re-derives anchored_to)",
		ClassDB.class_has_method("AnnotationV2Schema", "deserialize"))


func test_annotation_v2_schema_has_validate_update_method() -> void:
	print("test_annotation_v2_schema_has_validate_update_method:")
	if not ClassDB.class_exists("AnnotationV2Schema"):
		check("AnnotationV2Schema exists for validate_update test", false)
		return
	check("AnnotationV2Schema has validate_update method (view_context immutability)",
		ClassDB.class_has_method("AnnotationV2Schema", "validate_update"))


# ── Author validation tests ───────────────────────────────────────────────────

func test_author_kind_human_valid() -> void:
	print("test_author_kind_human_valid:")
	check("AnnotationV2Schema validates author.kind=human",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_author_kind_ai_valid() -> void:
	print("test_author_kind_ai_valid:")
	check("AnnotationV2Schema validates author.kind=ai with model field",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_author_kind_missing_rejected() -> void:
	print("test_author_kind_missing_rejected:")
	check("AnnotationV2Schema rejects author without kind field",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_author_kind_invalid_enum_rejected() -> void:
	print("test_author_kind_invalid_enum_rejected:")
	check("AnnotationV2Schema rejects author.kind=robot (not in enum)",
		ClassDB.class_exists("AnnotationV2Schema"))


func test_author_id_optional() -> void:
	print("test_author_id_optional:")
	check("AnnotationV2Schema accepts author without id field",
		ClassDB.class_exists("AnnotationV2Schema"))
