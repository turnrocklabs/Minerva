extends SceneTree

const ContextBlockScript = preload("res://Scripts/Services/Annotations/ContextBlock.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_chat_context_custom ===\n")
	test_custom_kind_adds_table_block_when_supported()
	test_custom_kind_skips_table_when_not_in_supported_types()
	test_custom_kind_still_emits_structured_json()
	test_custom_kind_still_emits_text_block()
	test_has_visual_render_default_true()
	test_has_visual_render_can_return_false()
	test_no_image_block_when_has_visual_render_false()
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


func _make_annotation() -> Dictionary:
	return {
		"id": "ann_test",
		"kind": "pcb_bus_hint",
		"schema_version": 2,
		"anchor": {"plugin": "pcb", "type": "bus", "id": "bus_power", "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"nets": ["VCC", "GND", "3V3"], "from": "U1", "to": "J2", "preferred_layer": "F.Cu", "spacing_mm": 0.2},
		"lifecycle": "open",
		"author": {"kind": "ai", "model": "claude-sonnet-4-6"},
		"view_context": "pcb:front",
		"visible_in_views": ["front"],
		"summary": "Route 3 nets from U1 to J2 on F.Cu with 0.2mm spacing.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func _caps_with_table() -> Dictionary:
	return {"multimodal": true, "max_tokens": 200000, "supported_block_types": ["text", "structured_json", "image", "table"]}


func _caps_no_table() -> Dictionary:
	return {"multimodal": false, "max_tokens": 32000, "supported_block_types": ["text", "structured_json"]}


func _blocks(blocks: Array, type_name: String) -> Array:
	return blocks.filter(func(block): return block.get("type_name", "") == type_name)


func test_custom_kind_adds_table_block_when_supported() -> void:
	var blocks := _PcbBusHintKind.new().to_chat_context(_make_annotation(), _caps_with_table())
	var table_blocks := _blocks(blocks, "TABLE")
	check("PCB bus hint adds table block when supported", table_blocks.size() > 0)
	if not table_blocks.is_empty():
		check("table block has rows", table_blocks[0].get("content", []).size() > 1)


func test_custom_kind_skips_table_when_not_in_supported_types() -> void:
	var blocks := _PcbBusHintKind.new().to_chat_context(_make_annotation(), _caps_no_table())
	check("PCB bus hint skips table when unsupported", _blocks(blocks, "TABLE").is_empty())


func test_custom_kind_still_emits_structured_json() -> void:
	var blocks := _PcbBusHintKind.new().to_chat_context(_make_annotation(), _caps_with_table())
	check("custom kind still emits structured_json", _blocks(blocks, "STRUCTURED_JSON").size() > 0)


func test_custom_kind_still_emits_text_block() -> void:
	var blocks := _PcbBusHintKind.new().to_chat_context(_make_annotation(), _caps_with_table())
	check("custom kind still emits text block", _blocks(blocks, "TEXT").size() > 0)


func test_has_visual_render_default_true() -> void:
	check("default has_visual_render returns true", AnnotationKind.new().has_visual_render())


func test_has_visual_render_can_return_false() -> void:
	check("overridden has_visual_render can return false", not _NonVisualKind.new().has_visual_render())


func test_no_image_block_when_has_visual_render_false() -> void:
	var caps := {"multimodal": true, "max_tokens": 200000, "supported_block_types": ["text", "structured_json", "image"]}
	var blocks := _NonVisualKind.new().to_chat_context(_make_annotation(), caps)
	check("no image block when has_visual_render=false", _blocks(blocks, "IMAGE").is_empty())


class _PcbBusHintKind extends AnnotationKind:
	func _init() -> void:
		name = &"pcb_bus_hint"
		display_name = "PCB Bus Hint"
		owning_plugin = &"pcb"

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		pass

	func has_visual_render() -> bool:
		return false

	func accepted_anchor_types() -> Array:
		return ["pcb/bus"]

	func to_chat_context(annotation: Dictionary, capabilities: Dictionary) -> Array:
		var blocks := super.to_chat_context(annotation, capabilities)
		if "table" in capabilities.get("supported_block_types", []):
			var rows := [["Net", "Layer"]]
			for net in annotation.get("kind_payload", {}).get("nets", []):
				rows.append([net, annotation.get("kind_payload", {}).get("preferred_layer", "?")])
			blocks.append(ContextBlockScript.make(ContextBlockScript.Type.TABLE, rows))
		return blocks


class _NonVisualKind extends AnnotationKind:
	func _init() -> void:
		name = &"non_visual_kind"
		display_name = "Non Visual"
		owning_plugin = &"test"

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		pass

	func has_visual_render() -> bool:
		return false

	func accepted_anchor_types() -> Array:
		return ["pcb/bus"]
