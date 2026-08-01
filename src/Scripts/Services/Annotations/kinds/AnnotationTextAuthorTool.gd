class_name AnnotationTextAuthorTool
extends AnnotationAuthorTool
## Authoring tool for the built-in 2d_text annotation kind.
##
## Second per-kind AnnotationAuthorTool subclass; mirrors the shape established
## by AnnotationArrowAuthorTool (state machine + signal contract + freshness).
##
## Interaction model — in-place editing (Illustrator/Photoshop type tool):
##   1. Click (left button)  → the click point is stored in document space and a
##                             LineEdit is parented to the annotation overlay AT
##                             that point and focused, so a caret blinks on the
##                             canvas immediately. No dialog, no popup window,
##                             no focus-stealing.
##   2. User types           → the LineEdit renders the text live using the same
##                             font (ThemeDB.fallback_font), the same author
##                             colour, and the same zoom-scaled pixel size that
##                             AnnotationText.render() will use, so what is being
##                             typed reads as the annotation being born.
##   3. Enter (no Shift)     → commit: build the annotation Dict, emit
##                             annotation_ready, return to IDLE. Shift+Enter is
##                             swallowed — 2d_text renders one draw_string line,
##                             so there is no multi-line form to author.
##   4. Click elsewhere      → commit the in-progress text (Illustrator) and
##                             immediately begin a new entry at the new point.
##                             The tool stays active and stays in TYPING.
##   5. Escape / right-click → cancel: emit cancelled, return to IDLE.
##   6. Empty / whitespace   → never authors an annotation. On Enter that is a
##                             cancel (cancelled emitted, matching the original
##                             rule); on click-elsewhere it is a SILENT discard,
##                             because the toolbar tears the tool down when it
##                             sees cancelled and the whole point of that gesture
##                             is "keep typing over there".
##
## Commit-on-focus-loss is deliberately NOT wired — one clean commit semantics.
## AnnotationOverlay._gui_input calls grab_focus() on itself for every left press
## before forwarding the event, so a focus_exited commit would race the
## click-elsewhere commit and double-fire. Click-elsewhere is the single "the
## user moved on" commit path; losing focus to unrelated chrome (e.g. the
## toolbar) leaves the entry open and typeable again on re-focus.
##
## Where the editor lives (why the overlay grew a hook):
##   AnnotationAuthorTool is handed only an AnnotationHost — a RefCounted with no
##   Control anywhere on its API — and the overlay's key forwarding covers only
##   Esc / Delete / Enter, never character keys. A tool therefore cannot collect
##   typed text on its own. AnnotationOverlay.set_active_tool() now hands the
##   active tool its own Control through the duck-typed
##   attach_edit_surface(parent) (null to hand it back). The overlay's local
##   space IS the space the host's view transform targets, so the caret's screen
##   position is just host.transform_doc_to_screen(_at).
##   The widget itself was FACTORED OUT into AnnotationInPlaceTextEditor (A8u2)
##   so AnnotationTransformTool can drive the same editor for arrow labels.
##
## World anchoring: _at is stored in DOCUMENT space and the widget is
## repositioned + restyled from draw_preview() on every overlay redraw. The
## overlay redraws on host view_changed and on resize, so the entry surface
## tracks pan/zoom while the user is typing.
##
## Testability: _text_provider keeps its original shape — a Callable taking
## (Vector2 at_doc, Callable on_done), where on_done receives a String to submit
## or null to cancel. What changed is the DEFAULT: it is now an EMPTY Callable,
## which means "collect in place with a real widget". Tests and programmatic
## callers assign a synchronous stub exactly as before and no widget is ever
## created. While a provider is driving collection the tool owns no Control, so
## canvas clicks during TYPING stay ignored rather than becoming commits.
##
## Tool-switch semantics (mirrors arrow):
##   on_deactivate() during TYPING is a SILENT cancel — the editor is discarded
##   and no cancelled signal is emitted. cancelled is reserved for explicit
##   user-abort (Escape / right-click).
##
## Annotation Dict shape (v2 canonical payload/anchor form):
##   {
##     "kind": "2d_text",
##     "schema_version": 2,
##     "anchor": core/canvas.point(x, y),
##     "kind_payload": {"text": "<typed_string>", "font_size": <TARGET_SCREEN_FONT_PX / authoring zoom>},
##     "primitives": [],
##     "lifecycle": "open",
##     "author": {"kind": "human"},
##     "view_context": "<host.get_view_context()>",
##     "visible_in_views": ["all"], "summary": "<typed_string>"
##   }
## Note: id is assigned by the substrate's add_annotation() on accept. A v1
## envelope (schema_version 1) is REJECTED by AnnotationV2Schema.validate.

# ── State ─────────────────────────────────────────────────────────────────────

enum State { IDLE, TYPING }

## Target on-SCREEN glyph height at authoring time, in pixels. The authored
## annotation's font_size is stored in DOCUMENT units as this value divided by
## the host zoom at collection start — so new text reads the same size on any
## host, instead of a fixed 14 doc units (which is 14 *millimeters* on a
## mm-unit canvas like the PCB panel and rendered as a clamped-64px monster;
## owner HITL 2026-07-30 — same doc-vs-screen bug class as the transform
## gizmo's zone sizes). On zoom-1 hosts (text editor canvas) the stored value
## is 14, identical to the old default.
const TARGET_SCREEN_FONT_PX: int = 14

var _state: int = State.IDLE
var _host: AnnotationHost = null

## Click position in document space (set when leaving IDLE).
var _at: Vector2 = Vector2.ZERO

## Optional text-collection override. Signature: func(at_doc: Vector2,
## on_done: Callable); on_done receives a String for submit, null for cancel.
## EMPTY by default — empty means "use the in-place editor". See the class
## doc-comment for the testability rationale.
var _text_provider: Callable = Callable()

## The in-place editor widget. FACTORED OUT into AnnotationInPlaceTextEditor in
## A8u2 so AnnotationTransformTool can drive the same LineEdit for arrow labels;
## this tool's behaviour is unchanged, it just no longer owns the Control.
var _editor: AnnotationInPlaceTextEditor = AnnotationInPlaceTextEditor.new()

## Document-unit font size for the annotation being authored — frozen at
## collection start (TARGET_SCREEN_FONT_PX / host zoom), so mid-edit zooming
## rescales the view without silently changing the committed size.
var _authored_font_size: float = float(TARGET_SCREEN_FONT_PX)


func _init() -> void:
	_editor.submitted.connect(_on_editor_submitted)
	_editor.aborted.connect(_on_editor_aborted)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = State.IDLE
	_at = Vector2.ZERO


func on_deactivate() -> void:
	# Per design: clean reset on tool-switch without emitting cancelled.
	# cancelled is for explicit user-abort (Escape / right-click) only.
	_discard_editor()
	_state = State.IDLE
	_at = Vector2.ZERO
	_host = null


## Duck-typed hook called by AnnotationOverlay.set_active_tool(): hands this tool
## the Control it may parent an in-canvas editor to, or null to hand it back.
## Tools that need no Control simply don't define this method.
func attach_edit_surface(parent: Control) -> void:
	# The shared editor drops any live widget when the surface changes rather
	# than orphaning it.
	_editor.set_surface(parent)


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	# Right-click while authoring → explicit user abort.
	if button == MOUSE_BUTTON_RIGHT:
		if _state == State.TYPING:
			_abort()
			return true
		return false

	# The overlay surfaces key events as pseudo-pointer-downs on the mods
	# channel (AnnotationOverlay._gui_input). These only reach us when the
	# OVERLAY holds focus — while the in-place editor is focused, Esc/Enter are
	# handled in _on_edit_gui_input instead. Both paths are kept so the tool
	# behaves identically with and without a live widget.
	if mods == KEY_ESCAPE:
		if _state == State.TYPING:
			_abort()
			return true
		return false
	if mods == KEY_ENTER:
		# Only meaningful for the widget path; a provider owns its own submit.
		if _state == State.TYPING and _has_live_editor():
			_on_text_provider_done(_editor.get_text())
			return true
		return false

	if button != MOUSE_BUTTON_LEFT:
		return false

	if _host == null:
		return false

	if _state == State.TYPING:
		if not _has_live_editor():
			# Provider-driven collection owns its own commit UX (and may be a
			# modal of its own making) — canvas clicks are not ours to read.
			return false
		# Illustrator: clicking elsewhere commits what is typed and starts a new
		# entry at the new point, without leaving TYPING.
		_commit_for_click(_host.transform_screen_to_doc(pos))
		return true

	_at = _host.transform_screen_to_doc(pos)
	_state = State.TYPING
	_begin_collection()
	return true


func on_pointer_move(_pos: Vector2) -> void:
	# Caret is anchored at click time and does not track the pointer.
	pass


func on_pointer_up(_pos: Vector2, _button: int, _mods: int) -> bool:
	# Click-to-commit, not drag — pointer_up is unused.
	return false


# ── Preview ───────────────────────────────────────────────────────────────────

func draw_preview(ctx: AnnotationRenderContext) -> void:
	if _state != State.TYPING:
		return
	if _has_live_editor():
		# The widget IS the preview; keep it pinned to the document-space caret
		# point and sized to the current zoom. draw_preview is the natural place
		# for this because the overlay redraws on every view change.
		_sync_editor_to_view(ctx)
		return
	# Provider-driven collection: no widget to look at, so draw a caret marker at
	# the click point to show where the text will land.
	var base := AnnotationRenderContext.author_color("human")
	var faded := Color(base.r, base.g, base.b, 0.5)
	# Vertical caret bar, 12 doc-units tall.
	var top := _at + Vector2(0.0, -6.0)
	var bot := _at + Vector2(0.0, 6.0)
	ctx.draw_line(top, bot, faded, 1.0)


# ── Collection dispatch ───────────────────────────────────────────────────────

func _begin_collection() -> void:
	# Freeze the authored size now, from the zoom the user is looking at —
	# same host duck-type idiom as AnnotationTransformTool._view_zoom.
	_authored_font_size = AnnotationInPlaceTextEditor.authored_font_size(_view_zoom())
	# An injected provider wins: it means a test or a programmatic caller wants
	# to supply the text without a live widget.
	if _text_provider.is_valid():
		_text_provider.call(_at, Callable(self, "_on_text_provider_done"))
		return
	if _editor.has_surface():
		_open_editor()
		return
	# No widget surface and no provider — nothing can collect text. Cancel so we
	# don't sit in TYPING forever.
	push_warning("[AnnotationTextAuthorTool] no edit surface and no _text_provider; "
		+ "text authoring cancelled. The overlay should call attach_edit_surface().")
	_on_text_provider_done(null)


func _on_text_provider_done(result: Variant) -> void:
	# A provider may fire after on_deactivate() (async collectors exist). Guard.
	if _state != State.TYPING:
		return

	# Cancel path: null result, or empty/whitespace-only string.
	if result == null:
		_reset_state()
		cancelled.emit()
		return

	var content := str(result).strip_edges()
	if content.is_empty():
		_reset_state()
		cancelled.emit()
		return

	var annotation := _build_annotation(_at, content)
	_reset_state()
	annotation_ready.emit(annotation)


## Commit-and-continue for a click on empty canvas while typing. Never emits
## cancelled: an empty entry is discarded silently so the tool survives the
## gesture (the toolbar deactivates the tool when it sees cancelled).
func _commit_for_click(new_at: Vector2) -> void:
	var content := _editor.get_text().strip_edges()
	var pending: Variant = null
	if not content.is_empty():
		pending = _build_annotation(_at, content)
	# Move the caret and re-arm the editor BEFORE emitting, so anything the
	# add_annotation round-trip triggers (redraw, selection change) sees a
	# consistent tool state.
	_at = new_at
	_open_editor()
	if pending is Dictionary:
		annotation_ready.emit(pending)


## Explicit user abort (Escape / right-click).
func _abort() -> void:
	_reset_state()
	cancelled.emit()


# ── In-place editor ───────────────────────────────────────────────────────────

func _has_live_editor() -> bool:
	return _editor.is_open()


func _open_editor() -> void:
	_editor.open(_host_doc_to_screen(_at), _host_zoom(), _authored_font_size, "", "Type annotation…")


## Enter (no shift) inside the widget — same commit path as the provider's.
func _on_editor_submitted(text: String) -> void:
	_on_text_provider_done(text)


## Escape inside the widget — explicit user abort.
func _on_editor_aborted() -> void:
	_abort()


## Pin the editor to the document-space caret point and keep its glyph size in
## step with the zoom, matching AnnotationText._render_payload_text's clamp.
func _sync_editor_to_view(ctx: AnnotationRenderContext) -> void:
	_editor.place(ctx.to_screen(_at), ctx.zoom)


## Host zoom via the optional accessor — same duck-type guard as
## AnnotationTransformTool. 1.0 on hosts that don't expose zoom.
func _view_zoom() -> float:
	if _host != null and _host.has_method("get_annotation_zoom"):
		return maxf(float(_host.get_annotation_zoom()), 0.01)
	return 1.0


func _discard_editor() -> void:
	# Tear the widget down without routing its content anywhere — used for silent
	# tool-switch cleanup and for surface hand-back.
	_editor.discard()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _host_doc_to_screen(doc_pos: Vector2) -> Vector2:
	if _host == null:
		return doc_pos
	return _host.transform_doc_to_screen(doc_pos)


func _host_zoom() -> float:
	if _host == null:
		return 1.0
	return _host.get_annotation_zoom()


func _reset_state() -> void:
	_discard_editor()
	_state = State.IDLE
	_at = Vector2.ZERO


func _build_annotation(at_pos: Vector2, content: String) -> Dictionary:
	# v2 envelope (schema_version 2). Was schema_version 1, which
	# AnnotationV2Schema.validate rejects (schema_version must be 2), so the
	# submitted text was silently dropped by host.add_annotation. Now mirrors the
	# route_hint / text_comment v2 shape; the host assigns id on accept.
	var view_ctx := ""
	if _host != null:
		view_ctx = _host.get_view_context()
	var now := int(Time.get_unix_time_from_system())
	return {
		"kind":            "2d_text",
		"schema_version":  2,
		"anchor":          CoreAnchors.make_canvas_point(at_pos.x, at_pos.y),
		"kind_payload":    {"text": content, "font_size": _authored_font_size},
		"primitives":      [],
		"lifecycle":       "open",
		"author":          {"kind": "human"},
		"view_context":    view_ctx,
		"visible_in_views": ["all"],
		"summary":         content,
		"created_at":      now,
		"updated_at":      now,
	}
