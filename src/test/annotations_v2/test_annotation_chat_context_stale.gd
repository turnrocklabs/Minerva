extends SceneTree

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_stale ===\n")
	test_stale_annotation_structured_json_stale_true()
	test_stale_annotation_structured_json_lifecycle_stale()
	test_stale_annotation_text_block_broken_prefix()
	test_open_annotation_no_broken_prefix()
	test_applied_annotation_no_broken_prefix()
	test_stale_annotation_included_not_filtered()
	test_stale_annotation_summary_preserved_in_structured_json()
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


func _caps() -> Dictionary:
	return {"multimodal": false, "max_tokens": 32000, "supported_block_types": ["text", "structured_json"]}


func _make_ann(lifecycle: String) -> Dictionary:
	return {
		"id": "ann_lifecycle_test",
		"kind": "text",
		"schema_version": 2,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": 5, "end": 20}, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func _block(blocks: Array, type_name: String) -> Dictionary:
	for b in blocks:
		if b.get("type_name", "") == type_name:
			return b
	return {}


func test_stale_annotation_structured_json_stale_true() -> void:
	var json := _block(AnnotationKindScript.new().to_chat_context(_make_ann("stale"), _caps()), "STRUCTURED_JSON")
	check("stale ann has structured_json block", not json.is_empty())
	check("structured_json has stale=true", json.get("content", {}).get("stale", false))


func test_stale_annotation_structured_json_lifecycle_stale() -> void:
	var json := _block(AnnotationKindScript.new().to_chat_context(_make_ann("stale"), _caps()), "STRUCTURED_JSON")
	check("structured_json lifecycle=stale", json.get("content", {}).get("lifecycle", "") == "stale")


func test_stale_annotation_text_block_broken_prefix() -> void:
	var text := _block(AnnotationKindScript.new().to_chat_context(_make_ann("stale"), _caps()), "TEXT")
	check("stale ann text block present", not text.is_empty())
	check("stale ann text block starts with [BROKEN]", str(text.get("content", "")).begins_with("[BROKEN]"))


func test_open_annotation_no_broken_prefix() -> void:
	var text := _block(AnnotationKindScript.new().to_chat_context(_make_ann("open"), _caps()), "TEXT")
	check("open ann text block has no [BROKEN] prefix", not str(text.get("content", "")).begins_with("[BROKEN]"))


func test_applied_annotation_no_broken_prefix() -> void:
	var text := _block(AnnotationKindScript.new().to_chat_context(_make_ann("applied"), _caps()), "TEXT")
	check("applied ann text block has no [BROKEN] prefix", not str(text.get("content", "")).begins_with("[BROKEN]"))


func test_stale_annotation_included_not_filtered() -> void:
	check("stale annotation produces blocks", AnnotationKindScript.new().to_chat_context(_make_ann("stale"), _caps()).size() > 0)


func test_stale_annotation_summary_preserved_in_structured_json() -> void:
	var json := _block(AnnotationKindScript.new().to_chat_context(_make_ann("stale"), _caps()), "STRUCTURED_JSON")
	check("stale ann structured_json preserves summary", str(json.get("content", {}).get("summary", "")).length() > 0)
