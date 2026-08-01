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
##   - OUTSIDE / no selection → select semantics (hit-test annotations); a press
##     that lands on an annotation ALSO arms a translate drag, so press-drag
##     selects and moves in one gesture (Illustrator/Photoshop feel). See
##     _do_selection for the jitter threshold that keeps a plain click inert.
##
## Selection grammar (A8u1 — matches what the pcb canvas already does for board
## entities, so one habit works on both surfaces):
##   - click              → replace the selection with what was hit
##   - shift-click        → toggle that annotation's membership (no drag armed)
##   - drag on empty      → marquee; every intersecting annotation is selected
##   - shift-drag on empty→ marquee that UNIONS into the existing selection
##   - click on empty     → deselect + `cancelled` (a zero-travel marquee)
##   - Delete             → removes EVERY selected annotation
##
## The gizmo is a SINGLE-selection affordance. With two or more selected the tool
## shows per-member outlines instead of handles and supports rigid translate only
## (drag any member; all move, offsets preserved via per-member snapshots). Scale
## and rotate over a multi-selection are deliberately not offered — no kind
## implements a group transform, so handles would promise something false.
##
## Three multi-selection behaviors are DELIBERATE and reviewed, not oversights:
##   - The marquee sweeps kind.bounds() AABBs while a click uses kind.hit_test(),
##     so a marquee touching only the empty corner of a long diagonal annotation's
##     box still selects it. Standard marquee behavior; no kind-level
##     rect-intersect API exists to do better.
##   - Membership is fixed at drag start. A member the host hides mid-drag (a pcb
##     layer filter flipping) still moves with the group — the substrate has no
##     lock concept, and dropping a member mid-gesture would silently break the
##     rigid-offset guarantee the whole design rests on.
##   - A group drag writes one annotation_modified per member per move, so hosts
##     with per-annotation revision history (pcb route hints) record N entries
##     for one visual move and need N undos to fully reverse it.
##
## This is the ONE manipulation tool. The four single-gesture tools it subsumed
## (select / translate / rotate / scale) were DELETED outright — owner-ratified
## chore 019fb59b34ee — so do not resurrect or re-list them.
##
## Keyboard:
##   - KEY_DELETE     → host.remove_annotation() for every selected id
##   - KEY_ESCAPE     → cancel label edit, else marquee, else revert in-progress
##                      drag, else clear selection
##
## Emits annotation_modified(id, new_dict) only. Never annotation_ready.
##
## ── Visio-style arrow labels (A8u2, item 019fb5de8c81) ────────────────────────
## DOUBLE-CLICK a single-selected 2d_arrow → an in-place LineEdit opens at the
## caption position (AnnotationInPlaceTextEditor, the same widget the 2d_text
## author tool uses). Enter commits, Escape cancels, a click anywhere else on the
## canvas commits — the text tool's grammar verbatim. An EMPTY commit CLEARS the
## caption. A second double-click edits the existing text.
##
## The caption is NOT a second annotation: it lives in the arrow's own
## kind_payload (label / label_offset / label_font_size — see AnnotationArrow) and
## its position is derived from the arrow midpoint, so it rides along whenever an
## endpoint moves. Dragging the caption rect is a SUB-HANDLE of this gizmo that
## writes label_offset and nothing else, off the same immutable
## _drag_start_annotation snapshot every other drag uses.
##
## Both affordances require EXACTLY ONE selection — a caption belongs to one
## arrow, and the multi-selection gizmo is deliberately translate-only. With two
## or more selected the sub-handle is drawn DISABLED (grey) and a double-click
## posts an on-canvas notice instead of opening the editor.
##
## No undo: like every other annotation mutation in this substrate (there is no
## annotation undo stack at all), a label edit or clear is not undoable.

# ── Zone constants — tune here for the polish pass ──────────────────────────
# All sizes are SCREEN pixels; zone math and gizmo drawing divide by the host
# zoom to get document units, so the gizmo stays a constant on-screen size at
# any zoom. (On identity-transform hosts zoom is 1.0 — behavior unchanged. The
# old doc-unit reading made the gizmo zones balloon on mm-unit canvases: a
# 28"mm" rotate ring at PCB zoom 8 was a 224px monster that swallowed the
# translate zone. Same bug class as the arrowhead's zoom² scaling.)

## Corner + edge handle hit zone radius, in screen pixels.
const HANDLE_HIT_RADIUS_DOC: float = 12.0

## Outer radius of rotate-ring annulus from corner, in screen pixels.
const ROTATE_RING_OUTER_DOC: float = 28.0

## Inner radius of rotate-ring annulus (= corner hit zone) so zones don't
## overlap: corner wins if dist < 12; rotate ring wins if 12 ≤ dist ≤ 28.
const ROTATE_RING_INNER_DOC: float = 12.0

## Filled-square gizmo size for corner and edge handles, in screen pixels.
const HANDLE_SIZE_DOC: float = 6.0

## Minimum scale factor — prevents collapsing to zero or mirroring.
const MIN_SCALE: float = 0.05

## Movement, in SCREEN pixels, a select-armed drag must exceed before it emits.
const SELECT_DRAG_THRESHOLD_PX: float = 3.0

# ── Visual constants ──────────────────────────────────────────────────────────

## Cyan corner/edge handle fill (matches ScaleTool convention).
const HANDLE_COLOR: Color         = Color(0.2, 0.7, 1.0)

## Orange rotate-ring / arc color (matches RotateTool convention).
const ROTATE_HANDLE_COLOR: Color  = Color(1.0, 0.5, 0.0)

## Subtle grey bounds outline.
const BOUNDS_COLOR: Color         = Color(0.6, 0.6, 0.6, 0.5)

## In-progress rotation arc tint.
const ARC_COLOR: Color            = Color(1.0, 0.5, 0.0, 0.6)

## Marquee (box-select) stroke + wash. Matches the cyan handle family.
const MARQUEE_COLOR: Color = Color(0.2, 0.7, 1.0, 0.9)
const MARQUEE_FILL: Color  = Color(0.2, 0.7, 1.0, 0.12)

## Per-member outline drawn for every annotation in a multi-selection, in place
## of the single-selection scale/rotate gizmo.
const MULTI_SELECT_COLOR: Color = Color(0.2, 0.7, 1.0, 0.9)

## Arrow-label sub-handle: dashed-looking outline + a small centre grip. Grey
## when disabled (multi-selection) so the affordance is visibly present but off.
const LABEL_HANDLE_COLOR: Color = Color(0.2, 0.7, 1.0, 0.75)
const LABEL_HANDLE_DISABLED_COLOR: Color = Color(0.6, 0.6, 0.6, 0.55)
const LABEL_NOTICE_COLOR: Color = Color(1.0, 0.5, 0.0, 0.95)
const LABEL_NOTICE_TEXT: String = "Select one arrow to edit its label"
const LABEL_NOTICE_FONT_PX: int = 13
const LABEL_GRIP_SIZE_PX: float = 5.0
## Slack, in screen px, added to the caption rect when hit-testing the handle.
const LABEL_HANDLE_SLACK_PX: float = 2.0

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
	## Arrow-label sub-handle (A8u2). Never returned by _hit_zone — the caption
	## rect can sit outside the bounds gizmo entirely, so it is tested first, in
	## on_pointer_down, against the kind's own label_rect.
	LABEL,
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

## True while a translate drag armed by the select-on-press path is still below
## the movement threshold. Such a drag emits nothing until the pointer travels
## far enough to be an intentional move, so a plain click that merely selects
## never writes a jittered position back to the host. Cleared once exceeded.
var _translate_pending_threshold: bool = false

# ── Multi-selection state (A8u1) ─────────────────────────────────────────────

## Immutable drag-start snapshots for the NON-primary members of a multi-selection,
## keyed by id. Empty for every single-selection drag, so the single-select code
## path below is byte-identical to pre-A8u1. Populated only for translate.
var _extra_drag_snapshots: Dictionary = {}

## Marquee (box-select) state. Armed on a left press that hits neither the gizmo
## nor an annotation; the press does NOT deselect or cancel yet, because that is
## exactly where a box-select gesture starts. The decision is deferred to release:
## zero travel replays the old empty-click semantics, real travel is a marquee.
var _marquee_active: bool = false
var _marquee_start_doc: Vector2 = Vector2.ZERO
var _marquee_current_doc: Vector2 = Vector2.ZERO

## Shift held at marquee press — the marquee unions with the existing selection
## instead of replacing it.
var _marquee_additive: bool = false
var _marquee_base_ids: PackedStringArray = PackedStringArray()

# ── Arrow-label editing state (A8u2) ─────────────────────────────────────────

## Shared in-place LineEdit, factored out of AnnotationTextAuthorTool so both
## tools drive one widget. Null surface (headless) simply never opens.
var _editor: AnnotationInPlaceTextEditor = AnnotationInPlaceTextEditor.new()

## Id of the annotation whose caption is being edited; "" when idle.
var _label_edit_id: String = ""

## Document point the editor is CENTRED on — the derived label position
## (midpoint + offset), i.e. exactly where the committed caption will centre.
## Re-applied on every redraw so the entry tracks pan/zoom like the text tool's,
## and the widget re-splits itself around it as the text grows, so nothing jumps
## sideways on commit.
var _label_edit_centre: Vector2 = Vector2.ZERO

## Glyph size (doc units) FROZEN when the editor opened. Zooming mid-edit must
## rescale the view without changing what gets committed — the same contract
## AnnotationTextAuthorTool's _authored_font_size has.
var _label_edit_font: float = float(AnnotationInPlaceTextEditor.TARGET_SCREEN_FONT_PX)

## Caption offset at label-drag start — the immutable value the drag deltas from.
var _drag_start_label_offset: Vector2 = Vector2.ZERO

## Document point at which to post the "select one arrow" notice, or null.
## Set when a double-click is refused because the selection is not exactly one.
var _label_notice_doc: Variant = null


func _init() -> void:
	_editor.submitted.connect(_on_label_editor_submitted)
	_editor.aborted.connect(_on_label_editor_aborted)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_reset_drag_state()
	_reset_marquee()
	_reset_label_edit()


func on_deactivate() -> void:
	# Silent reset — no revert, no signal. Clean tool-switch.
	_reset_drag_state()
	_reset_marquee()
	_reset_label_edit()
	_host = null


## Duck-typed hook from AnnotationOverlay.set_active_tool(): the Control the
## in-place caption editor is parented to (null hands it back). Same contract as
## AnnotationTextAuthorTool's.
func attach_edit_surface(parent: Control) -> void:
	_editor.set_surface(parent)
	if parent == null:
		_label_edit_id = ""


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
	_translate_pending_threshold = false
	_extra_drag_snapshots = {}
	_drag_start_label_offset = Vector2.ZERO


## Tear down the caption editor without committing anything.
func _reset_label_edit() -> void:
	_editor.discard()
	_label_edit_id = ""
	_label_edit_centre = Vector2.ZERO
	_label_edit_font = float(AnnotationInPlaceTextEditor.TARGET_SCREEN_FONT_PX)
	_label_notice_doc = null


func _reset_marquee() -> void:
	_marquee_active = false
	_marquee_start_doc = Vector2.ZERO
	_marquee_current_doc = Vector2.ZERO
	_marquee_additive = false
	_marquee_base_ids = PackedStringArray()


## Every currently-selected id, primary included. See AnnotationHost.selected_ids_for
## for the single-id fallback this shares with the overlay and the dock panes.
func _selected_ids() -> PackedStringArray:
	return AnnotationHost.selected_ids_for(_host)


func _set_selected_ids(ids: PackedStringArray, primary: String = "") -> void:
	if _host == null:
		return
	if _host.has_method("set_selected_annotation_ids"):
		_host.set_selected_annotation_ids(ids, primary)
		return
	# Legacy host: collapse to the primary, which is the old behavior.
	var fallback := primary
	if fallback.is_empty() and ids.size() > 0:
		fallback = ids[ids.size() - 1]
	_host.set_selected_annotation_id(fallback)


func _toggle_selected_id(annotation_id: String) -> void:
	if _host == null:
		return
	if _host.has_method("toggle_selected_annotation_id"):
		_host.toggle_selected_annotation_id(annotation_id)
		return
	var sel := _host.get_selected_annotation_id()
	_host.set_selected_annotation_id("" if sel == annotation_id else annotation_id)


## Screen-pixels-per-document-unit from the host (1.0 for identity hosts).
## Zone radii and gizmo sizes are screen px; dividing by this yields doc units.
func _view_zoom() -> float:
	if _host != null and _host.has_method("get_annotation_zoom"):
		return maxf(float(_host.get_annotation_zoom()), 0.01)
	return 1.0


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	if _host == null:
		return false

	# Right-click: let host handle — except that it aborts a caption edit first,
	# which is the text tool's "right-click is an explicit abort" rule.
	if button == MOUSE_BUTTON_RIGHT:
		if _editor.is_open():
			_reset_label_edit()
			return true
		return false

	# A live caption editor owns the keyboard grammar first. These pseudo-key
	# pointer-downs only arrive while the OVERLAY holds focus; when the LineEdit
	# itself is focused its own gui_input handles Enter/Escape. Both paths exist
	# for the same reason the text tool keeps both.
	if _editor.is_open():
		if mods == KEY_ESCAPE:
			_reset_label_edit()
			return true
		if mods == KEY_ENTER:
			_commit_label_edit()
			return true
		if mods == KEY_DELETE:
			# Never delete annotations out from under an open editor.
			return true
	elif mods == KEY_ENTER:
		# No editor open: Enter is not ours. Returning false matters — falling
		# through would run the selection path below against the overlay's
		# Vector2.ZERO pseudo-position and arm a marquee at the origin.
		return false

	# DELETE: remove EVERY selected annotation (A8u1). Single-selection is the
	# same one remove_annotation() call as before.
	if mods == KEY_DELETE:
		# `doomed` is the getter's own duplicate, so it survives the collapse the
		# host triggers when remove_annotation() clears the primary underneath us.
		var doomed := _selected_ids()
		if doomed.size() > 0:
			for id in doomed:
				_host.remove_annotation(id)
			_set_selected_ids(PackedStringArray())
			_reset_drag_state()
			_reset_marquee()
		# Always consume.
		return true

	# ESCAPE: cancel a marquee, else revert drag, else clear selection.
	if mods == KEY_ESCAPE:
		if _marquee_active:
			_reset_marquee()
			return true
		if _dragging:
			_revert_drag()
			return true
		# Idle escape — clear selection (mirrors SelectTool).
		_set_selected_ids(PackedStringArray())
		return true

	if button != MOUSE_BUTTON_LEFT:
		return false

	# Clicking anywhere else on the canvas COMMITS an open caption edit (the text
	# tool's grammar). Clicks that land inside the LineEdit never reach us — it is
	# a child Control on top of the overlay — so anything arriving here is
	# genuinely "elsewhere". The click then continues into normal selection
	# handling, so one gesture commits and selects.
	if _editor.is_open():
		_commit_label_edit()

	# Any real click clears a stale multi-selection notice.
	_label_notice_doc = null

	var doc_pos := _host.transform_screen_to_doc(pos)
	# mods carries a modifier MASK here; the KEY_DELETE / KEY_ESCAPE pseudo-events
	# above are exact-value comparisons, so they can never reach this test.
	var additive := (mods & KEY_MASK_SHIFT) != 0
	var selected_ids := _selected_ids()
	var selected_id := _host.get_selected_annotation_id()

	# ── Shift always means "edit set membership" ─────────────────────────────────
	# Checked before the gizmo so shift-clicking a selected annotation removes it
	# rather than starting a drag (Illustrator).
	if additive:
		return _do_selection(doc_pos, true)

	# ── Multi-selection: press on ANY member drags the whole set rigidly ────────
	# The per-annotation scale/rotate gizmo is intentionally not shown for a
	# multi-selection (see draw_preview), so only the translate gesture applies.
	if selected_ids.size() > 1:
		var hit_id := _hit_test_topmost(doc_pos)
		if hit_id != "" and selected_ids.has(hit_id):
			return _begin_multi_drag(doc_pos, selected_ids, hit_id)
		# Missed every member — fall through to select / marquee semantics.

	# ── Single selection: try to hit-test the gizmo zones ───────────────────────
	elif selected_id != "":
		var ann := _find_annotation(selected_id)
		if not ann.is_empty():
			# Arrow-label sub-handle wins over every gizmo zone: the caption rect
			# usually sits inside the bounds box, so testing it after INSIDE would
			# make it unreachable.
			if _hit_label_handle(ann, doc_pos):
				return _begin_label_drag(doc_pos, selected_id, ann)
			var kind := _get_kind(ann)
			if kind != null:
				var b: Rect2 = kind.bounds(ann)
				var zone := _hit_zone(doc_pos, b, _view_zoom())
				if zone != Zone.OUTSIDE:
					return _begin_drag(zone, doc_pos, selected_id, ann, b)
				# Click was outside the gizmo entirely — fall through to
				# SelectTool semantics so user can click a different annotation.

	# ── No active gizmo hit: SelectTool semantics ────────────────────────────────
	return _do_selection(doc_pos, false)


func on_pointer_move(pos: Vector2) -> void:
	if _host == null:
		return

	# Marquee gets its own move path — the drag guard below early-returns for
	# every non-drag gesture, which is precisely why a box-select needs one.
	if _marquee_active:
		_marquee_current_doc = _host.transform_screen_to_doc(pos)
		return

	if not _dragging:
		return

	var doc_pos := _host.transform_screen_to_doc(pos)

	match _active_zone:
		Zone.LABEL:
			_apply_label_drag(doc_pos)
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
	if _marquee_active:
		if button != MOUSE_BUTTON_LEFT:
			return false
		return _commit_marquee()
	if not _dragging:
		return false
	if button == MOUSE_BUTTON_LEFT:
		_reset_drag_state()
		return true
	return false


# ── Arrow labels: double-click to edit (A8u2) ────────────────────────────────

## Duck-typed hook called by AnnotationOverlay._gui_input for a LEFT double-click
## (see the forwarding comment there). Returning false means "not mine" and the
## overlay hands the same press to on_pointer_down as usual, which is what keeps
## a double-click behaving like an ordinary second click everywhere else.
##
## Godot delivers the second press of a double-click as a single event with
## double_click = true, so consuming it here is exactly one press-worth of input;
## the FIRST press already ran the ordinary select path, which is why the arrow
## is reliably single-selected by the time we get here.
func on_pointer_double_click(pos: Vector2, button: int, _mods: int) -> bool:
	if _host == null or button != MOUSE_BUTTON_LEFT:
		return false

	var doc_pos := _host.transform_screen_to_doc(pos)
	var ids := _selected_ids()

	# A caption belongs to exactly one arrow. With a multi-selection the editor
	# stays shut and the canvas says why (the U1 disarm rule: the affordance is
	# visibly present but off — see draw_preview's greyed sub-handle).
	if ids.size() > 1:
		if _hit_test_topmost(doc_pos) != "":
			_label_notice_doc = doc_pos
			return true
		return false

	var target_id := _host.get_selected_annotation_id()
	if target_id.is_empty() or _hit_test_topmost(doc_pos) != target_id:
		return false

	var ann := _find_annotation(target_id)
	var arrow := _arrow_kind(ann)
	if arrow == null:
		return false
	return _begin_label_edit(target_id, ann, arrow)


## Open the in-place editor on `ann`'s caption. Returns false when there is no
## surface (headless) or the arrow has no resolvable segment to hang a label off.
func _begin_label_edit(ann_id: String, ann: Dictionary, arrow: AnnotationArrow) -> bool:
	var zoom := _view_zoom()
	# A caption with no stored size is being authored now, so it gets the same
	# screen-constant sizing a fresh 2d_text does; an existing one keeps its own.
	var doc_font: float = arrow.label_font_size(ann) if arrow.has_label(ann) \
		else AnnotationInPlaceTextEditor.authored_font_size(zoom)
	var offset: Vector2 = arrow.label_offset(ann) if arrow.has_label(ann) \
		else AnnotationArrow.default_label_offset(doc_font)
	var mid: Variant = arrow.label_midpoint(ann)
	if not mid is Vector2:
		return false

	# A caption edit is not a transform — drop anything else in flight first.
	_reset_drag_state()
	_reset_marquee()
	_label_notice_doc = null

	# Freeze the size, and CENTRE the widget on the point the committed caption
	# will centre on — the editor re-splits itself around it as the text grows,
	# so what is typed sits exactly where it lands on Enter.
	_label_edit_font = doc_font
	_label_edit_centre = (mid as Vector2) + offset
	var text := arrow.label_text(ann)

	if not _editor.open(_host.transform_doc_to_screen(_label_edit_centre), zoom, doc_font,
			text, "Label…", AnnotationRenderContext.author_color("human"), true):
		_label_edit_id = ""
		return false
	_label_edit_id = ann_id
	return true


## Enter inside the widget: write the caption back. An EMPTY commit CLEARS the
## label (AnnotationArrow.with_label erases all three keys). Not undoable — the
## annotation substrate has no undo stack.
func _commit_label_edit() -> void:
	if not _editor.is_open() or _label_edit_id.is_empty():
		_reset_label_edit()
		return
	var text := _editor.get_text()
	var ann := _find_annotation(_label_edit_id)
	var arrow := _arrow_kind(ann)
	if arrow == null:
		_reset_label_edit()
		return
	# Clearing a caption that never existed is not an edit. Emitting here would
	# make the host full-replace the annotation, dirty the sidecar and bump its
	# revision for a double-click the user simply clicked away from.
	if text.strip_edges().is_empty() and not arrow.has_label(ann):
		_reset_label_edit()
		return
	# The size the user was LOOKING AT, frozen at open — not re-derived from a
	# zoom that may have changed mid-edit.
	var seed_font := _label_edit_font
	var updated := arrow.with_label(ann, text, AnnotationArrow.default_label_offset(seed_font), seed_font)
	var target_id := _label_edit_id
	_reset_label_edit()
	annotation_modified.emit(target_id, updated)


func _on_label_editor_submitted(_text: String) -> void:
	_commit_label_edit()


## Escape inside the widget: close without writing anything back.
func _on_label_editor_aborted() -> void:
	_reset_label_edit()


## The 2d_arrow kind for `ann`, or null when it is not an arrow.
func _arrow_kind(ann: Dictionary) -> AnnotationArrow:
	if ann.is_empty():
		return null
	var kind := _get_kind(ann)
	return kind as AnnotationArrow


## Caption rect of `ann` in document space, or null (not an arrow / no caption).
func _label_rect(ann: Dictionary) -> Variant:
	var arrow := _arrow_kind(ann)
	if arrow == null:
		return null
	return arrow.label_rect(ann)


func _hit_label_handle(ann: Dictionary, doc_pos: Vector2) -> bool:
	var r: Variant = _label_rect(ann)
	if not r is Rect2:
		return false
	return (r as Rect2).grow(LABEL_HANDLE_SLACK_PX / _view_zoom()).has_point(doc_pos)


func _begin_label_drag(doc_pos: Vector2, ann_id: String, ann: Dictionary) -> bool:
	var arrow := _arrow_kind(ann)
	if arrow == null:
		return false
	_begin_drag(Zone.LABEL, doc_pos, ann_id, ann, Rect2())
	_drag_start_label_offset = arrow.label_offset(ann)
	# Same jitter gate every select-armed drag uses: a press on the caption that
	# never travels must write nothing, because the very next event may be the
	# second half of a double-click asking to EDIT the caption, not move it.
	_translate_pending_threshold = true
	return true


## Caption drag: writes label_offset and NOTHING else, off the immutable
## drag-start snapshot (so the offset is absolute-from-snapshot, never
## cumulative). Endpoints, text, and glyph size are untouched by construction —
## AnnotationArrow.with_label_offset only ever sets the one key.
func _apply_label_drag(doc_pos: Vector2) -> void:
	if _drag_start_annotation.is_empty():
		return
	var arrow := _arrow_kind(_drag_start_annotation)
	if arrow == null:
		return
	var delta := doc_pos - _drag_start_doc
	if _translate_pending_threshold:
		if delta.length() * _view_zoom() < SELECT_DRAG_THRESHOLD_PX:
			return
		_translate_pending_threshold = false
	annotation_modified.emit(_drag_id, arrow.with_label_offset(_drag_start_annotation, _drag_start_label_offset + delta))


## Resolve an armed marquee at release.
##
## Zero travel (below SELECT_DRAG_THRESHOLD_PX, the same threshold the
## select-armed translate uses) is not a box-select — it is the plain empty
## click, and it replays the pre-A8u1 semantics exactly: clear the selection,
## reset, emit `cancelled` so the toolbar untoggles and the overlay's
## mouse_filter flips back to IGNORE, restoring the SubViewport's camera orbit.
## The ONLY change is timing — press-time before, release-time now, because the
## press is where a box-select must begin.
func _commit_marquee() -> bool:
	var start := _marquee_start_doc
	var current := _marquee_current_doc
	var travel_px := (current - start).length() * _view_zoom()
	var additive := _marquee_additive
	var base_ids := _marquee_base_ids
	_reset_marquee()

	if travel_px < SELECT_DRAG_THRESHOLD_PX:
		if additive:
			# A SHIFT-click that missed everything. In Illustrator that is a
			# no-op — it must not clear the set the user has been building, and
			# it must not emit `cancelled` (which would untoggle the toolbar and
			# flip the overlay back to IGNORE mid-gesture). Nothing between the
			# press and here touched the selection, so leaving it alone is both
			# the correct result and the one that emits no spurious signals.
			_reset_drag_state()
			return true
		# Plain click on empty space — the pre-A8u1 semantics, verbatim.
		_set_selected_ids(PackedStringArray())
		_reset_drag_state()
		cancelled.emit()
		return true

	var rect := Rect2(start, Vector2.ZERO).expand(current)
	var picked := _annotations_intersecting(rect)

	var result := PackedStringArray()
	if additive:
		result = base_ids.duplicate()
	for id in picked:
		if not result.has(id):
			result.append(id)

	# Primary = topmost annotation the marquee swept (last in document order).
	var primary := picked[picked.size() - 1] if picked.size() > 0 else ""
	if result.is_empty():
		# An empty marquee over blank space still means "deselect", but it is a
		# deliberate gesture, not an accidental click — do NOT emit `cancelled`
		# (that would rip the tool out from under the user mid-gesture).
		_set_selected_ids(PackedStringArray())
		_reset_drag_state()
		return true

	_set_selected_ids(result, primary)
	_reset_drag_state()
	return true


## Ids of every visible annotation whose kind bounds intersect `rect`, in
## document order (bottom-most first). Zero-area bounds (a bare point anchor)
## are matched by containment so point-like annotations are still sweepable.
func _annotations_intersecting(rect: Rect2) -> PackedStringArray:
	var out := PackedStringArray()
	if _host == null:
		return out
	var registry := _host.get_registry()
	for ann_v in _host.get_annotations():
		if not ann_v is Dictionary:
			continue
		var ann: Dictionary = ann_v
		# Same host visibility veto the click hit-test honors (WC-2 C3): a
		# filtered-out annotation is not sweepable either.
		if not _host.is_annotation_visible(ann):
			continue
		if registry == null:
			continue
		var kind: AnnotationKind = registry.get_annotation_kind(StringName(ann.get("kind", "")))
		if kind == null:
			continue
		var b: Rect2 = kind.bounds(ann)
		var hit := false
		if b.size.x <= 0.0 or b.size.y <= 0.0:
			hit = rect.has_point(b.position) or rect.has_point(b.position + b.size)
		else:
			hit = rect.intersects(b, true)
		if hit:
			var id := str(ann.get("id", ""))
			if not id.is_empty():
				out.append(id)
	return out


# ── Zone hit-test ─────────────────────────────────────────────────────────────

## Classify a document-space point against the bounding-box gizmo of `b`.
## Priority (highest first):
##   1. CORNER_* (dist from corner < HANDLE_HIT_RADIUS_DOC)
##   2. ROTATE_* (dist from corner in [ROTATE_RING_INNER_DOC, ROTATE_RING_OUTER_DOC])
##   3. EDGE_*   (dist from edge midpoint ≤ HANDLE_HIT_RADIUS_DOC AND not within
##                HANDLE_HIT_RADIUS_DOC of any corner)
##   4. INSIDE   (b.has_point(doc_pos))
##   5. OUTSIDE
static func _hit_zone(doc_pos: Vector2, b: Rect2, zoom: float = 1.0) -> Zone:
	# Zone radii are screen px; divide by zoom for doc units so the gizmo's
	# clickable areas are a constant on-screen size at any zoom.
	var z := maxf(zoom, 0.01)
	var handle_r := HANDLE_HIT_RADIUS_DOC / z
	var ring_inner := ROTATE_RING_INNER_DOC / z
	var ring_outer := ROTATE_RING_OUTER_DOC / z

	var corners := _corner_positions(b)
	# corners order: TL=0, TR=1, BL=2, BR=3
	var corner_zones: Array = [Zone.CORNER_TL, Zone.CORNER_TR, Zone.CORNER_BL, Zone.CORNER_BR]
	var rotate_zones: Array = [Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR]

	# 1. CORNER check
	for i in corners.size():
		var dist := doc_pos.distance_to(corners[i])
		if dist < handle_r:
			return corner_zones[i]

	# Compact annotations such as short text labels can be smaller than the
	# combined edge/rotate hit zones. Preserve a usable translate target inside
	# the bounds; exact corner handles still win above.
	var inside_bounds := b.has_point(doc_pos)
	var compact_bounds := b.size.x <= handle_r * 2.5 or b.size.y <= handle_r * 2.5
	if inside_bounds and compact_bounds:
		return Zone.INSIDE

	# 2. ROTATE ring check (annulus around each corner)
	for i in corners.size():
		var dist := doc_pos.distance_to(corners[i])
		if dist >= ring_inner and dist <= ring_outer:
			return rotate_zones[i]

	# 3. EDGE midpoint check — guard: must not be within corner hit radius of any corner
	var edge_midpoints := _edge_midpoints(b)
	# edge order: T=0, B=1, L=2, R=3
	var edge_zones: Array = [Zone.EDGE_T, Zone.EDGE_B, Zone.EDGE_L, Zone.EDGE_R]
	for i in edge_midpoints.size():
		var mid: Vector2 = edge_midpoints[i]
		if doc_pos.distance_to(mid) <= handle_r:
			# Guard: must not be within corner hit radius of any corner
			var near_corner := false
			for corner in corners:
				if doc_pos.distance_to(corner) < handle_r:
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
	# Single-annotation drag by default; _begin_multi_drag repopulates this
	# immediately after calling us.
	_extra_drag_snapshots = {}
	var center := b.get_center()

	match zone:
		Zone.INSIDE, Zone.LABEL:
			# LABEL deltas from the press point exactly like a translate does;
			# what differs is only which payload key the delta lands in.
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
	# Select-armed drags stay silent until the pointer has clearly moved, so a
	# click that only selects can't nudge the annotation by a pixel of hand
	# jitter. Drags started from the INSIDE gizmo zone (the user already had a
	# selection and deliberately grabbed it) are unthresholded, as before.
	if _translate_pending_threshold:
		if delta.length() * _view_zoom() < SELECT_DRAG_THRESHOLD_PX:
			return
		_translate_pending_threshold = false
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
	annotation_modified.emit(_drag_id, _transformed(_drag_start_annotation, transform, operation))

	# Multi-selection rigid move: the SAME transform applied to each member's own
	# immutable snapshot. Only ever populated for translate (multi-selection
	# suppresses the scale/rotate gizmo), but the math is transform-agnostic.
	for id in _extra_drag_snapshots.keys():
		var snapshot: Dictionary = _extra_drag_snapshots[id]
		annotation_modified.emit(str(id), _transformed(snapshot, transform, operation))


## Apply `transform` to one immutable snapshot, via the kind when it has an
## opinion and the primitive fallback when it does not.
func _transformed(snapshot: Dictionary, transform: Transform2D, operation: String) -> Dictionary:
	var kind := _get_kind(snapshot)
	if kind != null:
		return kind.transform_annotation(snapshot, transform, operation)
	var out := snapshot.duplicate(true)
	var prims: Variant = out.get("primitives", [])
	if prims is Array:
		out["primitives"] = AnnotationKind.transform_primitives(prims as Array, transform)
	return out


func _revert_drag() -> void:
	# A select-armed drag still below its movement threshold has emitted nothing,
	# so there is nothing to revert — skip the pointless write back to the host.
	if _translate_pending_threshold:
		_reset_drag_state()
		return
	if _drag_id != "" and not _drag_start_annotation.is_empty():
		annotation_modified.emit(_drag_id, _drag_start_annotation.duplicate(true))
		for id in _extra_drag_snapshots.keys():
			annotation_modified.emit(str(id), (_extra_drag_snapshots[id] as Dictionary).duplicate(true))
	_reset_drag_state()


# ── Select semantics ──────────────────────────────────────────────────────────

## Hit-test the topmost annotation and apply Illustrator selection grammar.
## Returns true (always consumes the click).
##
## `additive` (shift held) TOGGLES membership instead of replacing the selection.
##
## On a plain hit this also ARMS a translate drag on the freshly-selected
## annotation, which is what makes the tool feel like Illustrator's arrow:
## press-and-drag on anything moves it, with no separate "now switch to the move
## tool" step. The drag is armed with _translate_pending_threshold so a press that
## never travels SELECT_DRAG_THRESHOLD_PX emits nothing — a plain click remains
## pure selection.
##
## A press on EMPTY space arms a marquee and decides nothing yet — see
## _commit_marquee, which owns the deselect + `cancelled` behavior this function
## used to perform at press time.
func _do_selection(doc_pos: Vector2, additive: bool = false) -> bool:
	var hit_id := _hit_test_topmost(doc_pos)

	if not hit_id.is_empty():
		if additive:
			# Shift-click toggles membership only. No translate is armed: a
			# gesture that both changes the set AND moves what it just touched
			# is the one thing Illustrator does not do here.
			_toggle_selected_id(hit_id)
			_reset_drag_state()
			return true
		var ann := _find_annotation(hit_id)
		var kind := _get_kind(ann)
		# Plain click replaces the selection with this one — pre-A8u1 semantics.
		_set_selected_ids(PackedStringArray([hit_id]), hit_id)
		# Arm a threshold-gated translate so the same gesture can move it.
		if kind != null:
			_begin_drag(Zone.INSIDE, doc_pos, hit_id, ann, kind.bounds(ann))
			_translate_pending_threshold = true
		return true

	if additive:
		# Shift on empty space is a no-op on the set, but still arms an additive
		# marquee so shift-drag unions into the existing selection.
		_arm_marquee(doc_pos, true)
		return true

	# No hit — ARM A MARQUEE rather than deciding anything now. The old
	# clear-selection + `cancelled` path (which deactivates the tool so the
	# overlay's mouse_filter flips back to IGNORE and the underlying SubViewport
	# regains camera orbit) still runs, but from _commit_marquee() on a
	# zero-travel release. Cancelling here would make box-select impossible:
	# every marquee starts on empty space.
	_arm_marquee(doc_pos, false)
	return true


## Topmost (last-drawn) visible annotation under doc_pos, or "" for none.
func _hit_test_topmost(doc_pos: Vector2) -> String:
	if _host == null:
		return ""
	var registry := _host.get_registry()
	var annotations: Array = _host.get_annotations()
	# 8 screen px of slack, converted to doc units for kind.hit_test.
	var hit_threshold := 8.0 / _view_zoom()

	for i in range(annotations.size() - 1, -1, -1):
		var ann_v: Variant = annotations[i]
		if not ann_v is Dictionary:
			continue
		var ann: Dictionary = ann_v
		# Host visibility veto (WC-2 C3): a hidden annotation (e.g. a route
		# hint on a filtered-out copper layer) is not hit-testable.
		if not _host.is_annotation_visible(ann):
			continue
		var kind: AnnotationKind = null
		if registry != null:
			kind = registry.get_annotation_kind(StringName(ann.get("kind", "")))
		if kind == null:
			continue
		if kind.hit_test(ann, doc_pos, hit_threshold):
			return str(ann.get("id", ""))
	return ""


func _arm_marquee(doc_pos: Vector2, additive: bool) -> void:
	_reset_drag_state()
	_marquee_active = true
	_marquee_start_doc = doc_pos
	_marquee_current_doc = doc_pos
	_marquee_additive = additive
	_marquee_base_ids = _selected_ids() if additive else PackedStringArray()


## Arm a rigid translate of every member of a multi-selection. Each member gets
## its OWN immutable drag-start snapshot, so applying one shared delta to all of
## them preserves their relative offsets by construction — no group-bounds math,
## and no dependence on the cumulative-origin behavior of transform_annotation.
func _begin_multi_drag(doc_pos: Vector2, ids: PackedStringArray, hit_id: String) -> bool:
	var primary_ann := _find_annotation(hit_id)
	var primary_kind := _get_kind(primary_ann)
	if primary_ann.is_empty() or primary_kind == null:
		return _do_selection(doc_pos, false)
	_begin_drag(Zone.INSIDE, doc_pos, hit_id, primary_ann, primary_kind.bounds(primary_ann))
	# Threshold-gated: a plain click on a member must leave the set untouched and
	# write nothing, exactly like a plain click on a single selection.
	_translate_pending_threshold = true
	_extra_drag_snapshots = {}
	for id in ids:
		if id == hit_id:
			continue
		var ann := _find_annotation(id)
		if not ann.is_empty():
			_extra_drag_snapshots[id] = ann.duplicate(true)
	return true


# ── Preview ───────────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	if _host == null:
		return

	# Keep the caption editor pinned to its document point and sized to the
	# current zoom. draw_preview is the natural place for this because the overlay
	# redraws on every view change (same idiom as AnnotationTextAuthorTool).
	if _editor.is_open():
		_editor.place(ctx.to_screen(_label_edit_centre), ctx.zoom)

	# Refused-double-click notice (multi-selection). Cleared by the next click.
	if _label_notice_doc is Vector2:
		ctx.draw_string(null, _label_notice_doc as Vector2, LABEL_NOTICE_TEXT,
			LABEL_NOTICE_COLOR, LABEL_NOTICE_FONT_PX)

	# Marquee is drawn regardless of what is (or is not) selected.
	if _marquee_active:
		var m := Rect2(_marquee_start_doc, Vector2.ZERO).expand(_marquee_current_doc)
		ctx.draw_rect(m, MARQUEE_FILL, true, 1.0)
		ctx.draw_rect(m, MARQUEE_COLOR, false, 1.0)

	var ids := _selected_ids()

	# ── Multi-selection: outline every member, no scale/rotate gizmo ────────────
	# A bounding-box gizmo drawn around one arbitrary member (or around the union,
	# with per-member scale that no kind implements) would be a lie about what the
	# handles do. Multi-selection therefore supports rigid translate only, and
	# says so visually by showing outlines instead of handles.
	if ids.size() > 1:
		var gzm := maxf(ctx.zoom, 0.01)
		for id in ids:
			var member := _find_annotation(id)
			if member.is_empty():
				continue
			var member_kind := _get_kind(member)
			if member_kind == null:
				continue
			var mb: Rect2 = member_kind.bounds(member)
			ctx.draw_rect(mb.grow(2.0 / gzm), MULTI_SELECT_COLOR, false, 1.0)
			# Caption sub-handles are drawn DISABLED over a multi-selection: the
			# affordance stays visible so nothing looks missing, and its grey says
			# it is off. Same "handles absent/disabled means disarmed" grammar the
			# multi-select gizmo already uses for scale and rotate.
			_draw_label_handle(ctx, member, false)
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

	# Gizmo sizes are screen px; geometry below is doc units and ctx applies
	# the doc→screen transform, so divide by zoom for a constant on-screen
	# gizmo (mirrors _hit_zone so visuals match the clickable areas).
	var gz := maxf(ctx.zoom, 0.01)
	var handle_size := HANDLE_SIZE_DOC / gz

	# 1) Faint bounds outline.
	ctx.draw_rect(b, BOUNDS_COLOR, false, 1.0)

	# 2) Corner handles (filled squares).
	var half := handle_size * 0.5
	for corner_pos in _corner_positions(b):
		var r := Rect2(corner_pos - Vector2(half, half), Vector2(handle_size, handle_size))
		ctx.draw_rect(r, HANDLE_COLOR, true, 1.0)

	# 3) Edge midpoint handles (filled squares, same style).
	for mid_pos in _edge_midpoints(b):
		var r := Rect2(mid_pos - Vector2(half, half), Vector2(handle_size, handle_size))
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
		var ring_pos: Vector2 = corners[i] + offset_dir * ((ROTATE_RING_INNER_DOC + ROTATE_RING_OUTER_DOC) * 0.5 / gz)
		_draw_filled_disc(ctx, ring_pos, ROTATE_DISC_RADIUS / gz, ROTATE_HANDLE_COLOR)

	# 5) In-progress rotation arc.
	if _dragging and _active_zone in [Zone.ROTATE_TL, Zone.ROTATE_TR, Zone.ROTATE_BL, Zone.ROTATE_BR]:
		_draw_angle_arc(ctx, _rotation_center_doc, _drag_start_angle_rad, _current_angle_rad)

	# 6) Arrow-label sub-handle (single selection → armed).
	_draw_label_handle(ctx, ann, true)


## Outline + centre grip over an arrow's caption, marking it as draggable.
## Draws nothing when `ann` is not a labelled arrow.
func _draw_label_handle(ctx: AnnotationRenderContext, ann: Dictionary, armed: bool) -> void:
	var r: Variant = _label_rect(ann)
	if not r is Rect2:
		return
	var rect: Rect2 = r
	var z := maxf(ctx.zoom, 0.01)
	var color := LABEL_HANDLE_COLOR if armed else LABEL_HANDLE_DISABLED_COLOR
	ctx.draw_rect(rect.grow(LABEL_HANDLE_SLACK_PX / z), color, false, 1.0)
	var grip := LABEL_GRIP_SIZE_PX / z
	var centre := rect.get_center()
	ctx.draw_rect(Rect2(centre - Vector2(grip, grip) * 0.5, Vector2(grip, grip)), color, true, 1.0)


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
	# Screen-px ring radius → doc units (matches the ring discs in draw_preview).
	var radius := (ROTATE_RING_INNER_DOC + ROTATE_RING_OUTER_DOC) * 0.5 / maxf(ctx.zoom, 0.01)
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
