class_name AnnotationTextAuthorTool
extends AnnotationAuthorTool
## Authoring tool for the built-in 2d_text annotation kind.
##
## Second per-kind AnnotationAuthorTool subclass; mirrors the shape established
## by AnnotationArrowAuthorTool (state machine + signal contract + freshness).
##
## Interaction model (click → type → commit):
##   1. Click (left button)        → store caret position, open text dialog,
##                                   enter TYPING.
##   2. User types in the dialog   → independent of canvas pointer events.
##   3. Press Enter / OK in dialog → build annotation Dict with the typed
##                                   content, emit annotation_ready, return
##                                   to IDLE.
##   4. Press Esc / Cancel         → emit cancelled, return to IDLE.
##   5. Empty content on submit    → treated as a cancel (we never author
##                                   empty text annotations).
##
## Why a dialog (option B from the task brief)?
##   The author-tool pointer/input contract does NOT deliver keystrokes — only
##   pointer_down/move/up. Inline text-entry would require either a new
##   on_key_down channel on the base class or an in-canvas LineEdit overlay,
##   both of which are out of scope for this unit. A modal AcceptDialog is
##   self-contained inside the tool, uses standard Godot widgets, and keeps
##   the AnnotationAuthorTool API surface unchanged. The UX trade-off is a
##   brief modal popup instead of in-place editing — acceptable for the
##   first text-authoring smoke.
##
## Testability: _text_provider is a Callable that takes (Vector2 doc_pos,
## Callable on_done) and is responsible for collecting text from the user.
## The default provider opens a real AcceptDialog; tests inject a synchronous
## stub that immediately invokes on_done with a fixed string (or null to
## simulate cancel). This avoids needing to drive the SceneTree from a unit
## test.
##
## Tool-switch semantics (mirrors arrow):
##   on_deactivate() during TYPING is a SILENT cancel — no cancelled signal
##   emitted. The cancelled signal is reserved for explicit user-abort
##   (dialog Cancel / Escape).
##
## Annotation Dict shape (v2 canonical payload/anchor form):
##   {
##     "kind": "2d_text",
##     "schema_version": 2,
##     "anchor": core/canvas.point(x, y),
##     "kind_payload": {"text": "<typed_string>", "font_size": 14},
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

const DEFAULT_FONT_SIZE: int = 14

var _state: int = State.IDLE
var _host: AnnotationHost = null

## Click position in document space (set when leaving IDLE).
var _at: Vector2 = Vector2.ZERO

## Text-entry provider. Signature: func(at_doc: Vector2, on_done: Callable).
## on_done receives Variant — a String for submit, null for cancel.
## See class doc-comment for testability rationale.
var _text_provider: Callable = Callable()

## Reference to the live dialog when the default provider is in use, so
## on_deactivate() can clean it up silently.
var _active_dialog: AcceptDialog = null


func _init() -> void:
	# Default to the real-dialog provider. Tests overwrite this field after
	# construction to inject a stub.
	_text_provider = Callable(self, "_default_text_provider")


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func on_activate(host: AnnotationHost) -> void:
	_host = host
	_state = State.IDLE
	_at = Vector2.ZERO


func on_deactivate() -> void:
	# Per design: clean reset on tool-switch without emitting cancelled.
	# cancelled is for explicit user-abort (dialog cancel / Escape) only.
	_close_dialog_silently()
	_state = State.IDLE
	_at = Vector2.ZERO
	_host = null


# ── Pointer / input ───────────────────────────────────────────────────────────

func on_pointer_down(pos: Vector2, button: int, _mods: int) -> bool:
	if button != MOUSE_BUTTON_LEFT:
		return false

	# Already typing → dialog is modal; ignore canvas clicks.
	if _state == State.TYPING:
		return false

	if _host == null:
		return false

	_at = _host.transform_screen_to_doc(pos)
	_state = State.TYPING

	# Provider is responsible for collecting text. on_done receives the
	# entered string (or null for cancel) and we finalize accordingly.
	if _text_provider.is_valid():
		_text_provider.call(_at, Callable(self, "_on_text_provider_done"))
	else:
		# No provider — degenerate path. Treat as cancel so we don't get
		# stuck in TYPING forever.
		_on_text_provider_done(null)

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
	# Small caret marker at the click point so the user remembers where text
	# will land before the dialog paints over the canvas.
	var base := AnnotationRenderContext.author_color("human")
	var faded := Color(base.r, base.g, base.b, 0.5)
	# Vertical caret bar, 12 doc-units tall.
	var top := _at + Vector2(0.0, -6.0)
	var bot := _at + Vector2(0.0, 6.0)
	ctx.draw_line(top, bot, faded, 1.0)


# ── Provider callback ─────────────────────────────────────────────────────────

func _on_text_provider_done(result: Variant) -> void:
	# Provider may fire after on_deactivate() (real dialogs are async). Guard.
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


# ── Default real-dialog provider ──────────────────────────────────────────────

func _default_text_provider(_at_doc: Vector2, on_done: Callable) -> void:
	# Build a minimal AcceptDialog with a LineEdit. Attach to the SceneTree's
	# root so it can show even though this tool is a RefCounted with no
	# parent of its own.
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		on_done.call(null)
		return
	var tree: SceneTree = loop
	var root := tree.root
	if root == null:
		on_done.call(null)
		return

	var dialog := AcceptDialog.new()
	dialog.title = "Annotation text"
	dialog.dialog_hide_on_ok = true
	dialog.add_cancel_button("Cancel")

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "Enter annotation text…"
	line_edit.custom_minimum_size = Vector2(240, 0)
	dialog.add_child(line_edit)

	# Single-shot bookkeeping — guarantee on_done fires exactly once.
	var fired: Array = [false]
	var finish := func(result: Variant) -> void:
		if fired[0]:
			return
		fired[0] = true
		_active_dialog = null
		dialog.queue_free()
		on_done.call(result)

	dialog.confirmed.connect(func() -> void:
		finish.call(line_edit.text)
	)
	dialog.canceled.connect(func() -> void:
		finish.call(null)
	)
	# Enter inside the LineEdit submits.
	line_edit.text_submitted.connect(func(submitted: String) -> void:
		finish.call(submitted)
	)

	_active_dialog = dialog
	root.add_child(dialog)
	dialog.popup_centered()
	line_edit.grab_focus()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _close_dialog_silently() -> void:
	# Tear down the real dialog (if any) without firing its confirmed/canceled
	# signals to on_done — used for silent tool-switch cleanup.
	if _active_dialog != null:
		var d := _active_dialog
		_active_dialog = null
		# Disconnect everything we know about by simply freeing — listeners
		# on a freed object don't fire.
		d.queue_free()


func _reset_state() -> void:
	_state = State.IDLE
	_at = Vector2.ZERO
	_active_dialog = null


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
		"kind_payload":    {"text": content, "font_size": DEFAULT_FONT_SIZE},
		"primitives":      [],
		"lifecycle":       "open",
		"author":          {"kind": "human"},
		"view_context":    view_ctx,
		"visible_in_views": ["all"],
		"summary":         content,
		"created_at":      now,
		"updated_at":      now,
	}
