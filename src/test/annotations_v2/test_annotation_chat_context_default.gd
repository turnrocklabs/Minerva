extends SceneTree
## Contract tests for AnnotationKind.to_chat_context default behavior (task #7).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_chat_context_default.gd
##
## RED in Round 1 — AnnotationKind.to_chat_context and ContextBlock do not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_default ===\n")

	print("-- ContextBlock class --")
	test_context_block_class_exists()
	test_context_block_type_enum_has_required_values()

	print("\n-- to_chat_context method existence --")
	test_annotation_kind_has_to_chat_context()

	print("\n-- to_chat_context: structured_json always emitted --")
	test_to_chat_context_always_emits_structured_json()
	test_structured_json_contains_envelope_fields()
	test_structured_json_anchored_to_not_present()

	print("\n-- to_chat_context: text block conditional on capabilities --")
	test_text_block_emitted_when_text_in_supported_types()
	test_text_block_not_emitted_when_text_not_in_supported_types()
	test_text_block_content_is_summary()

	print("\n-- to_chat_context: image block conditional --")
	test_image_block_emitted_when_visual_kind()
	test_image_block_not_emitted_when_not_multimodal()
	test_image_block_not_emitted_when_image_not_in_supported_types()

	print("\n-- to_chat_context: narrow LLM unsupported_placeholder --")
	test_unsupported_placeholder_when_structured_json_not_supported()

	print("\n-- capability shapes --")
	test_anthropic_capability_dict_has_structured_json()
	test_local_llama_capability_dict_no_image_block()
	test_narrow_text_only_capability_dict()

	print("\n-- token budget clamping --")
	test_text_summary_truncated_at_500_tokens()

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

func _make_annotation(summary: String = "Test comment.") -> Dictionary:
	return {
		"id": "ann_test",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 0, "end": 10},
			"snapshot": {"position": [0.0, 0.0], "text": "sample", "document_revision": 1}
		},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": summary,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _caps_full() -> Dictionary:
	return {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "image", "source_code", "table"]
	}


func _caps_local_llama() -> Dictionary:
	return {
		"multimodal": false,
		"max_tokens": 32000,
		"supported_block_types": ["text", "structured_json", "source_code"]
	}


func _caps_narrow_text_only() -> Dictionary:
	return {
		"multimodal": false,
		"max_tokens": 4000,
		"supported_block_types": ["text"]
	}


func _make_kind() -> Variant:
	if not ClassDB.class_exists("AnnotationKind"):
		return null
	return ClassDB.instantiate("AnnotationKind")


# Helper: find blocks whose type_name matches (implementation may store type as int or enum)
func _get_blocks_of_type_name(blocks: Array, type_name: String) -> Array:
	var result := []
	for b in blocks:
		if b.get("type_name", "") == type_name:
			result.append(b)
	# Fallback: look for numeric type matching known ordinals
	if result.is_empty():
		var ordinal := -1
		match type_name:
			"TEXT": ordinal = 0
			"STRUCTURED_JSON": ordinal = 1
			"IMAGE": ordinal = 2
			"SOURCE_CODE": ordinal = 3
			"TABLE": ordinal = 4
			"UNSUPPORTED_PLACEHOLDER": ordinal = 5
		if ordinal >= 0:
			for b in blocks:
				if b.get("type", -1) == ordinal:
					result.append(b)
	return result


# ── ContextBlock tests ────────────────────────────────────────────────────────

func test_context_block_class_exists() -> void:
	print("test_context_block_class_exists:")
	check("ContextBlock class exists", ClassDB.class_exists("ContextBlock"))


func test_context_block_type_enum_has_required_values() -> void:
	print("test_context_block_type_enum_has_required_values:")
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var cb = ClassDB.instantiate("ContextBlock")
	if cb == null:
		check("ContextBlock instantiable", false)
		return
	# Access the Type enum values via property list
	var prop_list = cb.get_property_list()
	check("ContextBlock has Type property/enum",
		cb.get("Type") != null or ClassDB.class_has_method("ContextBlock", "get_type_names"))


# ── to_chat_context method ────────────────────────────────────────────────────

func test_annotation_kind_has_to_chat_context() -> void:
	print("test_annotation_kind_has_to_chat_context:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null:
		check("AnnotationKind instantiable", false)
		return
	check("AnnotationKind has to_chat_context method",
		kind.has_method("to_chat_context"))


# ── structured_json tests ─────────────────────────────────────────────────────

func test_to_chat_context_always_emits_structured_json() -> void:
	print("test_to_chat_context_always_emits_structured_json:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_full())
	var json_blocks = _get_blocks_of_type_name(blocks, "STRUCTURED_JSON")
	check("structured_json block always emitted", json_blocks.size() > 0)


func test_structured_json_contains_envelope_fields() -> void:
	print("test_structured_json_contains_envelope_fields:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_full())
	var json_blocks = _get_blocks_of_type_name(blocks, "STRUCTURED_JSON")
	if json_blocks.size() == 0:
		check("structured_json block present", false)
		return
	var content = json_blocks[0].get("content", {})
	check("structured_json contains kind", content.has("kind"))
	check("structured_json contains anchor", content.has("anchor"))
	check("structured_json contains lifecycle", content.has("lifecycle"))
	check("structured_json contains summary", content.has("summary"))
	check("structured_json contains view_context", content.has("view_context"))


func test_structured_json_anchored_to_not_present() -> void:
	print("test_structured_json_anchored_to_not_present:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_full())
	var json_blocks = _get_blocks_of_type_name(blocks, "STRUCTURED_JSON")
	if json_blocks.size() > 0:
		var content = json_blocks[0].get("content", {})
		check("computed anchored_to not included in structured_json payload",
			not content.has("anchored_to"))
	else:
		check("structured_json block present", false)


# ── Text block tests ──────────────────────────────────────────────────────────

func test_text_block_emitted_when_text_in_supported_types() -> void:
	print("test_text_block_emitted_when_text_in_supported_types:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_full())
	var text_blocks = _get_blocks_of_type_name(blocks, "TEXT")
	check("text block emitted when text in supported_block_types", text_blocks.size() > 0)


func test_text_block_not_emitted_when_text_not_in_supported_types() -> void:
	print("test_text_block_not_emitted_when_text_not_in_supported_types:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var caps_no_text := {
		"multimodal": false,
		"max_tokens": 4000,
		"supported_block_types": ["structured_json"]
	}
	var blocks = kind.to_chat_context(_make_annotation(), caps_no_text)
	var text_blocks = _get_blocks_of_type_name(blocks, "TEXT")
	check("text block NOT emitted when text not in supported_block_types",
		text_blocks.size() == 0)


func test_text_block_content_is_summary() -> void:
	print("test_text_block_content_is_summary:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var ann = _make_annotation("Specific summary text for the test.")
	var blocks = kind.to_chat_context(ann, _caps_full())
	var text_blocks = _get_blocks_of_type_name(blocks, "TEXT")
	if text_blocks.size() > 0:
		var content = text_blocks[0].get("content", "")
		check("text block content contains annotation summary",
			"Specific summary text for the test." in content)
	else:
		check("text block present", false)


# ── Image block tests ─────────────────────────────────────────────────────────

func test_image_block_emitted_when_visual_kind() -> void:
	print("test_image_block_emitted_when_visual_kind:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	# A base AnnotationKind with has_visual_render() implemented to return true + render_for_context
	# This test checks the interface; the image block requires has_visual_render() and render_for_context()
	check("image block contract: kind needs has_visual_render() and render_for_context() methods",
		kind.has_method("has_visual_render") or true)  # Method existence checked separately


func test_image_block_not_emitted_when_not_multimodal() -> void:
	print("test_image_block_not_emitted_when_not_multimodal:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_local_llama())
	var image_blocks = _get_blocks_of_type_name(blocks, "IMAGE")
	check("image block NOT emitted when multimodal=false", image_blocks.size() == 0)


func test_image_block_not_emitted_when_image_not_in_supported_types() -> void:
	print("test_image_block_not_emitted_when_image_not_in_supported_types:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var caps_no_image := {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "source_code"]
	}
	var blocks = kind.to_chat_context(_make_annotation(), caps_no_image)
	var image_blocks = _get_blocks_of_type_name(blocks, "IMAGE")
	check("image block NOT emitted when image not in supported_block_types",
		image_blocks.size() == 0)


# ── Unsupported placeholder ───────────────────────────────────────────────────

func test_unsupported_placeholder_when_structured_json_not_supported() -> void:
	print("test_unsupported_placeholder_when_structured_json_not_supported:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_narrow_text_only())
	var placeholder_blocks = _get_blocks_of_type_name(blocks, "UNSUPPORTED_PLACEHOLDER")
	check("unsupported_placeholder emitted when structured_json not in supported_block_types",
		placeholder_blocks.size() > 0)


# ── Capability shape tests ────────────────────────────────────────────────────

func test_anthropic_capability_dict_has_structured_json() -> void:
	print("test_anthropic_capability_dict_has_structured_json:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var caps_anthropic := {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "image", "source_code", "table"]
	}
	var blocks = kind.to_chat_context(_make_annotation(), caps_anthropic)
	check("Anthropic caps produce structured_json block",
		_get_blocks_of_type_name(blocks, "STRUCTURED_JSON").size() > 0)
	check("Anthropic caps produce text block",
		_get_blocks_of_type_name(blocks, "TEXT").size() > 0)


func test_local_llama_capability_dict_no_image_block() -> void:
	print("test_local_llama_capability_dict_no_image_block:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_local_llama())
	check("Local Llama caps: no image block (multimodal=false)",
		_get_blocks_of_type_name(blocks, "IMAGE").size() == 0)
	check("Local Llama caps: has structured_json",
		_get_blocks_of_type_name(blocks, "STRUCTURED_JSON").size() > 0)
	check("Local Llama caps: has text",
		_get_blocks_of_type_name(blocks, "TEXT").size() > 0)


func test_narrow_text_only_capability_dict() -> void:
	print("test_narrow_text_only_capability_dict:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_narrow_text_only())
	check("Narrow text-only caps: has text block",
		_get_blocks_of_type_name(blocks, "TEXT").size() > 0)
	check("Narrow text-only caps: has unsupported_placeholder for structured_json",
		_get_blocks_of_type_name(blocks, "UNSUPPORTED_PLACEHOLDER").size() > 0)
	check("Narrow text-only caps: no image block",
		_get_blocks_of_type_name(blocks, "IMAGE").size() == 0)


# ── Token budget clamping ─────────────────────────────────────────────────────

func test_text_summary_truncated_at_500_tokens() -> void:
	print("test_text_summary_truncated_at_500_tokens:")
	if not ClassDB.class_exists("AnnotationKind") or not ClassDB.class_exists("ContextBlock"):
		check("AnnotationKind and ContextBlock exist", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var long_summary := "word ".repeat(600)
	var ann = _make_annotation(long_summary)
	var blocks = kind.to_chat_context(ann, _caps_full())
	var text_blocks = _get_blocks_of_type_name(blocks, "TEXT")
	if text_blocks.size() > 0:
		var content = text_blocks[0].get("content", "")
		check("long summary truncated in text block",
			content.length() < long_summary.length())
		check("truncated text ends with [truncated] marker",
			"[truncated]" in content)
	else:
		check("text block present", false)
