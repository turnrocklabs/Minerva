extends SceneTree
## Contract tests for custom AnnotationKind.to_chat_context override (task #7).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_chat_context_custom.gd
##
## RED in Round 1 — AnnotationKind.to_chat_context does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_custom ===\n")

	print("-- custom kind extends default to_chat_context --")
	test_custom_kind_adds_table_block_when_supported()
	test_custom_kind_skips_table_when_not_in_supported_types()
	test_custom_kind_still_emits_structured_json()
	test_custom_kind_still_emits_text_block()

	print("\n-- custom kind: has_visual_render virtual --")
	test_has_visual_render_default_true()
	test_has_visual_render_can_return_false()
	test_no_image_block_when_has_visual_render_false()

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

func _make_annotation() -> Dictionary:
	return {
		"id": "ann_test",
		"kind": "pcb_bus_hint",
		"schema_version": 2,
		"anchor": {
			"plugin": "pcb",
			"type": "bus",
			"id": "bus_power",
			"snapshot": {"position": [0.0, 0.0]}
		},
		"kind_payload": {
			"nets": ["VCC", "GND", "3V3"],
			"from": "U1",
			"to": "J2",
			"preferred_layer": "F.Cu",
			"spacing_mm": 0.2
		},
		"lifecycle": "open",
		"author": {"kind": "ai", "model": "claude-sonnet-4-6"},
		"view_context": "pcb:front",
		"visible_in_views": ["front"],
		"summary": "Route 3 nets from U1 to J2 on F.Cu with 0.2mm spacing.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _caps_with_table() -> Dictionary:
	return {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "image", "table"]
	}


func _caps_no_table() -> Dictionary:
	return {
		"multimodal": false,
		"max_tokens": 32000,
		"supported_block_types": ["text", "structured_json"]
	}


func _get_blocks_of_type_name(blocks: Array, type_name: String) -> Array:
	var result := []
	for b in blocks:
		if b.get("type_name", "") == type_name:
			result.append(b)
	# Fallback: numeric ordinals
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


func _make_kind() -> Variant:
	if not ClassDB.class_exists("AnnotationKind"):
		return null
	return ClassDB.instantiate("AnnotationKind")


# ── Tests: custom kind with table block ───────────────────────────────────────

func test_custom_kind_adds_table_block_when_supported() -> void:
	print("test_custom_kind_adds_table_block_when_supported:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _PcbBusHintKind.new()
	if not kind.has_method("to_chat_context"):
		check("kind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_with_table())
	var table_blocks = _get_blocks_of_type_name(blocks, "TABLE")
	check("PCB bus hint kind adds table block when table in supported_block_types",
		table_blocks.size() > 0)
	if table_blocks.size() > 0:
		var content = table_blocks[0].get("content", [])
		check("table block has rows (nets listed)", content is Array and content.size() > 0)


func test_custom_kind_skips_table_when_not_in_supported_types() -> void:
	print("test_custom_kind_skips_table_when_not_in_supported_types:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _PcbBusHintKind.new()
	if not kind.has_method("to_chat_context"):
		check("kind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_no_table())
	var table_blocks = _get_blocks_of_type_name(blocks, "TABLE")
	check("PCB bus hint kind skips table when table not in supported_block_types",
		table_blocks.size() == 0)


func test_custom_kind_still_emits_structured_json() -> void:
	print("test_custom_kind_still_emits_structured_json:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _PcbBusHintKind.new()
	if not kind.has_method("to_chat_context"):
		check("kind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_with_table())
	var json_blocks = _get_blocks_of_type_name(blocks, "STRUCTURED_JSON")
	check("custom kind still emits structured_json (action contract always present)",
		json_blocks.size() > 0)


func test_custom_kind_still_emits_text_block() -> void:
	print("test_custom_kind_still_emits_text_block:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _PcbBusHintKind.new()
	if not kind.has_method("to_chat_context"):
		check("kind has to_chat_context", false)
		return
	var blocks = kind.to_chat_context(_make_annotation(), _caps_with_table())
	var text_blocks = _get_blocks_of_type_name(blocks, "TEXT")
	check("custom kind still emits text block (when text in supported_block_types)",
		text_blocks.size() > 0)


# ── Tests: has_visual_render virtual ─────────────────────────────────────────

func test_has_visual_render_default_true() -> void:
	print("test_has_visual_render_default_true:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _make_kind()
	if kind == null:
		check("AnnotationKind instantiable", false)
		return
	check("AnnotationKind has has_visual_render method",
		kind.has_method("has_visual_render"))
	if kind.has_method("has_visual_render"):
		check("default has_visual_render returns true",
			kind.has_visual_render() == true)


func test_has_visual_render_can_return_false() -> void:
	print("test_has_visual_render_can_return_false:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _NonVisualKind.new()
	if not kind.has_method("has_visual_render"):
		check("has_visual_render method exists", false)
		return
	check("overridden has_visual_render can return false",
		kind.has_visual_render() == false)


func test_no_image_block_when_has_visual_render_false() -> void:
	print("test_no_image_block_when_has_visual_render_false:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = _NonVisualKind.new()
	if not kind.has_method("to_chat_context"):
		check("kind has to_chat_context", false)
		return
	var caps := {
		"multimodal": true,
		"max_tokens": 200000,
		"supported_block_types": ["text", "structured_json", "image"]
	}
	var blocks = kind.to_chat_context(_make_annotation(), caps)
	var image_blocks = _get_blocks_of_type_name(blocks, "IMAGE")
	check("no image block when has_visual_render=false even with multimodal caps",
		image_blocks.size() == 0)


# ── Mock kinds ────────────────────────────────────────────────────────────────

class _PcbBusHintKind extends AnnotationKind:
	func _init() -> void:
		name = &"pcb_bus_hint"
		display_name = "PCB Bus Hint"
		owning_plugin = &"pcb"

	func render(_ctx, _ann: Dictionary) -> void: pass
	func has_visual_render() -> bool: return false
	func accepted_anchor_types() -> Array: return ["pcb/bus"]

	func to_chat_context(annotation: Dictionary, capabilities: Dictionary) -> Array:
		# Call super if the method exists on the base; otherwise start fresh
		var blocks: Array = []
		if has_method("to_chat_context"):
			# We are the override — build base manually since super may not exist in v1
			pass
		# Add table block when table is in supported_block_types
		if "table" in capabilities.get("supported_block_types", []):
			var tb := {}
			tb["type"] = 4  # TABLE ordinal
			tb["type_name"] = "TABLE"
			var nets = annotation.get("kind_payload", {}).get("nets", [])
			var rows := [["Net", "Layer"]]
			for net in nets:
				rows.append([net, annotation.get("kind_payload", {}).get("preferred_layer", "?")])
			tb["content"] = rows
			tb["meta"] = {}
			blocks.append(tb)
		return blocks


class _NonVisualKind extends AnnotationKind:
	func _init() -> void:
		name = &"non_visual_kind"
		display_name = "Non Visual"
		owning_plugin = &"test"

	func render(_ctx, _ann: Dictionary) -> void: pass
	func has_visual_render() -> bool: return false
	func accepted_anchor_types() -> Array: return ["pcb/bus"]
