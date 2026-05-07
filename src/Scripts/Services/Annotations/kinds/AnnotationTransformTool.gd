class_name AnnotationTransformTool
extends AnnotationAuthorTool
## Unified transform tool — collapses Select / Translate / Rotate / Scale into
## one gizmo with zone-routed drag semantics.
##
## When activated the tool shows:
##   - A faint bounds outline
##   - Four filled-square handles at the corners (scale)
##   - Four filled-square handles at the edge midpoints (axis-locked scale)
##   - Four rotate-ring arcs just outside each corner (rotate)
##
## Click routing:
##   - CORNER_*       → uniform scale drag
##   - EDGE_*         → axis-locked scale drag
##   - ROTATE_*       → rotation drag around bounds-center
##   - INSIDE         → translate drag
##   - OUTSIDE / no selection → SelectTool semantics (hit-test annotations)
##
## Keyboard:
##   - KEY_DELETE     → host.remove_annotation(selected_id)
##   - KEY_ESCAPE     → revert in-progress drag (or clear selection if idle)
##
## Emits annotation_modified(id, new_dict) only. Never annotation_ready.

# ── Zone constants — tune here for the polish pass ──────────────────────────

## Corner + edge handle hit zone radius, in document units.
const HANDLE_HIT_RADIUS_DOC: float = 12.0

## Outer radius of rotate-ring annulus from corner, in document units.
const ROTATE_RING_OUTER_DOC: float = 28.0

## Inner radius of rotate-ring annulus (= corner hit zone) so zones don't
## overlap: corner wins if dist < 12; rotate ring wins if 12 ≤ dist ≤ 28.
const ROTATE_RING_INNER_DOC: float = 12.0

## Filled-square gizmo size for corner and edge handles, in document units.
const HANDLE_SIZE_DOC: float = 6.0

## Minimum scale factor — prevents collapsing to zero or mirroring.
const MIN_SCALE: float = 0.05

# ── Visual constants ──────────────────────────────────────────────────────────

## Cyan corner/edge handle fill (matches ScaleTool convention).
const HANDLE_COLOR: Color         = Color(0.2, 0.7, 1.0)

## Orange rotate-ring / arc color (matches RotateTool convention).
const ROTATE_HANDLE_COLOR: Color  = Color(1.0, 0.5, 0.0)

## Subtle grey bounds outline.
const BOUNDS_COLOR: Color         = Color(0.6, 0.6, 0.6, 0.5)

## In-progress rotation arc tint.
const ARC_COLOR: Color            = Color(1.0, 0.5, 0.0, 0.6)

const ARC_SEGMENTS: int    = 32
const DISC_SEGMENTS: int   = 16
const ROTATE_DISC_RADIUS: float = 5.0

# ── Zones ────────────────────────────────────────────────────────────────────

enum Zone {
	OUTSIDE,
	INSIDE,
	CORNER_TL, CORNER_TR, CORNER_BL, CORNER_BR,
	EDGE_T, EDGE_B, EDGE_L, EDGE_R,
	ROTATE_TL, ROTATE_TR, ROTATE_BL, ROTATE_BR,
}

# ── State ─────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null
var _dragging: bool = false
var _active_zone: Zone = Zone.OUTSIDE

## Deep-copied annotation snapshot at drag start.
var _drag_start_annotation: Dictionary = {}
var _drag_id: String = ""

## Translate: doc position at drag start.
var _drag_start_doc: Vector2 = Vector2.ZERO

## Scale: center + start handle offset.
var _scale_center_doc: Vector2 = Vector2.ZERO
var _drag_start_handle_offset: Vector2 = Vector2.ZERO

## Rotate: center + start angle.
var _rotation_center_doc: Vector2 = Vector2.ZERO
var _drag_start_angle_rad: float = 0.0
var _current_angle_rad: float = 0.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_reset_drag_state()


func on_deactivate() -> void:
	# Silent reset — no revert, no signal. Clean tool-switch.
	_reset_drag_state()
	_host = null


func _reset_drag_state() -> void:
	_dragging = false
	_active_zone = Zone.OUTSIDE
	_drag_start_annotation = {}
	_drag_id = ""
	_drag_start_doc = Vector2.ZERO
	_scale_center_doc = Vector2.ZERO
	_drag_start_handle_offset = Vector2.ZERO
	_rotation_center_doc = Vector2.ZERO
	_drag_start_angle_rad = 0.0
	_current_angle_rad = 0.0


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	if _host == null:
		return false

	# Right-click: let host handle.
	if button == MOUSE_BUTTON_RIGHT:
		return false

	# DELETE: remove selected annotation.
	if mods == KEY_DELETE:
		var sel := _host.get_selected_annotation_id()
		if sel != "":
			_host.remove_annotation(sel)
			_reset_drag_state()
		# Always consume.
		return true

	# ESCAPE: revert drag if in progress, otherwise clear selection.
	if mods == KEY_ESCAPE:
		if _dragging:
			_revert_drag()
			return true
		# Idle escape — clear selection (mirrors SelectTool).
		_host.set_selected_annotation_id("")
		return true

	if button != MOUSE_BUTTON_LEFT:
		return false

	var doc_pos := _host.transform_screen_to_doc(pos)
	var selected_id := _host.get_selected_annotation_id()

	# ── With a selection: try to hit-test the gizmo zones ───────────────────────
	if selected_id != "":
		var ann := _find_annotation(selected_id)
		if not ann.is_empty():
			var kind := _get_kind(ann)
			if kind != null:
				var b: Rect2 = kind.bounds(ann)
				var zone := _hit_zone(doc_pos, b)
				if zone != Zone.OUTSIDE:
					return _begin_drag(zone, doc_pos, selected_id, ann, b)
				# Click was outside the gizmo entirely — fall through to
				# SelectTool semantics so user can click a different annotation.

	# ── No active gizmo hit: SelectTool semantics ────────────────────────────────
	return _do_selection(doc_pos)


func on_pointer_move(pos: Vector2) -> void:
	if not _dragging or _host == null:
		return

	var doc_pos := _host.transform_screen_to_doc(pos)

	match _active_zone:
		Zone.INSIDE:
			_apply_translate(doc_pos)
		Zone.CORNER_TL, Zone.CORNER_TR, Zone.CORNER_BL, Zone.CORNER_BR:
			_apply_uniform_scale(doc_pos)
		Zone.EDGE_T, Zone.EDGE_B:
			_apply_axis_scale(doc_pos, false, true)   # Y-locked
		Zone.EDGE_L, Zone.EDGE_R:
			_apply_axis_scale(doc_pos, true, false)   # X-locked
		Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR:
			_apply_rotate(doc_pos)


func on_pointer_up(_pos: Vector2, button: int, _mods: int) -> bool:
	if not _dragging:
		return false
	if button == MOUSE_BUTTON_LEFT:
		_reset_drag_state()
		return true
	return false


# ── Zone hit-test ─────────────────────────────────────────────────────────────

## Classify a document-space point against the bounding-box gizmo of `b`.
## Priority (highest first):
##   1. CORNER_* (dist from corner < HANDLE_HIT_RADIUS_DOC)
##   2. ROTATE_* (dist from corner in [ROTATE_RING_INNER_DOC, ROTATE_RING_OUTER_DOC])
##   3. EDGE_*   (dist from edge midpoint ≤ HANDLE_HIT_RADIUS_DOC AND not within
##                HANDLE_HIT_RADIUS_DOC of any corner)
##   4. INSIDE   (b.has_point(doc_pos))
##   5. OUTSIDE
static func _hit_zone(doc_pos: Vector2, b: Rect2) -> Zone:
	var corners := _corner_positions(b)
	# corners order: TL=0, TR=1, BL=2, BR=3
	var corner_zones: Array = [Zone.CORNER_TL, Zone.CORNER_TR, Zone.CORNER_BL, Zone.CORNER_BR]
	var rotate_zones: Array = [Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR]

	# 1. CORNER check
	for i in corners.size():
		var dist := doc_pos.distance_to(corners[i])
		if dist < HANDLE_HIT_RADIUS_DOC:
			return corner_zones[i]

	# Compact annotations such as short text labels can be smaller than the
	# combined edge/rotate hit zones. Preserve a usable translate target inside
	# the bounds; exact corner handles still win above.
	var inside_bounds := b.has_point(doc_pos)
	var compact_bounds := b.size.x <= HANDLE_HIT_RADIUS_DOC * 2.5 or b.size.y <= HANDLE_HIT_RADIUS_DOC * 2.5
	if inside_bounds and compact_bounds:
		return Zone.INSIDE

	# 2. ROTATE ring check (annulus around each corner)
	for i in corners.size():
		var dist := doc_pos.distance_to(corners[i])
		if dist >= ROTATE_RING_INNER_DOC and dist <= ROTATE_RING_OUTER_DOC:
			return rotate_zones[i]

	# 3. EDGE midpoint check — guard: must not be within corner hit radius of any corner
	var edge_midpoints := _edge_midpoints(b)
	# edge order: T=0, B=1, L=2, R=3
	var edge_zones: Array = [Zone.EDGE_T, Zone.EDGE_B, Zone.EDGE_L, Zone.EDGE_R]
	for i in edge_midpoints.size():
		var mid: Vector2 = edge_midpoints[i]
		if doc_pos.distance_to(mid) <= HANDLE_HIT_RADIUS_DOC:
			# Guard: must not be within corner hit radius of any corner
			var near_corner := false
			for corner in corners:
				if doc_pos.distance_to(corner) < HANDLE_HIT_RADIUS_DOC:
					near_corner = true
					break
			if not near_corner:
				return edge_zones[i]

	# 4. INSIDE
	if inside_bounds:
		return Zone.INSIDE

	# 5. OUTSIDE
	return Zone.OUTSIDE


# ── Corner / edge geometry helpers ────────────────────────────────────────────

## Returns [TL, TR, BL, BR] corners in document space.
## _corner suffix because plain `tr` shadows Object.tr translation method.
static func _corner_positions(b: Rect2) -> Array:
	var tl_corner := b.position
	var tr_corner := b.position + Vector2(b.size.x, 0.0)
	var bl_corner := b.position + Vector2(0.0, b.size.y)
	var br_corner := b.position + b.size
	return [tl_corner, tr_corner, bl_corner, br_corner]


## Returns [T, B, L, R] edge midpoints in document space.
static func _edge_midpoints(b: Rect2) -> Array:
	var cx := b.position.x + b.size.x * 0.5
	var cy := b.position.y + b.size.y * 0.5
	var top    := Vector2(cx, b.position.y)
	var bottom := Vector2(cx, b.position.y + b.size.y)
	var left   := Vector2(b.position.x, cy)
	var right  := Vector2(b.position.x + b.size.x, cy)
	return [top, bottom, left, right]


# ── Drag initiation ───────────────────────────────────────────────────────────

func _begin_drag(zone: Zone, doc_pos: Vector2, ann_id: String,
		ann: Dictionary, b: Rect2) -> bool:
	_dragging = true
	_active_zone = zone
	_drag_start_annotation = ann.duplicate(true)
	_drag_id = ann_id
	var center := b.get_center()

	match zone:
		Zone.INSIDE:
			_drag_start_doc = doc_pos

		Zone.CORNER_TL, Zone.CORNER_TR, Zone.CORNER_BL, Zone.CORNER_BR:
			_scale_center_doc = center
			_drag_start_handle_offset = doc_pos - center

		Zone.EDGE_T, Zone.EDGE_B, Zone.EDGE_L, Zone.EDGE_R:
			_scale_center_doc = center
			_drag_start_handle_offset = doc_pos - center

		Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR:
			_rotation_center_doc = center
			_drag_start_angle_rad = (doc_pos - center).angle()
			_current_angle_rad = _drag_start_angle_rad

	return true


# ── Drag math ─────────────────────────────────────────────────────────────────

func _apply_translate(doc_pos: Vector2) -> void:
	var delta := doc_pos - _drag_start_doc
	var transform := Transform2D(0.0, delta)
	_emit_transformed_annotation(transform, "translate")


func _apply_uniform_scale(doc_pos: Vector2) -> void:
	var current_offset := doc_pos - _scale_center_doc
	var sx := 1.0
	var sy := 1.0
	if absf(_drag_start_handle_offset.x) > 0.001:
		sx = current_offset.x / _drag_start_handle_offset.x
	if absf(_drag_start_handle_offset.y) > 0.001:
		sy = current_offset.y / _drag_start_handle_offset.y
	var s := minf(sx, sy)
	s = maxf(s, MIN_SCALE)
	var transform := _build_scale_transform(_scale_center_doc, s, s)
	_emit_transformed_annotation(transform, "scale")


func _apply_axis_scale(doc_pos: Vector2, lock_x: bool, lock_y: bool) -> void:
	var current_offset := doc_pos - _scale_center_doc
	var sx := 1.0
	var sy := 1.0
	if lock_x and absf(_drag_start_handle_offset.x) > 0.001:
		sx = current_offset.x / _drag_start_handle_offset.x
		sx = maxf(sx, MIN_SCALE)
	if lock_y and absf(_drag_start_handle_offset.y) > 0.001:
		sy = current_offset.y / _drag_start_handle_offset.y
		sy = maxf(sy, MIN_SCALE)
	var transform := _build_scale_transform(_scale_center_doc, sx, sy)
	_emit_transformed_annotation(transform, "scale")


func _apply_rotate(doc_pos: Vector2) -> void:
	var raw_angle := (doc_pos - _rotation_center_doc).angle()
	_current_angle_rad = raw_angle
	var delta := _normalise_angle(raw_angle - _drag_start_angle_rad)

	var t_to_origin := Transform2D(0.0, -_rotation_center_doc)
	var t_rotate    := Transform2D(delta, Vector2.ZERO)
	var t_back      := Transform2D(0.0, _rotation_center_doc)
	var transform   := t_back * t_rotate * t_to_origin
	_emit_transformed_annotation(transform, "rotate")


func _emit_transformed_annotation(transform: Transform2D, operation: String) -> void:
	var kind := _get_kind(_drag_start_annotation)
	var new_ann: Dictionary
	if kind != null:
		new_ann = kind.transform_annotation(_drag_start_annotation, transform, operation)
	else:
		new_ann = _drag_start_annotation.duplicate(true)
		var primitives: Variant = new_ann.get("primitives", [])
		if primitives is Array:
			new_ann["primitives"] = AnnotationKind.transform_primitives(primitives as Array, transform)
	annotation_modified.emit(_drag_id, new_ann)


func _revert_drag() -> void:
	if _drag_id != "" and not _drag_start_annotation.is_empty():
		annotation_modified.emit(_drag_id, _drag_start_annotation.duplicate(true))
	_reset_drag_state()


# ── SelectTool semantics ──────────────────────────────────────────────────────

## Hit-test all annotations in reverse order (topmost first). Sets or clears
## the host's selection. Returns true (always consumes the click).
##
## Click-empty also deactivates the tool. The overlay holds mouse_filter=STOP
## while a tool is active (AnnotationOverlay.set_active_tool flips it), so a
## sticky Select tool blocks the underlying SubViewport's camera orbit. Emitting
## `cancelled` after a no-hit click lets the toolbar untoggle the button and
## flip the overlay back to IGNORE, restoring orbit without forcing the user
## to mouse over to the toolbar to manually deselect.
func _do_selection(doc_pos: Vector2) -> bool:
	var registry := _host.get_registry()
	var annotations: Array = _host.get_annotations()
	const HIT_THRESHOLD := 8.0

	for i in range(annotations.size() - 1, -1, -1):
		var ann: Dictionary = annotations[i]
		var kind_name := StringName(ann.get("kind", ""))
		var kind: AnnotationKind = null
		if registry != null:
			kind = registry.get_annotation_kind(kind_name)
		if kind == null:
			continue
		if kind.hit_test(ann, doc_pos, HIT_THRESHOLD):
			_host.set_selected_annotation_id(str(ann.get("id", "")))
			return true

	# No hit — clear selection AND deactivate the tool so the overlay's
	# mouse_filter flips back to IGNORE and the underlying SubViewport
	# regains camera-orbit control. The toolbar's _on_tool_cancelled does
	# the full untoggle pipeline.
	_host.set_selected_annotation_id("")
	_reset_drag_state()
	cancelled.emit()
	return true


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
	var kind := _get_kind(ann)
	if kind == null:
		return

	var b: Rect2 = kind.bounds(ann)

	# 1) Faint bounds outline.
	ctx.draw_rect(b, BOUNDS_COLOR, false, 1.0)

	# 2) Corner handles (filled squares).
	var half := HANDLE_SIZE_DOC * 0.5
	for corner_pos in _corner_positions(b):
		var r := Rect2(corner_pos - Vector2(half, half), Vector2(HANDLE_SIZE_DOC, HANDLE_SIZE_DOC))
		ctx.draw_rect(r, HANDLE_COLOR, true, 1.0)

	# 3) Edge midpoint handles (filled squares, same style).
	for mid_pos in _edge_midpoints(b):
		var r := Rect2(mid_pos - Vector2(half, half), Vector2(HANDLE_SIZE_DOC, HANDLE_SIZE_DOC))
		ctx.draw_rect(r, HANDLE_COLOR, true, 1.0)

	# 4) Rotate-ring visual: small discs just outside each corner.
	#    NOTE: the visible disc is only an indicator — the actual hit zone is
	#    the full annulus around the corner (see _hit_zone). Users grabbing
	#    anywhere in [INNER, OUTER] from a corner triggers rotate, even if
	#    the click misses the visible disc.
	var corners := _corner_positions(b)
	var corner_offsets: Array[Vector2] = [
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0),
		Vector2(-1.0, 1.0),  Vector2(1.0, 1.0),
	]
	for i in corners.size():
		var offset_dir: Vector2 = corner_offsets[i].normalized()
		var ring_pos: Vector2 = corners[i] + offset_dir * ((ROTATE_RING_INNER_DOC + ROTATE_RING_OUTER_DOC) * 0.5)
		_draw_filled_disc(ctx, ring_pos, ROTATE_DISC_RADIUS, ROTATE_HANDLE_COLOR)

	# 5) In-progress rotation arc.
	if _dragging and _active_zone in [Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR]:
		_draw_angle_arc(ctx, _rotation_center_doc, _drag_start_angle_rad, _current_angle_rad)


func _draw_filled_disc(ctx: AnnotationRenderContext, at: Vector2,
		radius: float, color: Color) -> void:
	var pts := PackedVector2Array()
	pts.resize(DISC_SEGMENTS)
	for i in DISC_SEGMENTS:
		var theta: float = TAU * float(i) / float(DISC_SEGMENTS)
		pts[i] = at + Vector2(cos(theta), sin(theta)) * radius
	var cols := PackedColorArray()
	cols.resize(DISC_SEGMENTS)
	for i in DISC_SEGMENTS:
		cols[i] = color
	ctx.draw_polygon(pts, cols)


func _draw_angle_arc(ctx: AnnotationRenderContext, center: Vector2,
		from_angle: float, to_angle: float) -> void:
	var delta := _normalise_angle(to_angle - from_angle)
	if absf(delta) < 0.001:
		return
	var radius := (ROTATE_RING_INNER_DOC + ROTATE_RING_OUTER_DOC) * 0.5
	var pts := PackedVector2Array()
	pts.resize(ARC_SEGMENTS + 1)
	for i in ARC_SEGMENTS + 1:
		var t: float = float(i) / float(ARC_SEGMENTS)
		var theta: float = from_angle + delta * t
		pts[i] = center + Vector2(cos(theta), sin(theta)) * radius
	ctx.draw_polyline(pts, ARC_COLOR, 1.0)


# ── Private helpers ───────────────────────────────────────────────────────────

static func _normalise_angle(a: float) -> float:
	while a > PI:
		a -= TAU
	while a <= -PI:
		a += TAU
	return a


## Build a (possibly non-uniform) scale transform centered at `center`:
##   T = T(+center) · S(sx, sy) · T(-center)
static func _build_scale_transform(center: Vector2, sx: float, sy: float) -> Transform2D:
	var t_to_origin := Transform2D(0.0, -center)
	var t_scale := Transform2D(0.0, Vector2.ZERO).scaled(Vector2(sx, sy))
	var t_back := Transform2D(0.0, center)
	return t_back * t_scale * t_to_origin


func _find_annotation(ann_id: String) -> Dictionary:
	if _host == null:
		return {}
	for ann in _host.get_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == ann_id:
			return ann as Dictionary
	return {}


func _get_kind(ann: Dictionary) -> AnnotationKind:
	if _host == null:
		return null
	var registry := _host.get_registry()
	if registry == null:
		return null
	var kind_name := StringName(ann.get("kind", ""))
	return registry.get_annotation_kind(kind_name)
