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
const _BADGE_SIZE := Vector2(18.0, 16.0)


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
	var badge_slots_by_line := {}

	var display_index := 0
	for ann in anns:
		if not ann is Dictionary:
			continue
		display_index += 1
		var anchor: Dictionary = (ann as Dictionary).get("anchor", {})
		if anchor.is_empty():
			continue
		var resolved: Dictionary = host.resolve_anchor(anchor)
		if bool(resolved.get("stale", false)):
			_draw_broken(resolved, ce_local, ce_size, line_height, display_index, badge_slots_by_line)
		elif _is_line_annotation(ann as Dictionary):
			_draw_line_marker(anchor, code, ce_local, ce_size, line_height, display_index, badge_slots_by_line)
		else:
			_draw_healthy(anchor, code, ce_local, ce_size, line_height, display_index, badge_slots_by_line)


func _draw_broken(
	resolved: Dictionary,
	ce_local: Vector2,
	ce_size: Vector2,
	line_height: float,
	display_index: int,
	badge_slots_by_line: Dictionary
) -> void:
	var pos: Vector2 = resolved.get("position", Vector2.ZERO)
	var line_idx: int = int(pos.x)
	var y: float = ce_local.y + line_idx * line_height
	if y < ce_local.y or y > ce_local.y + ce_size.y:
		return
	var strip := Rect2(ce_local.x, y, _STRIP_WIDTH, line_height)
	draw_rect(strip, _BROKEN_COLOR, true)
	var fill := Rect2(ce_local.x + _STRIP_WIDTH, y, ce_size.x - _STRIP_WIDTH, line_height)
	draw_rect(fill, _BROKEN_FILL, true)
	_draw_badge_for_line(line_idx, ce_local, ce_size, line_height, display_index, _BROKEN_COLOR, badge_slots_by_line, ce_local.x + _STRIP_WIDTH, true)


func _draw_healthy(
	anchor: Dictionary,
	code: Object,
	ce_local: Vector2,
	ce_size: Vector2,
	line_height: float,
	display_index: int,
	badge_slots_by_line: Dictionary
) -> void:
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
	var badge_drawn := false
	var badge_leader_x := ce_local.x

	for line in range(start_line, end_line + 1):
		var col_a := start_col if line == start_line else 0
		var col_b: int = end_col if line == end_line else _line_length(code, line)
		if col_b <= col_a:
			continue
		var p_a: Vector2i = code.get_pos_at_line_column(line, col_a)
		var p_b: Vector2i = code.get_pos_at_line_column(line, col_b)
		if p_a.x < 0 or p_b.x < 0:
			continue
		# get_pos_at_line_column returns the baseline-ish y in code_edit-local
		# space; -1px nudges the line just above the API y for an underline
		# look directly under the text.
		var y := ce_local.y + float(p_a.y) - 1.0
		var x1 := float(p_a.x) + ce_local.x
		var x2 := float(p_b.x) + ce_local.x
		draw_line(Vector2(x1, y), Vector2(x2, y), _HEALTHY_COLOR, _UNDERLINE_THICKNESS)
		if not badge_drawn:
			badge_leader_x = x2
			badge_drawn = true

	if badge_drawn:
		_draw_badge_for_line(start_line, ce_local, ce_size, line_height, display_index, _HEALTHY_COLOR, badge_slots_by_line, badge_leader_x, true)


func _draw_line_marker(
	anchor: Dictionary,
	code: Object,
	ce_local: Vector2,
	ce_size: Vector2,
	line_height: float,
	display_index: int,
	badge_slots_by_line: Dictionary
) -> void:
	var id: Variant = anchor.get("id", null)
	if not id is Dictionary:
		return
	var start_v: Variant = (id as Dictionary).get("start", -1)
	if not start_v is int:
		return
	var doc: String = str(code.text) if "text" in code else ""
	var line_col := _flat_offset_to_line_col(doc, start_v as int)
	var line_idx := line_col[0] as int
	var y: float = ce_local.y + line_idx * line_height
	if y < ce_local.y or y > ce_local.y + ce_size.y:
		return
	draw_rect(Rect2(ce_local.x, y, _STRIP_WIDTH, line_height), _HEALTHY_COLOR, true)
	_draw_badge(
		Vector2(ce_local.x + _STRIP_WIDTH + 3.0, y + maxf(0.0, (line_height - _BADGE_SIZE.y) * 0.5)),
		display_index,
		_HEALTHY_COLOR
	)


func _draw_badge_for_line(
	line_idx: int,
	ce_local: Vector2,
	ce_size: Vector2,
	line_height: float,
	display_index: int,
	color: Color,
	badge_slots_by_line: Dictionary,
	leader_from_x: float,
	draw_leader: bool
) -> void:
	var slot := _claim_badge_slot(line_idx, badge_slots_by_line)
	var gap := 4.0
	var right_padding := 8.0
	var x := ce_local.x + ce_size.x - right_padding - _BADGE_SIZE.x - float(slot) * (_BADGE_SIZE.x + gap)
	x = maxf(ce_local.x + _STRIP_WIDTH + gap, x)
	var line_y := ce_local.y + float(line_idx) * line_height
	var y := line_y + maxf(0.0, (line_height - _BADGE_SIZE.y) * 0.5)
	if draw_leader:
		var leader_y := line_y + line_height - 3.0
		var leader_end_x := x - 3.0
		if leader_end_x > leader_from_x + 3.0:
			draw_line(
				Vector2(leader_from_x + 2.0, leader_y),
				Vector2(leader_end_x, leader_y),
				Color(color.r, color.g, color.b, 0.55),
				1.0
			)
	_draw_badge(Vector2(x, y), display_index, color)


func _claim_badge_slot(line_idx: int, badge_slots_by_line: Dictionary) -> int:
	var key := str(line_idx)
	var slot := int(badge_slots_by_line.get(key, 0))
	badge_slots_by_line[key] = slot + 1
	return slot


func _draw_badge(position: Vector2, display_index: int, color: Color) -> void:
	if display_index <= 0:
		return
	var rect := Rect2(position, _BADGE_SIZE)
	draw_rect(rect, color, true)
	draw_rect(rect, Color(0, 0, 0, 0.35), false, 1.0)
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 11
	if has_theme_font_size("font_size"):
		font_size = min(12, get_theme_font_size("font_size"))
	var text := str(display_index)
	var text_pos := position + Vector2(4.0 if display_index < 10 else 2.0, 12.0)
	draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color.WHITE)


func _is_line_annotation(annotation: Dictionary) -> bool:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and str((payload as Dictionary).get("target_scope", "")) == "line":
		return true
	var snapshot: Variant = annotation.get("anchor", {}).get("snapshot", {})
	return snapshot is Dictionary and str((snapshot as Dictionary).get("target_scope", "")) == "line"


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
