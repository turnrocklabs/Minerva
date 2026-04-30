extends SceneTree

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const ContextBlockScript = preload("res://Scripts/Services/Annotations/ContextBlock.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_default ===\n")
	test_context_block_shape()
	test_annotation_kind_has_to_chat_context()
	test_to_chat_context_always_emits_structured_json()
	test_structured_json_contains_envelope_fields()
	test_structured_json_anchored_to_not_present()
	test_text_block_emitted_when_text_in_supported_types()
	test_text_block_not_emitted_when_text_not_in_supported_types()
	test_text_block_content_is_summary()
	test_image_block_not_emitted_when_not_multimodal()
	test_image_block_not_emitted_when_image_not_in_supported_types()
	test_unsupported_placeholder_when_structured_json_not_supported()
	test_anthropic_capability_dict_has_structured_json()
	test_local_llama_capability_dict_no_image_block()
	test_narrow_text_only_capability_dict()
	test_text_summary_truncated_at_500_tokens()
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


func _make_annotation(summary: String = "Test comment.") -> Dictionary:
	return {
		"id": "ann_test",
		"kind": "text",
		"schema_version": 2,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": 0, "end": 10}, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": summary,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func _caps_full() -> Dictionary:
	return {"multimodal": true, "max_tokens": 200000, "supported_block_types": ["text", "structured_json", "image", "source_code", "table"]}


func _caps_local_llama() -> Dictionary:
	return {"multimodal": false, "max_tokens": 32000, "supported_block_types": ["text", "structured_json", "source_code"]}


func _caps_narrow_text_only() -> Dictionary:
	return {"multimodal": false, "max_tokens": 4000, "supported_block_types": ["text"]}


func _blocks(blocks: Array, type_name: String) -> Array:
	return blocks.filter(func(block): return block.get("type_name", "") == type_name)


func test_context_block_shape() -> void:
	var block := ContextBlockScript.make(ContextBlockScript.Type.STRUCTURED_JSON, {"a": 1}, {"mime": "application/json"})
	check("ContextBlock emits STRUCTURED_JSON type_name", block.get("type_name", "") == "STRUCTURED_JSON")
	check("ContextBlock carries content", block.get("content", {}).get("a", 0) == 1)
	check("ContextBlock carries meta", block.get("meta", {}).get("mime", "") == "application/json")


func test_annotation_kind_has_to_chat_context() -> void:
	var kind := AnnotationKindScript.new()
	check("AnnotationKind has to_chat_context method", kind.has_method("to_chat_context"))
	check("AnnotationKind has has_visual_render method", kind.has_method("has_visual_render"))
	check("default has_visual_render returns true", kind.has_visual_render())


func test_to_chat_context_always_emits_structured_json() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_full())
	check("structured_json block always emitted", _blocks(blocks, "STRUCTURED_JSON").size() > 0)


func test_structured_json_contains_envelope_fields() -> void:
	var json_blocks := _blocks(AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_full()), "STRUCTURED_JSON")
	check("structured_json block present", json_blocks.size() > 0)
	if not json_blocks.is_empty():
		var content: Dictionary = json_blocks[0].get("content", {})
		check("structured_json contains kind", content.has("kind"))
		check("structured_json contains anchor", content.has("anchor"))
		check("structured_json contains lifecycle", content.has("lifecycle"))
		check("structured_json contains summary", content.has("summary"))
		check("structured_json contains view_context", content.has("view_context"))


func test_structured_json_anchored_to_not_present() -> void:
	var ann := _make_annotation()
	ann["anchored_to"] = "computed.value"
	var json_blocks := _blocks(AnnotationKindScript.new().to_chat_context(ann, _caps_full()), "STRUCTURED_JSON")
	check("computed anchored_to not included in structured_json payload", not json_blocks[0].get("content", {}).has("anchored_to"))


func test_text_block_emitted_when_text_in_supported_types() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_full())
	check("text block emitted when text supported", _blocks(blocks, "TEXT").size() > 0)


func test_text_block_not_emitted_when_text_not_in_supported_types() -> void:
	var caps := {"multimodal": false, "max_tokens": 4000, "supported_block_types": ["structured_json"]}
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), caps)
	check("text block not emitted when text unsupported", _blocks(blocks, "TEXT").is_empty())


func test_text_block_content_is_summary() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation("Specific summary text."), _caps_full())
	check("text block content contains summary", "Specific summary text." in str(_blocks(blocks, "TEXT")[0].get("content", "")))


func test_image_block_not_emitted_when_not_multimodal() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_local_llama())
	check("image block not emitted when multimodal=false", _blocks(blocks, "IMAGE").is_empty())


func test_image_block_not_emitted_when_image_not_in_supported_types() -> void:
	var caps := {"multimodal": true, "max_tokens": 200000, "supported_block_types": ["text", "structured_json"]}
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), caps)
	check("image block not emitted when image unsupported", _blocks(blocks, "IMAGE").is_empty())


func test_unsupported_placeholder_when_structured_json_not_supported() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_narrow_text_only())
	check("unsupported_placeholder emitted when structured_json unsupported", _blocks(blocks, "UNSUPPORTED_PLACEHOLDER").size() > 0)


func test_anthropic_capability_dict_has_structured_json() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_full())
	check("Anthropic caps produce structured_json block", _blocks(blocks, "STRUCTURED_JSON").size() > 0)
	check("Anthropic caps produce text block", _blocks(blocks, "TEXT").size() > 0)


func test_local_llama_capability_dict_no_image_block() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_local_llama())
	check("Local Llama caps no image block", _blocks(blocks, "IMAGE").is_empty())
	check("Local Llama caps has structured_json", _blocks(blocks, "STRUCTURED_JSON").size() > 0)
	check("Local Llama caps has text", _blocks(blocks, "TEXT").size() > 0)


func test_narrow_text_only_capability_dict() -> void:
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(), _caps_narrow_text_only())
	check("Narrow text-only caps has text block", _blocks(blocks, "TEXT").size() > 0)
	check("Narrow text-only caps has unsupported_placeholder", _blocks(blocks, "UNSUPPORTED_PLACEHOLDER").size() > 0)
	check("Narrow text-only caps no image block", _blocks(blocks, "IMAGE").is_empty())


func test_text_summary_truncated_at_500_tokens() -> void:
	var long_summary := "word ".repeat(600)
	var blocks := AnnotationKindScript.new().to_chat_context(_make_annotation(long_summary), _caps_full())
	var content := str(_blocks(blocks, "TEXT")[0].get("content", ""))
	check("long summary truncated in text block", content.length() < long_summary.length())
	check("truncated text ends with marker", "[truncated]" in content)
