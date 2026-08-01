class_name AnnotationInPlaceTextEditor
extends RefCounted
## Shared in-canvas single-line text editor for annotation tools.
##
## FACTORED OUT of AnnotationTextAuthorTool (core commit 6044ed5f, epoch 6) in
## A8u2 so a SECOND tool — AnnotationTransformTool's Visio-style arrow-label
## editing — can drive the exact same widget without reimplementing it. The
## behaviour here is the text tool's behaviour verbatim; only the ownership moved.
##
## What it owns:
##   - The LineEdit itself: creation, minimal stylebox chrome, author-coloured
##     glyphs, caret, expand-to-text sizing, teardown.
##   - Zoom-aware placement: the caller supplies a SCREEN point plus the current
##     zoom on every redraw; the widget is pinned there and its pixel font size
##     is (document font size × zoom), clamped 8…64 — the same clamp
##     AnnotationText._render_payload_text uses, so what is typed reads as the
##     annotation being born / edited.
##   - Key grammar: Enter → `submitted(text)`, Escape → `aborted()`,
##     Shift+Enter → swallowed (every consumer is single-line).
##
## What it does NOT own: the tool's state machine, where the doc point comes
## from, or what the committed string means. Consumers connect the two signals.
##
## Surface: annotation tools receive only an AnnotationHost (a RefCounted with no
## Control anywhere on its API), so the Control to parent onto arrives through
## AnnotationOverlay.set_active_tool → the tool's duck-typed
## attach_edit_surface(parent) → set_surface() here. Without a surface (headless
## tests) is_open() stays false and open() returns false.

## Emitted on Enter (no shift). Carries the RAW text — the consumer decides what
## empty means (the text tool cancels; the arrow-label editor clears the label).
signal submitted(text: String)

## Emitted on Escape — cancel without committing.
signal aborted()

## Target on-SCREEN glyph height, in pixels, for freshly authored text. Stored
## document-unit sizes are this divided by the authoring zoom, so new text reads
## the same size on any host instead of being 14 *millimetres* on a mm-unit
## canvas (owner HITL 2026-07-30).
const TARGET_SCREEN_FONT_PX: int = 14

## Content margin baked into the stylebox, in px. The widget is offset by it so
## the first glyph lands on the caret point rather than inside the chrome.
const PADDING: float = 2.0
const MIN_WIDTH: float = 120.0

var _parent: Control = null
var _edit: LineEdit = null
var _font_px: int = -1

## Last placement, replayed whenever the widget resizes (see _on_edit_text_changed).
var _anchor_screen: Vector2 = Vector2.ZERO

## True when _anchor_screen is the widget's CENTRE rather than its top-left.
## Centred mode exists because a caption that renders centred on a derived point
## must be TYPED centred on that same point — otherwise the committed text jumps
## sideways by half its width the moment the editor closes (A8u2 F2). The 2d_text
## author tool keeps the default top-left anchoring, which is caret placement.
var _centred: bool = false

## Document-unit font size for the text being edited — frozen by open(), so
## mid-edit zooming rescales the view without changing the committed size.
var _doc_font_size: float = float(TARGET_SCREEN_FONT_PX)


## Document-unit font size that renders as TARGET_SCREEN_FONT_PX at `zoom`.
static func authored_font_size(zoom: float) -> float:
	return clampf(float(TARGET_SCREEN_FONT_PX) / maxf(zoom, 0.01), 0.05, 400.0)


## Hand this editor the Control it may parent onto (null to hand it back). A
## surface change discards any live widget rather than orphaning it.
func set_surface(parent: Control) -> void:
	if parent == _parent:
		return
	discard()
	_parent = parent


func has_surface() -> bool:
	return _parent != null and is_instance_valid(_parent)


func is_open() -> bool:
	return _edit != null and is_instance_valid(_edit)


## Open (or re-open) the editor at `screen_pos` with `initial_text` selected-free
## and the caret at the end. Returns false when there is no surface to host it.
## `centred` makes screen_pos the widget's centre instead of its top-left, and
## keeps it centred as the text grows.
func open(
	screen_pos: Vector2,
	zoom: float,
	doc_font_size: float,
	initial_text: String = "",
	placeholder: String = "Type annotation…",
	color: Color = Color(0, 0, 0, 0),
	centred: bool = false,
) -> bool:
	if not has_surface():
		return false
	if not is_open():
		_edit = _create_editor(placeholder, color)
		if _edit == null:
			return false
		_parent.add_child(_edit)
	else:
		_edit.placeholder_text = placeholder
	_doc_font_size = doc_font_size
	_centred = centred
	_edit.text = initial_text
	_font_px = -1
	place(screen_pos, zoom)
	_edit.visible = true
	if _edit.is_inside_tree():
		_edit.grab_focus()
	_edit.caret_column = initial_text.length()
	return true


## Pin the widget to `screen_pos` and keep its glyph size in step with `zoom`.
## Called from the consumer's draw_preview so the entry tracks pan/zoom.
func place(screen_pos: Vector2, zoom: float) -> void:
	if not is_open():
		return
	_anchor_screen = screen_pos
	var px := int(clampf(_doc_font_size * zoom, 8.0, 64.0))
	if px != _font_px:
		_font_px = px
		_edit.add_theme_font_size_override(&"font_size", px)
		_edit.reset_size()
	_reposition()


## Apply the stored anchor. Split out of place() because the widget also has to
## be re-anchored when it RESIZES (typing), which happens between redraws.
func _reposition() -> void:
	if not is_open():
		return
	var target := _anchor_screen - (_edit.size * 0.5 if _centred else Vector2(PADDING, PADDING))
	if not _edit.position.is_equal_approx(target):
		_edit.position = target


func get_text() -> String:
	return _edit.text if is_open() else ""


## Tear the widget down without routing its content anywhere — silent cleanup for
## tool-switch, surface hand-back, and post-commit reset.
func discard() -> void:
	if _edit != null:
		if is_instance_valid(_edit):
			_edit.queue_free()
		_edit = null
	_font_px = -1


# ── Widget ────────────────────────────────────────────────────────────────────

func _create_editor(placeholder: String, color: Color) -> LineEdit:
	if not has_surface():
		return null
	var edit := LineEdit.new()
	edit.name = "AnnotationTextInPlaceEditor"
	edit.flat = true
	edit.expand_to_text_length = true
	edit.caret_blink = true
	edit.custom_minimum_size = Vector2(MIN_WIDTH, 0.0)
	edit.placeholder_text = placeholder

	# Minimal chrome: just enough backing to read the caret over busy canvas
	# content, with the padding place() compensates for.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.35)
	style.set_corner_radius_all(3)
	style.content_margin_left = PADDING
	style.content_margin_right = PADDING
	style.content_margin_top = PADDING
	style.content_margin_bottom = PADDING
	edit.add_theme_stylebox_override(&"normal", style)
	edit.add_theme_stylebox_override(&"focus", style)

	# Match the rendered annotation: kinds draw with a null font (→
	# ThemeDB.fallback_font). Default colour is the human author colour, which is
	# what AnnotationText.render() uses for freshly authored text.
	var glyph_color := color
	if glyph_color.a <= 0.0:
		glyph_color = AnnotationRenderContext.author_color("human")
	var font := ThemeDB.fallback_font
	if font != null:
		edit.add_theme_font_override(&"font", font)
	edit.add_theme_color_override(&"font_color", glyph_color)
	edit.add_theme_color_override(&"font_placeholder_color", Color(glyph_color, 0.4))
	edit.add_theme_color_override(&"caret_color", glyph_color)

	edit.gui_input.connect(_on_edit_gui_input)
	edit.text_changed.connect(_on_edit_text_changed)
	return edit


func _on_edit_text_changed(_new_text: String) -> void:
	# expand_to_text_length only grows the MINIMUM size; a Control outside a
	# container has to be told to take it.
	if is_open():
		_edit.reset_size()
		# Re-anchor: in centred mode the new width must be re-split around the
		# anchor point. Top-left mode re-computes the same target and no-ops.
		_reposition()


func _on_edit_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.is_echo():
		return
	if not is_open():
		return

	match key.keycode:
		KEY_ESCAPE:
			# Consume before emitting: accept_event() stops LineEdit's own
			# handling, and the connected gui_input signal runs before it.
			_edit.accept_event()
			aborted.emit()
		KEY_ENTER, KEY_KP_ENTER:
			_edit.accept_event()
			if key.shift_pressed:
				# Every consumer renders one draw_string line — swallow rather
				# than pretend a multi-line entry is being authored.
				return
			submitted.emit(_edit.text)
