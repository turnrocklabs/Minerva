extends Control
## Overlay that paints anchor indicators on top of a Type.TEXT Editor.
##
## - Healthy anchors get a subtle blue underline along the actual character
##   range so the user can see WHICH text is annotated.
## - Stale anchors get an orange gutter strip + line tint so the broken state
##   reads at a glance.

const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 0.85)
const _BROKEN_FILL := Color(1.0, 0.55, 0.05, 0.18)
const _HEALTHY_COLOR := Color(0.40, 0.70, 1.0, 0.85)
const _STRIP_WIDTH := 4.0
const _UNDERLINE_THICKNESS := 1.5


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 50


func _draw() -> void:
	var editor := get_parent()
	if editor == null:
		return
	var host = editor.get("annotation_host") if "annotation_host" in editor else null
	if host == null:
		return
	var code = editor.get("code_edit") if "code_edit" in editor else null
	if code == null:
		return

	var anns: Array = []
	if host.has_method("get_annotations"):
		anns = host.get_annotations()
	if anns.is_empty():
		return

	var line_height: float = 16.0
	if code.has_method("get_line_height"):
		line_height = float(code.get_line_height())
	var ce_local: Vector2 = Vector2.ZERO
	if "global_position" in code:
		ce_local = code.global_position - global_position
	var ce_size: Vector2 = code.size if "size" in code else Vector2.ZERO

	for ann in anns:
		if not ann is Dictionary:
			continue
		var anchor: Dictionary = (ann as Dictionary).get("anchor", {})
		if anchor.is_empty():
			continue
		var resolved: Dictionary = host.resolve_anchor(anchor)
		if bool(resolved.get("stale", false)):
			_draw_broken(resolved, ce_local, ce_size, line_height)
		else:
			_draw_healthy(anchor, code, ce_local, line_height)


func _draw_broken(resolved: Dictionary, ce_local: Vector2, ce_size: Vector2, line_height: float) -> void:
	var pos: Vector2 = resolved.get("position", Vector2.ZERO)
	var line_idx: int = int(pos.x)
	var y: float = ce_local.y + line_idx * line_height
	if y < ce_local.y or y > ce_local.y + ce_size.y:
		return
	var strip := Rect2(ce_local.x, y, _STRIP_WIDTH, line_height)
	draw_rect(strip, _BROKEN_COLOR, true)
	var fill := Rect2(ce_local.x + _STRIP_WIDTH, y, ce_size.x - _STRIP_WIDTH, line_height)
	draw_rect(fill, _BROKEN_FILL, true)


func _draw_healthy(anchor: Dictionary, code: Object, ce_local: Vector2, line_height: float) -> void:
	# Underline the actual character range so the user can see what's annotated.
	# Multi-line ranges get one underline segment per line (full-width middle
	# lines, partial first/last lines). Lines that aren't in the visible area
	# return get_pos_at_line_column == -1 and we skip them silently.
	var id: Variant = anchor.get("id", null)
	if not id is Dictionary:
		return
	var id_dict: Dictionary = id as Dictionary
	var start_v: Variant = id_dict.get("start", -1)
	var end_v: Variant = id_dict.get("end", -1)
	if not start_v is int or not end_v is int:
		return
	var start: int = start_v as int
	var end: int = end_v as int
	if start < 0 or end <= start:
		return
	if not code.has_method("get_pos_at_line_column"):
		return

	var doc: String = str(code.text) if "text" in code else ""
	var start_lc := _flat_offset_to_line_col(doc, start)
	var end_lc := _flat_offset_to_line_col(doc, end)
	var start_line := start_lc[0] as int
	var start_col := start_lc[1] as int
	var end_line := end_lc[0] as int
	var end_col := end_lc[1] as int

	for line in range(start_line, end_line + 1):
		var col_a := start_col if line == start_line else 0
		var col_b: int = end_col if line == end_line else _line_length(code, line)
		if col_b <= col_a:
			continue
		var p_a: Vector2i = code.get_pos_at_line_column(line, col_a)
		var p_b: Vector2i = code.get_pos_at_line_column(line, col_b)
		if p_a.x < 0 or p_b.x < 0:
			continue
		var y := float(p_a.y) + line_height - 1.0
		var x1 := float(p_a.x) + ce_local.x
		var x2 := float(p_b.x) + ce_local.x
		draw_line(Vector2(x1, y), Vector2(x2, y), _HEALTHY_COLOR, _UNDERLINE_THICKNESS)


func _line_length(code: Object, line: int) -> int:
	if code.has_method("get_line"):
		return str(code.get_line(line)).length()
	return 0


static func _flat_offset_to_line_col(doc: String, offset: int) -> Array:
	var line := 0
	var col := 0
	var i := 0
	while i < offset and i < doc.length():
		if doc[i] == "\n":
			line += 1
			col = 0
		else:
			col += 1
		i += 1
	return [line, col]
