extends SceneTree

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const ContextBlockScript = preload("res://Scripts/Services/Annotations/ContextBlock.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_chat ===\n")
	test_context_block_shape()
	test_annotation_kind_has_to_chat_context()
	test_broken_annotation_text_block_has_broken_prefix()
	test_non_broken_annotation_text_block_has_no_prefix()
	test_broken_annotation_structured_json_has_stale_true()
	test_broken_annotation_structured_json_lifecycle_stale()
	test_non_broken_structured_json_stale_false()
	test_broken_annotation_included_in_chat_context_by_default()
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


func _capabilities_full() -> Dictionary:
	return {"multimodal": true, "max_tokens": 200000, "supported_block_types": ["text", "structured_json", "image"]}


func _make_annotation(lifecycle: String) -> Dictionary:
	return {
		"id": "ann_test",
		"kind": "text",
		"schema_version": 2,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": 0, "end": 10}, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func _block(blocks: Array, type_name: String) -> Variant:
	for b in blocks:
		if b.get("type_name", "") == type_name:
			return b
	return null


func test_context_block_shape() -> void:
	var block := ContextBlockScript.make(ContextBlockScript.Type.TEXT, "hello")
	check("ContextBlock emits TEXT type_name", block.get("type_name", "") == "TEXT")
	check("ContextBlock emits content", block.get("content", "") == "hello")


func test_annotation_kind_has_to_chat_context() -> void:
	check("AnnotationKind has to_chat_context method", AnnotationKindScript.new().has_method("to_chat_context"))


func test_broken_annotation_text_block_has_broken_prefix() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation("stale"), _capabilities_full())
	var text_block = _block(blocks, "TEXT")
	check("stale annotation produces text block", text_block != null)
	if text_block != null:
		check("stale annotation text block prefixed with [BROKEN]", str(text_block.get("content", "")).begins_with("[BROKEN]"))


func test_non_broken_annotation_text_block_has_no_prefix() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation("open"), _capabilities_full())
	var text_block = _block(blocks, "TEXT")
	check("open annotation has text block", text_block != null)
	if text_block != null:
		check("open annotation text block has no [BROKEN] prefix", not str(text_block.get("content", "")).begins_with("[BROKEN]"))


func test_broken_annotation_structured_json_has_stale_true() -> void:
	var json_block = _block(AnnotationKindScript.new().to_chat_context(_make_annotation("stale"), _capabilities_full()), "STRUCTURED_JSON")
	check("stale annotation has structured_json block", json_block != null)
	if json_block != null:
		check("structured_json block has stale=true", json_block.get("content", {}).get("stale", false) == true)


func test_broken_annotation_structured_json_lifecycle_stale() -> void:
	var json_block = _block(AnnotationKindScript.new().to_chat_context(_make_annotation("stale"), _capabilities_full()), "STRUCTURED_JSON")
	check("structured_json block present for stale annotation", json_block != null)
	if json_block != null:
		check("structured_json block has lifecycle=stale", json_block.get("content", {}).get("lifecycle", "") == "stale")


func test_non_broken_structured_json_stale_false() -> void:
	var json_block = _block(AnnotationKindScript.new().to_chat_context(_make_annotation("open"), _capabilities_full()), "STRUCTURED_JSON")
	check("structured_json block always present", json_block != null)
	if json_block != null:
		check("open annotation structured_json has stale=false", json_block.get("content", {}).get("stale", true) == false)


func test_broken_annotation_included_in_chat_context_by_default() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation("stale"), _capabilities_full())
	check("broken annotation produces non-empty context blocks", blocks.size() > 0)
