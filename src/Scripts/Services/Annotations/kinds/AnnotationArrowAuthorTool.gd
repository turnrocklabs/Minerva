class_name AnnotationArrowAuthorTool
extends AnnotationAuthorTool
## Authoring tool for the built-in 2d_arrow annotation kind.
##
## Pattern-establishing implementation for per-kind AnnotationAuthorTool
## subclasses (text, region, polyline, etc. should mirror this shape).
##
## Interaction model (click-click, NOT click-drag):
##   1. Click 1 (left button)        → store endpoint A, enter first_click_done.
##   2. Pointer move                 → update preview endpoint B; canvas redraws
##                                     each frame and calls draw_preview() which
##                                     reads the latest preview endpoint.
##   3. Click 2 (left button)        → store endpoint B, build annotation Dict,
##                                     emit annotation_ready, return to idle.
##   4. Right-click or Escape        → emit cancelled, return to idle.
##
## Preview-redraw contract:
##   AnnotationAuthorTool has no "request redraw" method on the host today.
##   The hosting canvas is expected to invalidate per frame in its own
##   _process(delta) → queue_redraw() loop. on_pointer_move() therefore only
##   updates internal state; the next draw_preview() call picks it up.
##
## Tool-switch semantics:
##   Per design, switching tools mid-author is a clean cancel WITHOUT emitting
##   the cancelled signal. The toolbar invokes on_deactivate() and we simply
##   reset state. The "user-aborted" cancelled signal is reserved for explicit
##   right-click / Escape user action. (See test
##   test_switch_tools_mid_author_no_signals.)
##
## Annotation Dict shape (matches AnnotationArrow.render which reads "from"/"to"):
##   {
##     "kind": "2d_arrow",
##     "schema_version": 1,
##     "author": "human",
##     "view_context": "<host.get_view_context()>",
##     "primitives": [{"kind": "arrow", "from": [ax, ay], "to": [bx, by]}]
##   }
## Note: id and created_at are added by the substrate's add_annotation(), not here.

# ── State ─────────────────────────────────────────────────────────────────────

enum State { IDLE, FIRST_CLICK_DONE }

var _state: int = State.IDLE
var _host: AnnotationHost = null

## First clicked point in document space (set when leaving IDLE).
var _a: Vector2 = Vector2.ZERO

## Final clicked point (only assigned briefly during finalize).
var _b: Vector2 = Vector2.ZERO

## Live preview endpoint, updated on every pointer move while
## state == FIRST_CLICK_DONE.
var _b_preview: Vector2 = Vector2.ZERO


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = State.IDLE
	_a = Vector2.ZERO
	_b = Vector2.ZERO
	_b_preview = Vector2.ZERO


func on_deactivate() -> void:
	# Per design: clean reset on tool-switch without emitting cancelled.
	# cancelled is for explicit user-abort (right-click / Escape) only.
	_state = State.IDLE
	_a = Vector2.ZERO
	_b = Vector2.ZERO
	_b_preview = Vector2.ZERO
	_host = null


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# Right-click while authoring → cancel.
	if button == MOUSE_BUTTON_RIGHT:
		if _state == State.FIRST_CLICK_DONE:
			_reset_state()
			cancelled.emit()
			return true
		return false

	# Escape passed via the mods channel (some hosts surface key state this way).
	if mods == KEY_ESCAPE:
		if _state == State.FIRST_CLICK_DONE:
			_reset_state()
			cancelled.emit()
			return true
		return false

	if button != MOUSE_BUTTON_LEFT:
		return false

	if _host == null:
		return false

	var doc_pos := _host.transform_screen_to_doc(pos)

	match _state:
		State.IDLE:
			_a = doc_pos
			_b_preview = doc_pos
			_state = State.FIRST_CLICK_DONE
			return true
		State.FIRST_CLICK_DONE:
			_b = doc_pos
			var annotation := _build_annotation(_a, _b)
			_reset_state()
			annotation_ready.emit(annotation)
			return true

	return false


func on_pointer_move(pos: Vector2) -> void:
	if _state != State.FIRST_CLICK_DONE:
		return
	if _host == null:
		return
	# Preview update only — canvas is expected to queue_redraw() per frame and
	# call draw_preview() which reads _b_preview. See preview-redraw contract
	# at the top of this file.
	_b_preview = _host.transform_screen_to_doc(pos)


func on_pointer_up(_pos: Vector2, _button: int, _mods: int) -> bool:
	# Arrow uses click-click rather than drag — pointer_up is unused.
	return false


# ── Preview ───────────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	if _state != State.FIRST_CLICK_DONE:
		return
	# Faded version of the human author colour.
	var base := AnnotationRenderContext.author_color("human")
	var faded := Color(base.r, base.g, base.b, 0.5)
	ctx.draw_line(_a, _b_preview, faded, 1.0)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _reset_state() -> void:
	_state = State.IDLE
	_a = Vector2.ZERO
	_b = Vector2.ZERO
	_b_preview = Vector2.ZERO


func _build_annotation(a: Vector2, b: Vector2) -> Dictionary:
	# Keys "from"/"to" match what AnnotationArrow.render reads (see
	# AnnotationArrow.gd:_render_arrow). The substrate's add_annotation()
	# assigns id/created_at on accept.
	var view_ctx := ""
	if _host != null:
		view_ctx = _host.get_view_context()
	return {
		"kind":           "2d_arrow",
		"schema_version": 1,
		"author":         "human",
		"view_context":   view_ctx,
		"primitives":     [{
			"kind": "arrow",
			"from": [a.x, a.y],
			"to":   [b.x, b.y],
		}],
	}
