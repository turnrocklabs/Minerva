extends SceneTree
## Contract tests for broken/stale annotation chat-context injection (task #7).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_chat_context_stale.gd
##
## RED in Round 1 — AnnotationKind.to_chat_context does not exist yet.
## (Companion to test_broken_anchor_chat.gd which covers broader surfaces.)

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_stale ===\n")

	print("-- stale annotation chat injection --")
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


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _caps() -> Dictionary:
	return {
		"multimodal": false,
		"max_tokens": 32000,
		"supported_block_types": ["text", "structured_json"]
	}


func _make_ann(lifecycle: String) -> Dictionary:
	return {
		"id": "ann_lifecycle_test",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 5, "end": 20},
			"snapshot": {"position": [0.0, 0.0], "text": "was here", "document_revision": 3}
		},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _get_json_block(blocks: Array) -> Variant:
	for b in blocks:
		if b.get("type_name", "") == "STRUCTURED_JSON" or b.get("type", -1) == 1:
			return b
	return null


func _get_text_block(blocks: Array) -> Variant:
	for b in blocks:
		if b.get("type_name", "") == "TEXT" or b.get("type", -1) == 0:
			return b
	return null


func _make_kind() -> Variant:
	if not ClassDB.class_exists("AnnotationKind"):
		return null
	return ClassDB.instantiate("AnnotationKind")


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_stale_annotation_structured_json_stale_true() -> void:
	print("test_stale_annotation_structured_json_stale_true:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("stale"), _caps())
	var json_b = _get_json_block(blocks)
	check("stale ann has structured_json block", json_b != null)
	if json_b != null:
		check("structured_json has stale=true", json_b.get("content", {}).get("stale", false))


func test_stale_annotation_structured_json_lifecycle_stale() -> void:
	print("test_stale_annotation_structured_json_lifecycle_stale:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("stale"), _caps())
	var json_b = _get_json_block(blocks)
	if json_b != null:
		check("structured_json lifecycle=stale",
			json_b.get("content", {}).get("lifecycle", "") == "stale")
	else:
		check("structured_json block present", false)


func test_stale_annotation_text_block_broken_prefix() -> void:
	print("test_stale_annotation_text_block_broken_prefix:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("stale"), _caps())
	var text_b = _get_text_block(blocks)
	check("stale ann text block present", text_b != null)
	if text_b != null:
		check("stale ann text block starts with [BROKEN]",
			text_b.get("content", "").begins_with("[BROKEN]"))


func test_open_annotation_no_broken_prefix() -> void:
	print("test_open_annotation_no_broken_prefix:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("open"), _caps())
	var text_b = _get_text_block(blocks)
	if text_b != null:
		check("open ann text block has no [BROKEN] prefix",
			not text_b.get("content", "").begins_with("[BROKEN]"))
	else:
		check("open ann has text block", false)


func test_applied_annotation_no_broken_prefix() -> void:
	print("test_applied_annotation_no_broken_prefix:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("applied"), _caps())
	var text_b = _get_text_block(blocks)
	if text_b != null:
		check("applied ann text block has no [BROKEN] prefix",
			not text_b.get("content", "").begins_with("[BROKEN]"))
	else:
		check("applied ann has text block", false)


func test_stale_annotation_included_not_filtered() -> void:
	print("test_stale_annotation_included_not_filtered:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_ann("stale"), _caps())
	check("stale annotation produces blocks (included in context, not filtered)",
		blocks.size() > 0)


func test_stale_annotation_summary_preserved_in_structured_json() -> void:
	print("test_stale_annotation_summary_preserved_in_structured_json:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context", false)
		return
	# Even when stale, the summary (from anchor's last successful resolve) should be preserved
	var blocks = kind.to_chat_context(_make_ann("stale"), _caps())
	var json_b = _get_json_block(blocks)
	if json_b != null:
		var content = json_b.get("content", {})
		check("stale ann structured_json preserves summary field",
			content.has("summary") and content.get("summary", "").length() > 0)
	else:
		check("structured_json block present", false)
