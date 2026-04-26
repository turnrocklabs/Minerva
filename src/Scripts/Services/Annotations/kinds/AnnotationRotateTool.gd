class_name AnnotationRotateTool
extends AnnotationAuthorTool
## Manipulation tool — rotates the selected annotation around its bounds-center
## using a visible gizmo handle drawn above the bounds.
##
## Pattern: stateless aside from drag-state. Selection is HOST state (read via
## host.get_selected_annotation_id()). Mirrors AnnotationSelectTool.gd and
## complements TranslateTool / ScaleTool.
##
## Gizmo geometry (doc-space):
##   - Connector line: from bounds.get_center() straight up to the handle.
##   - Handle:         filled circle at bounds.get_center() + (0, -h/2 - HANDLE_OFFSET_DOC).
##   - Hit-radius:     HANDLE_HIT_RADIUS_DOC (12 doc-units) — generous so the
##                     handle is grabbable even when the bounds are tiny.
##
## Rotation convention (IMPORTANT — screen-Y-down):
##   We treat angles as Vector2.angle() does — the angle of a vector measured
##   counterclockwise from +X. Because Godot's screen Y axis points DOWN, a
##   positive Vector2.angle() value visually rotates CLOCKWISE on screen, which
##   matches user expectation when dragging the handle clockwise around the
##   bounds-center. Translation: dragging the handle clockwise on screen rotates
##   the annotation clockwise on screen.
##
## Drag math:
##   start_angle = (pointer_at_press - center).angle()
##   curr_angle  = (pointer_now - center).angle()
##   delta       = curr_angle - start_angle, normalised to [-π, π] so dragging
##                 across the +X axis doesn't flip direction.
##   transform   = T(center) · R(delta) · T(-center)
##   new_primitives = AnnotationKind.transform_primitives(start_primitives, transform)
##
## We store a deep-copy of the annotation at drag-start and re-apply the full
## transform every move, so the dictionary doesn't drift through accumulated
## floating-point error and ESC reverts to the exact original.
##
## Signals: emits annotation_modified(id, new_dict) only. Never annotation_ready.

# ── Gizmo style / geometry ────────────────────────────────────────────────────

const HANDLE_OFFSET_DOC: float       = 16.0
const HANDLE_RADIUS_DOC: float       = 6.0
const HANDLE_HIT_RADIUS_DOC: float   = 12.0
const HANDLE_COLOR: Color            = Color(1.0, 0.5, 0.0)             # orange
const GIZMO_LINE_COLOR: Color        = Color(0.6, 0.6, 0.6, 0.5)        # subtle grey
const ARC_COLOR: Color               = Color(1.0, 0.5, 0.0, 0.6)        # arc tint
const HANDLE_POLY_SEGMENTS: int      = 16
const ARC_SEGMENTS: int              = 32

# ── State ─────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null
var _dragging: bool = false
var _drag_start_annotation: Dictionary = {}
var _drag_start_id: String = ""
var _rotation_center_doc: Vector2 = Vector2.ZERO
var _drag_start_angle_rad: float = 0.0
var _current_angle_rad: float = 0.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_reset_drag_state()


func on_deactivate() -> void:
	# Silent reset — no cancelled() emission per spec.
	_reset_drag_state()
	_host = null


func _reset_drag_state() -> void:
	_dragging = false
	_drag_start_annotation = {}
	_drag_start_id = ""
	_rotation_center_doc = Vector2.ZERO
	_drag_start_angle_rad = 0.0
	_current_angle_rad = 0.0


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	if _host == null:
		return false

	# Right-click — let host handle (context menu / pan).
	if button == MOUSE_BUTTON_RIGHT:
		return false

	# ESC during drag → revert.
	if mods == KEY_ESCAPE:
		if _dragging:
			_revert_drag()
			return true
		return false

	if button != MOUSE_BUTTON_LEFT:
		return false

	var sel := _host.get_selected_annotation_id()
	if sel == "":
		return false

	var ann := _find_annotation(sel)
	if ann.is_empty():
		return false

	var kind := _kind_for(ann)
	if kind == null:
		return false

	var b: Rect2 = kind.bounds(ann)
	var center: Vector2 = b.get_center()
	var handle_pos: Vector2 = _handle_position(b)

	var doc_pos: Vector2 = _host.transform_screen_to_doc(pos)
	if doc_pos.distance_to(handle_pos) > HANDLE_HIT_RADIUS_DOC:
		# Click was not on the handle — let other tools see it.
		return false

	# Begin drag.
	_dragging = true
	_drag_start_annotation = ann.duplicate(true)
	_drag_start_id = sel
	_rotation_center_doc = center
	_drag_start_angle_rad = (doc_pos - center).angle()
	_current_angle_rad = _drag_start_angle_rad
	return true


func on_pointer_move(pos: Vector2) -> void:
	if not _dragging or _host == null:
		return

	var doc_pos: Vector2 = _host.transform_screen_to_doc(pos)
	var raw_angle: float = (doc_pos - _rotation_center_doc).angle()
	_current_angle_rad = raw_angle

	var delta: float = _normalise_angle(raw_angle - _drag_start_angle_rad)

	var t_to_origin := Transform2D(0.0, -_rotation_center_doc)
	var t_rotate    := Transform2D(delta, Vector2.ZERO)
	var t_back      := Transform2D(0.0, _rotation_center_doc)
	var transform   := t_back * t_rotate * t_to_origin

	var start_prims: Array = _drag_start_annotation.get("primitives", [])
	var new_ann: Dictionary = _drag_start_annotation.duplicate(true)
	new_ann["primitives"] = AnnotationKind.transform_primitives(start_prims, transform)

	annotation_modified.emit(_drag_start_id, new_ann)


func on_pointer_up(_pos: Vector2, button: int, _mods: int) -> bool:
	if not _dragging:
		return false
	if button == MOUSE_BUTTON_LEFT:
		# Finalise — last on_pointer_move already emitted the committed state.
		var was_dragging := _dragging
		_reset_drag_state()
		return was_dragging
	return false


# ── Revert on ESC ─────────────────────────────────────────────────────────────

func _revert_drag() -> void:
	if _drag_start_id != "" and not _drag_start_annotation.is_empty():
		annotation_modified.emit(_drag_start_id, _drag_start_annotation.duplicate(true))
	_reset_drag_state()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _find_annotation(id: String) -> Dictionary:
	if _host == null:
		return {}
	for ann in _host.get_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == id:
			return ann
	return {}


func _kind_for(ann: Dictionary) -> AnnotationKind:
	if _host == null:
		return null
	var registry := _host.get_registry()
	if registry == null:
		return null
	return registry.get_annotation_kind(StringName(ann.get("kind", "")))


func _handle_position(b: Rect2) -> Vector2:
	# Use bounds.get_center() (real geometric centre) rather than re-deriving
	# from corners — avoids the PCBEditor "all-anchors-at-top-left" bug.
	var center: Vector2 = b.get_center()
	return center + Vector2(0.0, -b.size.y * 0.5 - HANDLE_OFFSET_DOC)


static func _normalise_angle(a: float) -> float:
	# Wrap to (-π, π]. Vector2.angle() returns -π..π, so the raw delta can be
	# in (-2π, 2π). Without normalisation, a drag that crosses the +X axis
	# would briefly flip rotation direction.
	while a > PI:
		a -= TAU
	while a <= -PI:
		a += TAU
	return a


# ── Preview ───────────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	if _host == null:
		return
	var sel := _host.get_selected_annotation_id()
	if sel == "":
		return

	var ann := _find_annotation(sel)
	if ann.is_empty():
		return

	var kind := _kind_for(ann)
	if kind == null:
		return

	var b: Rect2 = kind.bounds(ann)
	var center: Vector2 = b.get_center()
	var handle_pos: Vector2 = _handle_position(b)

	# 1) Connector line center → handle.
	ctx.draw_line(center, handle_pos, GIZMO_LINE_COLOR, 1.0)

	# 2) Handle (filled circle approximated as 16-gon).
	_draw_filled_disc(ctx, handle_pos, HANDLE_RADIUS_DOC, HANDLE_COLOR)

	# 3) In-progress arc (only while dragging) — visual feedback for delta angle.
	if _dragging:
		_draw_angle_arc(ctx, center, _drag_start_angle_rad, _current_angle_rad)


func _draw_filled_disc(
	ctx: AnnotationRenderContext,
	at: Vector2,
	radius: float,
	color: Color,
) -> void:
	var pts := PackedVector2Array()
	pts.resize(HANDLE_POLY_SEGMENTS)
	for i in HANDLE_POLY_SEGMENTS:
		var theta: float = TAU * float(i) / float(HANDLE_POLY_SEGMENTS)
		pts[i] = at + Vector2(cos(theta), sin(theta)) * radius
	var cols := PackedColorArray()
	cols.resize(HANDLE_POLY_SEGMENTS)
	for i in HANDLE_POLY_SEGMENTS:
		cols[i] = color
	ctx.draw_polygon(pts, cols)


func _draw_angle_arc(
	ctx: AnnotationRenderContext,
	center: Vector2,
	from_angle: float,
	to_angle: float,
) -> void:
	# Arc rendered at a fixed doc-space radius slightly inside the handle ring,
	# as a polyline. Sample ARC_SEGMENTS+1 points along the shortest arc from
	# from_angle to to_angle.
	var delta: float = _normalise_angle(to_angle - from_angle)
	if abs(delta) < 0.001:
		return
	var radius: float = HANDLE_OFFSET_DOC * 0.5
	var pts := PackedVector2Array()
	pts.resize(ARC_SEGMENTS + 1)
	for i in ARC_SEGMENTS + 1:
		var t: float = float(i) / float(ARC_SEGMENTS)
		var theta: float = from_angle + delta * t
		pts[i] = center + Vector2(cos(theta), sin(theta)) * radius
	ctx.draw_polyline(pts, ARC_COLOR, 1.0)
