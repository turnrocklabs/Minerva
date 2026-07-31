class_name AnnotationArrowAuthorTool
extends AnnotationAuthorTool
## Authoring tool for the built-in 2d_arrow annotation kind.
##
## Pattern-establishing implementation for per-kind AnnotationAuthorTool
## subclasses (text, region, polyline, etc. should mirror this shape).
##
## Interaction model (click-click, NOT click-drag), HEAD-FIRST per owner ruling
## ("humans start from the head" — the point being indicated is placed first):
##   1. Click 1 (left button)        → store the HEAD position, enter
##                                     first_click_done.
##   2. Pointer move                 → update the live TAIL preview position;
##                                     the head stays fixed at click 1. Canvas
##                                     redraws each frame and calls
##                                     draw_preview() which reads the latest
##                                     tail-preview position.
##   3. Click 2 (left button)        → store the TAIL position, build
##                                     annotation Dict (head → "to", tail →
##                                     "from"), emit annotation_ready, return
##                                     to idle.
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
## Annotation Dict shape (v2 — matches AnnotationArrow.render which reads
## "from"/"to"; AnnotationArrow's canonical anchor is the head, i.e. "to"):
##   {
##     "kind": "2d_arrow",
##     "schema_version": 2,
##     "anchor": core/canvas.point(hx, hy),   -- the HEAD (click 1)
##     "kind_payload": {},
##     "primitives": [{"kind": "arrow", "from": [tx, ty], "to": [hx, hy]}],
##     "lifecycle": "open",
##     "author": {"kind": "human"},
##     "view_context": "<host.get_view_context()>",
##     "visible_in_views": ["all"], "summary": "Arrow"
##   }
## Note: id is assigned by the substrate's add_annotation() on accept. A v1
## envelope (schema_version 1) is REJECTED by AnnotationV2Schema.validate — that
## silent rejection is why arrow authoring produced nothing before.

# ── State ─────────────────────────────────────────────────────────────────────

enum State { IDLE, FIRST_CLICK_DONE }

var _state: int = State.IDLE
var _host: AnnotationHost = null

## HEAD position — click 1, the point being indicated. Fixed once set (set
## when leaving IDLE); does not move during the FIRST_CLICK_DONE preview.
var _head: Vector2 = Vector2.ZERO

## TAIL position — click 2 (only assigned briefly during finalize).
var _tail: Vector2 = Vector2.ZERO

## Live TAIL preview position, updated on every pointer move while
## state == FIRST_CLICK_DONE. The head stays pinned at _head.
var _tail_preview: Vector2 = Vector2.ZERO


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = State.IDLE
	_head = Vector2.ZERO
	_tail = Vector2.ZERO
	_tail_preview = Vector2.ZERO


func on_deactivate() -> void:
	# Per design: clean reset on tool-switch without emitting cancelled.
	# cancelled is for explicit user-abort (right-click / Escape) only.
	_state = State.IDLE
	_head = Vector2.ZERO
	_tail = Vector2.ZERO
	_tail_preview = Vector2.ZERO
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
			# Click 1 places the HEAD — the point being indicated.
			_head = doc_pos
			_tail_preview = doc_pos
			_state = State.FIRST_CLICK_DONE
			return true
		State.FIRST_CLICK_DONE:
			# Click 2 places the TAIL.
			_tail = doc_pos
			var annotation := _build_annotation(_head, _tail)
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
	# call draw_preview() which reads _tail_preview. The head stays pinned at
	# _head. See preview-redraw contract at the top of this file.
	_tail_preview = _host.transform_screen_to_doc(pos)


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
	# Head is pinned at _head (click 1); tail follows the cursor via
	# _tail_preview — "pin the head, pull out the tail." (Preview is a plain
	# faded line; no arrowhead glyph is drawn during authoring — the head/tail
	# triangle rendering lives in AnnotationArrow.render, not here.)
	ctx.draw_line(_head, _tail_preview, faded, 1.0)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _reset_state() -> void:
	_state = State.IDLE
	_head = Vector2.ZERO
	_tail = Vector2.ZERO
	_tail_preview = Vector2.ZERO


func _build_annotation(head: Vector2, tail: Vector2) -> Dictionary:
	# v2 envelope (schema_version 2) — matches the established authoring pattern
	# (route_hint / text_comment build v2 directly). Head-first: click 1 is the
	# HEAD (the point being indicated) and anchors the annotation; click 2 is
	# the TAIL. This matches AnnotationArrow's canonical anchor, which is the
	# head (see AnnotationArrow.primary_anchor_point, which reads primitive
	# "to"). The base AnnotationHost resolves canvas.point so the annotation
	# renders on any host. (A raw v1 envelope is rejected by
	# AnnotationV2Schema.validate — schema_version must be 2 — which is why
	# authoring silently produced nothing before.) Keys "from"/"to" match what
	# AnnotationArrow.render reads: "to" is the head (arrowhead tip), "from" is
	# the tail. The host assigns id on accept.
	var view_ctx := ""
	if _host != null:
		view_ctx = _host.get_view_context()
	var now := int(Time.get_unix_time_from_system())
	return {
		"kind":            "2d_arrow",
		"schema_version":  2,
		"anchor":          CoreAnchors.make_canvas_point(head.x, head.y),
		"kind_payload":    {},
		"primitives":      [{
			"kind": "arrow",
			"from": [tail.x, tail.y],
			"to":   [head.x, head.y],
		}],
		"lifecycle":       "open",
		"author":          {"kind": "human"},
		"view_context":    view_ctx,
		"visible_in_views": ["all"],
		"summary":         "Arrow",
		"created_at":      now,
		"updated_at":      now,
	}
