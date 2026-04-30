extends Control
## Overlay that paints broken-anchor indicators on top of a Type.TEXT Editor.
##
## Round 5b.i deliverable: when an annotation's anchor resolves stale, paint
## a warning-tinted strip on the left gutter at the (best-effort) line plus
## a corner badge showing the total broken count. No interactivity yet —
## sidebar / Repair button is 5b.ii.

const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 0.85)
const _BROKEN_FILL := Color(1.0, 0.55, 0.05, 0.18)
const _STRIP_WIDTH := 4.0


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
		if not bool(resolved.get("stale", false)):
			continue
		var pos: Vector2 = resolved.get("position", Vector2.ZERO)
		var line_idx: int = int(pos.x)
		var y: float = ce_local.y + line_idx * line_height
		if y < ce_local.y or y > ce_local.y + ce_size.y:
			continue
		var strip := Rect2(ce_local.x, y, _STRIP_WIDTH, line_height)
		draw_rect(strip, _BROKEN_COLOR, true)
		var fill := Rect2(ce_local.x + _STRIP_WIDTH, y, ce_size.x - _STRIP_WIDTH, line_height)
		draw_rect(fill, _BROKEN_FILL, true)
