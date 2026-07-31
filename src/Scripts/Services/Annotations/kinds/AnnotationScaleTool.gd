class_name AnnotationScaleTool
extends AnnotationAuthorTool
## SUBSUMED — retired, not reachable from any UI. Superseded by
## AnnotationTransformTool, the one universal manipulation tool (select + move +
## rotate + scale, no mode switching); its Zone.CORNER_* / Zone.EDGE_* handles
## are this behavior. AnnotationToolbar._construct_tool_for_name no longer builds
## this class and nothing else constructs it outside tests. Kept on disk only so
## its tests and history stay readable; slated for deletion. Do NOT re-list it in
## a toolbar and do NOT add features here.
##
## Manipulation tool: scale the selected annotation by dragging one of four
## corner gizmo handles around the annotation's bounds-center anchor.
##
## State machine:
##   IDLE → (left-click hits a corner handle) → DRAGGING
##   DRAGGING → (pointer_move) → emits annotation_modified live
##   DRAGGING → (pointer_up)   → IDLE (last live emission is the committed value)
##   DRAGGING → (KEY_ESCAPE)   → IDLE (re-emits the start state to revert)
##   DRAGGING → (on_deactivate)→ IDLE silent (no revert, no signal)
##
## Anchor: the bounds-center at drag start. Scale math is symmetric — the corner
## the user grabbed is informational (used for visual feedback only).
##
## Uniform vs non-uniform scale (DESIGN DECISION):
##   We use UNIFORM scale by default. The per-axis ratios (sx, sy) are computed
##   from the live drag offset versus the start offset; we then take their
##   SIGNED MIN to keep the dominant motion direction. This is the most common
##   UX (drag any corner = uniform resize) and avoids accidental shears or
##   mirroring. Non-uniform / per-axis stretch is explicitly out of scope here
##   and can be added later as a polish (e.g. via a modifier key).
##
## Clamp behaviour:
##   To prevent collapsing the annotation to zero or flipping it via negative
##   scale, the chosen scale factor is clamped to MIN_SCALE (= 0.05). Dragging
##   past the center therefore freezes at the clamp rather than mirroring.
##
## PCB-bug avoidance:
##   PCBCanvas has a known bug (docket 019dc65b39fb7d2ca049e951b777ee6b) where
##   text-bounds anchors all render at top-left. We DO NOT replicate that:
##   _corner_positions() computes the four corners independently from
##   bounds.position and bounds.size so that they always resolve to four DIFFERENT
##   points when bounds is non-degenerate. The "anchor placement" unit test
##   asserts this directly.
##
## Coordinate path:
##   pos (screen) → host.transform_screen_to_doc(pos) → doc coords
##   transform = T(+center) · S(s, s) · T(-center)
##   new_prims = AnnotationKind.transform_primitives(start_prims, transform)

# ── Visual / hit constants ────────────────────────────────────────────────────

## Side length of a corner handle's filled-square gizmo, in document units.
const HANDLE_SIZE_DOC: float = 6.0

## Hit-test radius around each corner anchor, in document units. Generous so the
## handle is easy to grab even at non-1:1 zooms.
const HANDLE_HIT_RADIUS_DOC: float = 12.0

## Cyan handle fill (matches general manipulation-gizmo convention in Minerva).
const HANDLE_COLOR: Color = Color(0.2, 0.7, 1.0)

## Subtle grey for the bounds-outline guide.
const BOUNDS_COLOR: Color = Color(0.6, 0.6, 0.6, 0.5)

## Floor on the scale factor — prevents zero/negative scale.
const MIN_SCALE: float = 0.05

# ── Corner indices (informational — scale math is symmetric) ──────────────────

const CORNER_TL: int = 0
const CORNER_TR: int = 1
const CORNER_BL: int = 2
const CORNER_BR: int = 3

# ── State ─────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null
var _dragging: bool = false
## Deep-copy snapshot of the annotation dict at drag start.
var _drag_start_annotation: Dictionary = {}
## Bounds-center at drag start — the anchor point about which we scale.
var _scale_center_doc: Vector2 = Vector2.ZERO
## Vector from center to the grabbed corner at drag start.
var _drag_start_handle_offset: Vector2 = Vector2.ZERO
## Which of the four corners is being dragged (0=TL, 1=TR, 2=BL, 3=BR).
## Visual feedback only — the math is symmetric across corners.
var _grabbed_corner: int = -1
## Id of the annotation being scaled.
var _drag_id: String = ""


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_reset_state()


func on_deactivate() -> void:
	# Silent reset: if a drag was in progress, drop it without emitting any
	# revert signal. Per design, deactivation is a clean tool-switch.
	_reset_state()
	_host = null


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# Right-click: always no-op; let the host handle it.
	if button == MOUSE_BUTTON_RIGHT:
		return false

	# Escape surfaced via the mods channel (matches arrow / select / translate pattern).
	if mods == KEY_ESCAPE:
		if _dragging:
			# Revert by re-emitting the start state.
			annotation_modified.emit(_drag_id, _drag_start_annotation)
			_reset_state()
			return true
		return false

	if button != MOUSE_BUTTON_LEFT:
		return false

	if _host == null:
		return false

	# Need an active selection to begin a scale drag.
	var selected_id := _host.get_selected_annotation_id()
	if selected_id == "":
		return false

	var ann := _find_annotation(selected_id)
	if ann.is_empty():
		return false

	var kind := _get_kind(ann)
	if kind == null:
		return false

	var doc_pos := _host.transform_screen_to_doc(pos)
	var b: Rect2 = kind.bounds(ann)
	var corners := _corner_positions(b)

	# Hit-test each corner. First one within HANDLE_HIT_RADIUS_DOC wins.
	for i in corners.size():
		var corner_pos: Vector2 = corners[i]
		if doc_pos.distance_to(corner_pos) <= HANDLE_HIT_RADIUS_DOC:
			# Begin drag.
			_dragging = true
			_grabbed_corner = i
			_drag_start_annotation = ann.duplicate(true)
			_drag_id = selected_id
			_scale_center_doc = b.get_center()
			_drag_start_handle_offset = corner_pos - _scale_center_doc
			return true

	# No corner hit — let the host (or other tools) handle the click.
	return false


func on_pointer_move(pos: Vector2) -> void:
	if not _dragging or _host == null:
		return

	var doc_pos := _host.transform_screen_to_doc(pos)
	var current_handle_offset := doc_pos - _scale_center_doc

	# Per-axis ratios. Guard against degenerate (zero-size) start offsets to
	# avoid divide-by-zero when bounds.size is zero on either axis.
	var sx: float = 1.0
	var sy: float = 1.0
	if absf(_drag_start_handle_offset.x) > 0.001:
		sx = current_handle_offset.x / _drag_start_handle_offset.x
	if absf(_drag_start_handle_offset.y) > 0.001:
		sy = current_handle_offset.y / _drag_start_handle_offset.y

	# Uniform scale: take the dominant motion direction (signed min) so dragging
	# either axis equally toward/away gives the expected resize. Then clamp at
	# MIN_SCALE so we never collapse to zero or mirror.
	var s: float = minf(sx, sy)
	if s < MIN_SCALE:
		s = MIN_SCALE

	var transform := _build_scale_transform(_scale_center_doc, s)

	var new_prims := AnnotationKind.transform_primitives(
		_drag_start_annotation.get("primitives", []),
		transform
	)
	var new_ann: Dictionary = _drag_start_annotation.duplicate(true)
	new_ann["primitives"] = new_prims
	annotation_modified.emit(_drag_id, new_ann)


func on_pointer_up(_pos: Vector2, button: int, _mods: int) -> bool:
	if not _dragging:
		return false
	if button == MOUSE_BUTTON_LEFT:
		# Finalize: the latest annotation_modified from on_pointer_move is the
		# committed result.
		_reset_state()
		return true
	return false


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

	# 1) Faint bounds outline so the user sees the box being scaled.
	ctx.draw_rect(b, BOUNDS_COLOR, false, 1.0)

	# 2) Filled square handles at each of the four corners.
	var corners := _corner_positions(b)
	var half := HANDLE_SIZE_DOC * 0.5
	for corner_pos in corners:
		var handle_rect := Rect2(
			corner_pos - Vector2(half, half),
			Vector2(HANDLE_SIZE_DOC, HANDLE_SIZE_DOC)
		)
		ctx.draw_rect(handle_rect, HANDLE_COLOR, true, 1.0)


# ── Private helpers ───────────────────────────────────────────────────────────

## Compute the four corner positions of `b` in document space.
## Order matches CORNER_* constants: TL, TR, BL, BR.
##
## CRITICAL: each corner is computed independently from bounds.position +
## per-axis size offsets. Do NOT use bounds.position for all four — that's the
## PCBCanvas top-left bug (docket 019dc65b39fb7d2ca049e951b777ee6b) and unit
## tests assert the four resolve to four DIFFERENT points.
static func _corner_positions(b: Rect2) -> Array:
	var tl := b.position
	var tr := b.position + Vector2(b.size.x, 0.0)
	var bl := b.position + Vector2(0.0, b.size.y)
	var br := b.position + b.size
	return [tl, tr, bl, br]


## Build a uniform-scale transform centered at `center`:
##   T = T(+center) · S(s, s) · T(-center)
static func _build_scale_transform(center: Vector2, s: float) -> Transform2D:
	var t_to_origin := Transform2D(0.0, -center)
	var t_scale := Transform2D(0.0, Vector2.ZERO).scaled(Vector2(s, s))
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


func _reset_state() -> void:
	_dragging = false
	_drag_start_annotation = {}
	_scale_center_doc = Vector2.ZERO
	_drag_start_handle_offset = Vector2.ZERO
	_grabbed_corner = -1
	_drag_id = ""
