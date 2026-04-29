extends SceneTree
## Contract tests for broken/stale anchor chat-context injection (task #4).
## Run: godot --headless --path src --script test/annotations_v2/test_broken_anchor_chat.gd
##
## RED in Round 1 — AnnotationKind.to_chat_context and ContextBlock do not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_chat ===\n")

	print("-- ContextBlock / to_chat_context: class/method existence --")
	test_context_block_class_exists()
	test_annotation_kind_has_to_chat_context()

	print("\n-- broken annotation in chat context --")
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


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _capabilities_full() -> Dictionary:
	return {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "image", "source_code", "table"]
	}


func _make_annotation(lifecycle: String) -> Dictionary:
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
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _get_context_block_type_value(type_name: String) -> int:
	# Safely retrieve ContextBlock.Type.TEXT etc. at runtime using ClassDB
	if not ClassDB.class_exists("ContextBlock"):
		return -1
	var inst = ClassDB.instantiate("ContextBlock")
	if inst == null:
		return -1
	var type_enum = inst.get("Type")
	if type_enum == null:
		# Try accessing the enum via the class
		return -999
	return -1


func _get_text_block(blocks: Array, kind_inst: Object) -> Variant:
	if not ClassDB.class_exists("ContextBlock"):
		return null
	# Use kind_inst to get the type value at runtime
	for block in blocks:
		var t = block.get("type", -1)
		# Check if it's a text type by checking the numeric value from a ContextBlock instance
		var cb = ClassDB.instantiate("ContextBlock")
		if cb != null and cb.get("Type") != null:
			var text_type = cb.get("Type").TEXT if cb.get("Type") != null else null
			if text_type != null and t == text_type:
				return block
		# Fallback: check string representation
		if typeof(t) == TYPE_INT and t == 0:  # TEXT is usually 0
			return block
	return null


func _get_structured_json_block(blocks: Array) -> Variant:
	if not ClassDB.class_exists("ContextBlock"):
		return null
	for block in blocks:
		var t = block.get("type", -1)
		var cb = ClassDB.instantiate("ContextBlock")
		if cb != null:
			var prop_list = cb.get_property_list()
			for prop in prop_list:
				if prop.get("name", "") == "Type":
					break
		# Fallback: check the block's type field by name
		if block.get("type_name", "") == "STRUCTURED_JSON":
			return block
		if typeof(t) == TYPE_INT and t == 1:  # STRUCTURED_JSON is usually 1
			return block
	return null


# ── Class existence ───────────────────────────────────────────────────────────

func test_context_block_class_exists() -> void:
	print("test_context_block_class_exists:")
	check("ContextBlock class exists", ClassDB.class_exists("ContextBlock"))


func test_annotation_kind_has_to_chat_context() -> void:
	print("test_annotation_kind_has_to_chat_context:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null:
		check("AnnotationKind instantiable", false)
		return
	check("AnnotationKind has to_chat_context method",
		kind.has_method("to_chat_context"))


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_broken_annotation_text_block_has_broken_prefix() -> void:
	print("test_broken_annotation_text_block_has_broken_prefix:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("stale")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	# Find text block: type is ContextBlock.Type.TEXT
	var text_block: Variant = null
	for b in blocks:
		if b.get("type_name", "") == "TEXT" or b.get("type", -1) == 0:
			text_block = b
			break
	check("stale annotation produces text block", text_block != null)
	if text_block != null:
		var content = text_block.get("content", "")
		check("stale annotation text block prefixed with [BROKEN]",
			content.begins_with("[BROKEN]"))


func test_non_broken_annotation_text_block_has_no_prefix() -> void:
	print("test_non_broken_annotation_text_block_has_no_prefix:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("open")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	var text_block: Variant = null
	for b in blocks:
		if b.get("type_name", "") == "TEXT" or b.get("type", -1) == 0:
			text_block = b
			break
	if text_block != null:
		var content = text_block.get("content", "")
		check("open annotation text block has NO [BROKEN] prefix",
			not content.begins_with("[BROKEN]"))
	else:
		check("open annotation has text block when text in supported_block_types", false)


func test_broken_annotation_structured_json_has_stale_true() -> void:
	print("test_broken_annotation_structured_json_has_stale_true:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("stale")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	var json_block: Variant = null
	for b in blocks:
		if b.get("type_name", "") == "STRUCTURED_JSON" or b.get("type", -1) == 1:
			json_block = b
			break
	check("stale annotation has structured_json block", json_block != null)
	if json_block != null:
		var content = json_block.get("content", {})
		check("structured_json block has stale=true", content.get("stale", false) == true)


func test_broken_annotation_structured_json_lifecycle_stale() -> void:
	print("test_broken_annotation_structured_json_lifecycle_stale:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("stale")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	var json_block: Variant = null
	for b in blocks:
		if b.get("type_name", "") == "STRUCTURED_JSON" or b.get("type", -1) == 1:
			json_block = b
			break
	if json_block != null:
		var content = json_block.get("content", {})
		check("structured_json block has lifecycle=stale",
			content.get("lifecycle", "") == "stale")
	else:
		check("structured_json block present for stale annotation", false)


func test_non_broken_structured_json_stale_false() -> void:
	print("test_non_broken_structured_json_stale_false:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("open")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	var json_block: Variant = null
	for b in blocks:
		if b.get("type_name", "") == "STRUCTURED_JSON" or b.get("type", -1) == 1:
			json_block = b
			break
	if json_block != null:
		var content = json_block.get("content", {})
		check("open annotation structured_json has stale=false",
			content.get("stale", true) == false)
	else:
		check("structured_json block always present", false)


func test_broken_annotation_included_in_chat_context_by_default() -> void:
	print("test_broken_annotation_included_in_chat_context_by_default:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("ContextBlock"):
		check("ContextBlock exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null or not kind.has_method("to_chat_context"):
		check("AnnotationKind has to_chat_context method", false)
		return
	var ann = _make_annotation("stale")
	var blocks = kind.to_chat_context(ann, _capabilities_full())
	check("broken annotation produces non-empty context blocks", blocks.size() > 0)
