class_name AnnotationTranslateTool
extends AnnotationAuthorTool
## Manipulation tool: drag a selected annotation to a new position.
##
## State machine:
##   IDLE → (left-click hits selected annotation) → DRAGGING → (pointer_up) → IDLE
##   DRAGGING → (KEY_ESCAPE) → IDLE (emits annotation_modified with start state to revert)
##   DRAGGING → (on_deactivate) → IDLE (silent, no revert signal)
##
## Emits annotation_modified on every pointer_move while dragging (live preview).
## The last emission before pointer_up is the committed final position.
##
## Hit-test: uses kind.hit_test(ann, doc_pos, _HIT_THRESHOLD). Clicks that miss
## the selected annotation return false so the host can forward to SelectTool or
## its own click handler (re-selection on empty space).
##
## Right-click: always no-op; returns false.
##
## Coordinate path:
##   pos (screen) → host.transform_screen_to_doc(pos) → doc coords
##   delta = current_doc - _drag_start_doc
##   new_prims = AnnotationKind.transform_primitives(start_prims, Transform2D(0.0, delta))

const _HIT_THRESHOLD: float = 8.0

# ── State ─────────────────────────────────────────────────────────────────────

var _host: AnnotationHost = null
var _dragging: bool = false
## Initial pointer position in doc coords when drag started.
var _drag_start_doc: Vector2 = Vector2.ZERO
## Deep-copied snapshot of the annotation dict at drag start.
var _drag_start_annotation: Dictionary = {}
## Id of the annotation being dragged (cached from _drag_start_annotation).
var _drag_id: String = ""


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_dragging = false
	_drag_start_doc = Vector2.ZERO
	_drag_start_annotation = {}
	_drag_id = ""


func on_deactivate() -> void:
	# Silent reset — if a drag was in progress we stop it but do NOT revert and
	# do NOT emit any signal. Per design, deactivation is a clean tool-switch.
	_dragging = false
	_drag_start_doc = Vector2.ZERO
	_drag_start_annotation = {}
	_drag_id = ""
	_host = null


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# Right-click: always no-op; let the host handle it.
	if button == MOUSE_BUTTON_RIGHT:
		return false

	# Escape surfaced via the mods channel (matches arrow / select tool pattern).
	if mods == KEY_ESCAPE:
		if _dragging:
			# Revert by re-emitting the start state.
			annotation_modified.emit(_drag_id, _drag_start_annotation)
			_dragging = false
			_drag_start_doc = Vector2.ZERO
			_drag_start_annotation = {}
			_drag_id = ""
			return true
		return false

	if button != MOUSE_BUTTON_LEFT:
		return false

	if _host == null:
		return false

	# Need an active selection to begin a drag.
	var selected_id := _host.get_selected_annotation_id()
	if selected_id == "":
		return false

	# Find the selected annotation.
	var ann := _find_annotation(selected_id)
	if ann.is_empty():
		return false

	# Hit-test the selected annotation. If the click misses, let the host handle
	# it (e.g. SelectTool deselects or picks another annotation).
	var doc_pos := _host.transform_screen_to_doc(pos)
	var kind := _get_kind(ann)
	if kind == null:
		return false

	if not kind.hit_test(ann, doc_pos, _HIT_THRESHOLD):
		return false

	# Hit confirmed — begin drag.
	_drag_start_doc = doc_pos
	_drag_start_annotation = ann.duplicate(true)
	_drag_id = selected_id
	_dragging = true
	return true


func on_pointer_move(pos: Vector2) -> void:
	if not _dragging or _host == null:
		return

	var current_doc := _host.transform_screen_to_doc(pos)
	var delta := current_doc - _drag_start_doc
	var translation := Transform2D(0.0, delta)

	var new_prims := AnnotationKind.transform_primitives(
		_drag_start_annotation.get("primitives", []),
		translation
	)
	var new_ann: Dictionary = _drag_start_annotation.duplicate(true)
	new_ann["primitives"] = new_prims
	annotation_modified.emit(_drag_id, new_ann)


func on_pointer_up(_pos: Vector2, button: int, _mods: int) -> bool:
	if not _dragging:
		return false
	if button == MOUSE_BUTTON_LEFT:
		# Finalize: the latest annotation_modified from on_pointer_move is the
		# committed result — nothing extra to do here.
		_dragging = false
		_drag_start_doc = Vector2.ZERO
		_drag_start_annotation = {}
		_drag_id = ""
		return true
	return false


# ── Preview ───────────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	# Minimal: draw a faint bounding-rect outline at the current translated
	# position. SelectTool already draws the selection halo from host state; this
	# preview gives the user a frame of the dragged annotation.
	if not _dragging or _host == null:
		return
	# Use the latest translated annotation bounds for the preview rect.
	# We re-read the last emitted state via host (host.update_annotation has
	# already applied it), so just draw a subtle rect from the kind's bounds on
	# the host annotation to avoid redundant re-translation here.
	#
	# Lightweight: get the kind, get the current annotation from host (already
	# updated), draw a faint magenta outline at its bounds.
	var ann := _find_annotation(_drag_id)
	if ann.is_empty():
		return
	var kind := _get_kind(ann)
	if kind == null:
		return
	var b := kind.bounds(ann)
	var preview_color := Color(1.0, 0.2, 0.8, 0.4)
	ctx.draw_rect(b, preview_color, false, 1.5)


# ── Private helpers ───────────────────────────────────────────────────────────

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
