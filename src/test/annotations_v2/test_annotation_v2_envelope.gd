extends SceneTree
## Behavioral contract tests for the v2 annotation envelope (task #1).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_v2_envelope.gd

const AnnotationV2SchemaScript = preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const AnnotationLifecycleScript = preload("res://Scripts/Services/Annotations/AnnotationLifecycle.gd")
const AnnotationAuthorScript = preload("res://Scripts/Services/Annotations/AnnotationAuthor.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_v2_envelope ===\n")

	print("-- envelope: required fields --")
	test_envelope_validate_minimal_valid()
	test_envelope_empty_dict_rejected()
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
	test_lifecycle_open_to_stale_legal()
	test_lifecycle_applied_to_resolved_legal()
	test_lifecycle_resolved_to_open_legal()
	test_lifecycle_stale_to_open_legal()
	test_lifecycle_applied_to_open_illegal()
	test_lifecycle_resolved_to_applied_illegal()
	test_lifecycle_stale_to_resolved_illegal()
	test_lifecycle_self_transition_illegal()
	test_lifecycle_unknown_state_illegal()

	print("\n-- envelope: anchored_to computed accessor --")
	test_anchored_to_round_trips_through_serialize()
	test_deserialize_missing_anchor_leaves_anchored_to_empty()
	test_view_context_immutability_helper()
	test_validate_update_allows_visible_in_views_change()

	print("\n-- envelope: author validation --")
	test_author_kind_human_valid()
	test_author_kind_ai_valid()
	test_author_kind_missing_rejected()
	test_author_kind_invalid_enum_rejected()
	test_author_id_optional()
	test_author_optional_field_type_rejected()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# -- Assertion helpers ---------------------------------------------------------

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


# -- Fixtures ----------------------------------------------------------------

func _schema() -> RefCounted:
	return AnnotationV2SchemaScript.new()


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


func _validated(env: Dictionary) -> RefCounted:
	return _schema().validate(env)


func _without_key(dict: Dictionary, key: String) -> Dictionary:
	var out := dict.duplicate(true)
	out.erase(key)
	return out


func _envelope_without_top_level(key: String) -> Dictionary:
	return _without_key(_valid_envelope(), key)


func _envelope_without_anchor_key(key: String) -> Dictionary:
	var env := _valid_envelope()
	env["anchor"].erase(key)
	return env


func _has_error_for(result: RefCounted, field_path: String) -> bool:
	for e in result.to_error_dicts():
		if e.get("field_path", "") == field_path:
			return true
	return false


# -- Required-field tests ------------------------------------------------------

func test_envelope_validate_minimal_valid() -> void:
	print("test_envelope_validate_minimal_valid:")
	check("valid envelope has no errors", not _validated(_valid_envelope()).has_errors())


func test_envelope_empty_dict_rejected() -> void:
	print("test_envelope_empty_dict_rejected:")
	var result := _validated({})
	check("empty envelope has errors", result.has_errors())
	check("empty envelope reports missing id", _has_error_for(result, "id"))
	check("empty envelope reports missing kind", _has_error_for(result, "kind"))
	check("empty envelope reports missing schema_version", _has_error_for(result, "schema_version"))
	check("empty envelope reports missing anchor", _has_error_for(result, "anchor"))
	check("empty envelope reports missing kind_payload", _has_error_for(result, "kind_payload"))
	check("empty envelope reports missing lifecycle", _has_error_for(result, "lifecycle"))
	check("empty envelope reports missing author", _has_error_for(result, "author"))
	check("empty envelope reports missing view_context", _has_error_for(result, "view_context"))
	check("empty envelope reports missing visible_in_views", _has_error_for(result, "visible_in_views"))
	check("empty envelope reports missing summary", _has_error_for(result, "summary"))


func test_envelope_missing_id_rejected() -> void:
	print("test_envelope_missing_id_rejected:")
	var result := _validated(_envelope_without_top_level("id"))
	check("missing id rejected", result.has_errors())
	check("missing id reports id path", _has_error_for(result, "id"))


func test_envelope_missing_kind_rejected() -> void:
	print("test_envelope_missing_kind_rejected:")
	var result := _validated(_envelope_without_top_level("kind"))
	check("missing kind rejected", result.has_errors())
	check("missing kind reports kind path", _has_error_for(result, "kind"))


func test_envelope_missing_schema_version_rejected() -> void:
	print("test_envelope_missing_schema_version_rejected:")
	var result := _validated(_envelope_without_top_level("schema_version"))
	check("missing schema_version rejected", result.has_errors())
	check("missing schema_version reports schema_version path", _has_error_for(result, "schema_version"))


func test_envelope_schema_version_1_rejected() -> void:
	print("test_envelope_schema_version_1_rejected:")
	var env := _valid_envelope()
	env["schema_version"] = 1
	var result := _validated(env)
	check("schema_version=1 rejected", result.has_errors())
	check("schema_version=1 reports schema_version path", _has_error_for(result, "schema_version"))


func test_envelope_missing_anchor_rejected() -> void:
	print("test_envelope_missing_anchor_rejected:")
	var result := _validated(_envelope_without_top_level("anchor"))
	check("missing anchor rejected", result.has_errors())
	check("missing anchor reports anchor path", _has_error_for(result, "anchor"))


func test_envelope_missing_kind_payload_rejected() -> void:
	print("test_envelope_missing_kind_payload_rejected:")
	var result := _validated(_envelope_without_top_level("kind_payload"))
	check("missing kind_payload rejected", result.has_errors())
	check("missing kind_payload reports kind_payload path", _has_error_for(result, "kind_payload"))


func test_envelope_missing_lifecycle_rejected() -> void:
	print("test_envelope_missing_lifecycle_rejected:")
	var result := _validated(_envelope_without_top_level("lifecycle"))
	check("missing lifecycle rejected", result.has_errors())
	check("missing lifecycle reports lifecycle path", _has_error_for(result, "lifecycle"))


func test_envelope_missing_author_rejected() -> void:
	print("test_envelope_missing_author_rejected:")
	var result := _validated(_envelope_without_top_level("author"))
	check("missing author rejected", result.has_errors())
	check("missing author reports author path", _has_error_for(result, "author"))


func test_envelope_missing_view_context_rejected() -> void:
	print("test_envelope_missing_view_context_rejected:")
	var result := _validated(_envelope_without_top_level("view_context"))
	check("missing view_context rejected", result.has_errors())
	check("missing view_context reports view_context path", _has_error_for(result, "view_context"))


func test_envelope_missing_visible_in_views_rejected() -> void:
	print("test_envelope_missing_visible_in_views_rejected:")
	var result := _validated(_envelope_without_top_level("visible_in_views"))
	check("missing visible_in_views rejected", result.has_errors())
	check("missing visible_in_views reports visible_in_views path", _has_error_for(result, "visible_in_views"))


func test_envelope_missing_summary_rejected() -> void:
	print("test_envelope_missing_summary_rejected:")
	var result := _validated(_envelope_without_top_level("summary"))
	check("missing summary rejected", result.has_errors())
	check("missing summary reports summary path", _has_error_for(result, "summary"))


func test_envelope_empty_summary_rejected() -> void:
	print("test_envelope_empty_summary_rejected:")
	var env := _valid_envelope()
	env["summary"] = ""
	var result := _validated(env)
	check("empty summary rejected", result.has_errors())
	check("empty summary reports summary path", _has_error_for(result, "summary"))


# -- Anchor shape tests --------------------------------------------------------

func test_anchor_missing_plugin_rejected() -> void:
	print("test_anchor_missing_plugin_rejected:")
	var result := _validated(_envelope_without_anchor_key("plugin"))
	check("missing anchor.plugin rejected", result.has_errors())
	check("missing anchor.plugin reports path", _has_error_for(result, "anchor.plugin"))


func test_anchor_missing_type_rejected() -> void:
	print("test_anchor_missing_type_rejected:")
	var result := _validated(_envelope_without_anchor_key("type"))
	check("missing anchor.type rejected", result.has_errors())
	check("missing anchor.type reports path", _has_error_for(result, "anchor.type"))


func test_anchor_missing_id_rejected() -> void:
	print("test_anchor_missing_id_rejected:")
	var result := _validated(_envelope_without_anchor_key("id"))
	check("missing anchor.id rejected", result.has_errors())
	check("missing anchor.id reports path", _has_error_for(result, "anchor.id"))


func test_anchor_missing_snapshot_rejected() -> void:
	print("test_anchor_missing_snapshot_rejected:")
	var result := _validated(_envelope_without_anchor_key("snapshot"))
	check("missing anchor.snapshot rejected", result.has_errors())
	check("missing anchor.snapshot reports path", _has_error_for(result, "anchor.snapshot"))


func test_anchor_snapshot_without_position_rejected() -> void:
	print("test_anchor_snapshot_without_position_rejected:")
	var env := _valid_envelope()
	env["anchor"]["snapshot"].erase("position")
	var result := _validated(env)
	check("missing anchor.snapshot.position rejected", result.has_errors())
	check("missing anchor.snapshot.position reports path", _has_error_for(result, "anchor.snapshot.position"))


func test_anchor_id_variant_int_accepted() -> void:
	print("test_anchor_id_variant_int_accepted:")
	var env := _valid_envelope()
	env["anchor"]["id"] = 7
	check("int anchor.id accepted", not _validated(env).has_errors())


func test_anchor_id_variant_string_accepted() -> void:
	print("test_anchor_id_variant_string_accepted:")
	var env := _valid_envelope()
	env["anchor"]["id"] = "edge-7"
	check("string anchor.id accepted", not _validated(env).has_errors())


func test_anchor_id_variant_array_accepted() -> void:
	print("test_anchor_id_variant_array_accepted:")
	var env := _valid_envelope()
	env["anchor"]["id"] = [7, 8, 9]
	check("array anchor.id accepted", not _validated(env).has_errors())


func test_anchor_stable_key_optional() -> void:
	print("test_anchor_stable_key_optional:")
	var env := _envelope_without_anchor_key("stable_key")
	check("absent stable_key accepted", not _validated(env).has_errors())


# -- Lifecycle state machine tests -------------------------------------------

func test_lifecycle_open_to_applied_legal() -> void:
	print("test_lifecycle_open_to_applied_legal:")
	check("open -> applied legal", AnnotationLifecycleScript.can_transition("open", "applied"))


func test_lifecycle_open_to_resolved_legal() -> void:
	print("test_lifecycle_open_to_resolved_legal:")
	check("open -> resolved legal", AnnotationLifecycleScript.can_transition("open", "resolved"))


func test_lifecycle_open_to_stale_legal() -> void:
	print("test_lifecycle_open_to_stale_legal:")
	check("open -> stale legal", AnnotationLifecycleScript.can_transition("open", "stale"))


func test_lifecycle_applied_to_resolved_legal() -> void:
	print("test_lifecycle_applied_to_resolved_legal:")
	check("applied -> resolved legal", AnnotationLifecycleScript.can_transition("applied", "resolved"))


func test_lifecycle_resolved_to_open_legal() -> void:
	print("test_lifecycle_resolved_to_open_legal:")
	check("resolved -> open legal", AnnotationLifecycleScript.can_transition("resolved", "open"))


func test_lifecycle_stale_to_open_legal() -> void:
	print("test_lifecycle_stale_to_open_legal:")
	check("stale -> open legal", AnnotationLifecycleScript.can_transition("stale", "open"))


func test_lifecycle_applied_to_open_illegal() -> void:
	print("test_lifecycle_applied_to_open_illegal:")
	check("applied -> open illegal", not AnnotationLifecycleScript.can_transition("applied", "open"))


func test_lifecycle_resolved_to_applied_illegal() -> void:
	print("test_lifecycle_resolved_to_applied_illegal:")
	check("resolved -> applied illegal", not AnnotationLifecycleScript.can_transition("resolved", "applied"))


func test_lifecycle_stale_to_resolved_illegal() -> void:
	print("test_lifecycle_stale_to_resolved_illegal:")
	check("stale -> resolved illegal", not AnnotationLifecycleScript.can_transition("stale", "resolved"))


func test_lifecycle_self_transition_illegal() -> void:
	print("test_lifecycle_self_transition_illegal:")
	check("open -> open illegal", not AnnotationLifecycleScript.can_transition("open", "open"))


func test_lifecycle_unknown_state_illegal() -> void:
	print("test_lifecycle_unknown_state_illegal:")
	check("unknown source rejected", not AnnotationLifecycleScript.can_transition("missing", "open"))
	check("unknown target rejected", not AnnotationLifecycleScript.can_transition("open", "missing"))


# -- anchored_to computed accessor tests --------------------------------------

func test_anchored_to_round_trips_through_serialize() -> void:
	print("test_anchored_to_round_trips_through_serialize:")
	var schema := _schema()
	var env := _valid_envelope()
	env["anchored_to"] = "stale.value:that-should-not-persist"
	var serialized: Dictionary = schema.serialize(env)
	check("serialize strips anchored_to", not serialized.has("anchored_to"))
	var round_trip: Dictionary = schema.deserialize(serialized)
	check("deserialize recomputes anchored_to", round_trip.has("anchored_to"))
	check("anchored_to starts with anchor plugin/type", (round_trip["anchored_to"] as String).begins_with("core.text.range:"))


func test_deserialize_missing_anchor_leaves_anchored_to_empty() -> void:
	print("test_deserialize_missing_anchor_leaves_anchored_to_empty:")
	var serialized := _envelope_without_top_level("anchor")
	var round_trip: Dictionary = _schema().deserialize(serialized)
	check("missing anchor does not synthesize anchored_to", not round_trip.has("anchored_to"))


func test_view_context_immutability_helper() -> void:
	print("test_view_context_immutability_helper:")
	var old_env := _valid_envelope()
	var new_env := _valid_envelope()
	new_env["view_context"] = "editor:secondary"
	var errors: Array = _schema().check_view_context_immutable(old_env, new_env)
	check("view_context change reports error", errors.size() > 0)
	check_eq("view_context error path", errors[0].get("field_path", ""), "view_context")


func test_validate_update_allows_visible_in_views_change() -> void:
	print("test_validate_update_allows_visible_in_views_change:")
	var old_env := _valid_envelope()
	var new_env := _valid_envelope()
	new_env["visible_in_views"] = ["main", "secondary"]
	check("visible_in_views may change", _schema().validate_update(old_env, new_env).is_empty())


# -- Author validation tests ---------------------------------------------------

func test_author_kind_human_valid() -> void:
	print("test_author_kind_human_valid:")
	check("author.kind=human accepted", AnnotationAuthorScript.validate({"kind": "human"}).is_empty())


func test_author_kind_ai_valid() -> void:
	print("test_author_kind_ai_valid:")
	check("author.kind=ai accepted", AnnotationAuthorScript.validate({"kind": "ai", "model": "test-model"}).is_empty())


func test_author_kind_missing_rejected() -> void:
	print("test_author_kind_missing_rejected:")
	var errors: Array = AnnotationAuthorScript.validate({})
	check("missing author.kind rejected", errors.size() > 0)
	check_eq("missing author.kind error path", errors[0].get("field_path", ""), "author.kind")


func test_author_kind_invalid_enum_rejected() -> void:
	print("test_author_kind_invalid_enum_rejected:")
	var errors: Array = AnnotationAuthorScript.validate({"kind": "robot"})
	check("author.kind=robot rejected", errors.size() > 0)
	check_eq("author.kind=robot error path", errors[0].get("field_path", ""), "author.kind")


func test_author_id_optional() -> void:
	print("test_author_id_optional:")
	check("author id optional", AnnotationAuthorScript.validate({"kind": "human"}).is_empty())


func test_author_optional_field_type_rejected() -> void:
	print("test_author_optional_field_type_rejected:")
	var errors: Array = AnnotationAuthorScript.validate({"kind": "human", "id": 12})
	check("non-string author.id rejected", errors.size() > 0)
	check_eq("non-string author.id error path", errors[0].get("field_path", ""), "author.id")
