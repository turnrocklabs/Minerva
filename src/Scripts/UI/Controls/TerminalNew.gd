class_name TerminalNew
extends Control

const CURSOR_CHAR: = "█"

var WINDOWS_CWD_REGEX: = RegEx.create_from_string(r"(\r\n)?[a-zA-Z]:[\\\/](?:[a-zA-Z0-9]+[\\\/])*([a-zA-Z0-9\s-]+>)")

@onready var _output_container: ScrollContainer = %OutputContainer
@onready var _check_buttons_container: Control = %CheckButtonsContainer

var _output_label_nodes: Array[TextLayer]

# Terminal is from a GDExtension that may not be available
var terminal = null
var _terminal_available: bool = false

var _viewport_start: int = 0
var _scrolled_up: bool = false

var cursor_visible: bool = true

var text_layer: TextLayer
var cursor_layer: CursorLayer

# Terminal dimensions in cells
var _cols: int = 80
var _rows: int = 24

# TODO: use this in subclasses
var font: Font = preload("res://assets/fonts/CascadiaCode/CascadiaMono.ttf")
var font_size: int = ThemeDB.fallback_font_size
var line_height: float
var char_width: float

# Default palette colors for resolving palette indices
var _palette: Array[Color] = []


## Creates new terminal instance
static func create() -> TerminalNew:
	var terminal_instance = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal_instance

func _update_font_metrics():
	var char_metrics = font.get_char_size("M".unicode_at(0), font_size)
	line_height = font.get_height(font_size)
	char_width = char_metrics.x

func _recalc_terminal_size():
	## cols: from TextLayer width (actual drawable area, excludes check buttons/margins)
	## rows: from _output_container height (visible viewport, not scrolled content)
	var draw_width: float = text_layer.size.x if text_layer else _output_container.size.x
	var view_height: float = _output_container.size.y
	_cols = maxi(1, int(draw_width / char_width))
	_rows = maxi(1, int(view_height / line_height))

func _init_palette():
	var tc: TerminalConfig = SingletonObject.get_terminal_config()
	var _pal := tc.get_full_palette()
	_palette.clear()
	for c in _pal:
		_palette.append(c)

func _apply_terminal_config() -> void:
	var tc: TerminalConfig = SingletonObject.get_terminal_config()
	# Palette
	var _pal := tc.get_full_palette()
	_palette.clear()
	for c in _pal:
		_palette.append(c)
	# Font
	font = tc.get_font()
	font_size = tc.font_size
	_update_font_metrics()
	_recalc_terminal_size()
	if terminal and terminal.has_method("resize"):
		terminal.resize(_cols, _rows)
	# Cursor
	if cursor_layer:
		cursor_layer.cursor_style = tc.cursor_style
		cursor_layer.cursor_blink = tc.cursor_blink
		cursor_layer.queue_redraw()
	# Redraw
	if text_layer:
		text_layer.queue_redraw()

func _ready():
	# Check if Terminal GDExtension is available
	if ClassDB.class_exists("Terminal"):
		terminal = ClassDB.instantiate("Terminal")
		_terminal_available = true
		add_child(terminal)
	else:
		push_error("Terminal GDExtension not available - terminal functionality disabled")
		return

	visibility_changed.connect(
		func():
			if is_visible_in_tree():
				grab_focus()
	)

	# Apply terminal config (font, palette, cursor) and listen for changes
	var tc: TerminalConfig = SingletonObject.get_terminal_config()
	font = tc.get_font()
	font_size = tc.font_size
	_update_font_metrics()
	_init_palette()
	tc.settings_changed.connect(_apply_terminal_config)

	_create_output_container()

	# Connect to libghostty-vt state change signal for cell-grid rendering
	if terminal.has_signal("vt_state_changed"):
		terminal.vt_state_changed.connect(_on_vt_state_changed)
		print("[Terminal] vt_state_changed signal connected — using libghostty-vt cell-grid rendering")
	else:
		push_warning("[Terminal] vt_state_changed signal NOT found — libghostty-vt not available")

	# Keep legacy output signal for shell prompt marker detection
	terminal.output_received.connect(_on_output_received)

	# Shell prompt markers
	terminal.on_shell_prompt_start.connect(
		func():
			var cursor = terminal.get_cursor()
			_create_check_button(cursor.get("y", 0))
	)
	terminal.on_shell_prompt_end.connect(
		func():
			var cursor = terminal.get_cursor()
			_create_check_button(cursor.get("y", 0))
	)

	await get_tree().process_frame

	_recalc_terminal_size()
	print("[Terminal] Container size: %s, self size: %s, cw=%.2f, lh=%.2f" % [_output_container.size, size, char_width, line_height])
	print("[Terminal] Starting with size: %d cols x %d rows" % [_cols, _rows])
	print("[Terminal] Font: %s" % font.resource_path)
	var started = terminal.start(_cols, _rows)
	if not started:
		push_error("[Terminal] Failed to start terminal - forkpty may have failed")
	else:
		print("[Terminal] Terminal started successfully")

	resized.connect(
		func():
			_recalc_terminal_size()
			terminal.resize(_cols, _rows)
			text_layer.queue_redraw()
			cursor_layer.queue_redraw()
	)


var _scrollbar_updating: bool = false

func _on_vt_state_changed() -> void:
	text_layer.queue_redraw()
	cursor_layer.queue_redraw()
	_update_scrollbar()

func _update_scrollbar() -> void:
	if not _vscrollbar or not terminal or not terminal.has_method("get_scroll_info"):
		return
	var info: Dictionary = terminal.get_scroll_info()
	if info.is_empty():
		return
	var total: int = info.get("total_rows", _rows)
	var viewport: int = info.get("viewport_rows", _rows)
	var at_bottom: bool = info.get("is_at_bottom", true)
	var scrollback: int = maxi(0, total - viewport)

	_scrollbar_updating = true
	# Godot ScrollBar: draggable range is [min_value, max_value - page]
	# So set max_value = total, page = viewport → max position = total - viewport = scrollback
	_vscrollbar.max_value = total
	_vscrollbar.page = viewport
	if at_bottom:
		_vscrollbar.value = scrollback  # total - viewport
		_scrolled_up = false
	_scrollbar_updating = false

func _on_scrollbar_changed(value: float) -> void:
	if _scrollbar_updating or not terminal:
		return
	var info: Dictionary = terminal.get_scroll_info()
	var total: int = info.get("total_rows", _rows)
	var viewport: int = info.get("viewport_rows", _rows)
	var scrollback: int = maxi(0, total - viewport)
	# value range: 0 (top of history) to scrollback (bottom/current)
	var lines_from_bottom: int = scrollback - int(value)
	if lines_from_bottom <= 0:
		_scrolled_up = false
		terminal.scroll_viewport(0)
	else:
		_scrolled_up = true
		terminal.scroll_viewport(0)
		terminal.scroll_viewport(-lines_from_bottom)
	text_layer.queue_redraw()
	cursor_layer.queue_redraw()

func _on_output_received(_text: String, _type: int) -> void:
	# Legacy signal handler — kept only for shell prompt detection on Windows
	var matches: = WINDOWS_CWD_REGEX.search_all(_text)
	if not matches.is_empty():
		for match_ in matches:
			var cursor = terminal.get_cursor()
			_create_check_button(cursor.get("y", 0))


var _vscrollbar: VScrollBar

func _create_output_container() -> void:
	# Hide the inner ScrollContainer's scrollbar — we add our own driven by ghostty-vt
	_output_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	var hbox: = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_check_buttons_container = Control.new()
	_check_buttons_container.custom_minimum_size.x = 32

	text_layer = TextLayer.new()
	text_layer.terminal = self

	cursor_layer = CursorLayer.new()
	cursor_layer.terminal = self

	text_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cursor_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	text_layer.add_child(cursor_layer)

	hbox.add_child(_check_buttons_container)
	hbox.add_child(text_layer)

	_output_container.add_child(hbox)

	# Add a VScrollBar next to the output container, driven by ghostty-vt scroll info
	_vscrollbar = VScrollBar.new()
	_vscrollbar.custom_minimum_size.x = 12
	_vscrollbar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vscrollbar.value_changed.connect(_on_scrollbar_changed)
	# Insert scrollbar as sibling of _output_container inside its parent HBox
	_output_container.get_parent().add_child(_vscrollbar)

	_output_label_nodes.append(text_layer)


func _create_check_button(row: int) -> void:
	var btn = CheckButton.new()
	btn.set_meta("row", row)
	btn.toggled.connect(_on_check_button_toggled.bind(btn))
	btn.position.y = row * line_height
	_check_buttons_container.add_child(btn)


func _on_check_button_toggled(_toggled_on: bool, _btn: CheckButton):
	pass


func resolve_color(cell: Dictionary, key: String, default_color: Color) -> Color:
	## Resolve a cell color — handles RGB, palette, and default.
	if cell.has(key):
		return cell[key]
	var palette_key = key + "_palette"
	if cell.has(palette_key):
		var idx: int = cell[palette_key]
		if idx >= 0 and idx < _palette.size():
			return _palette[idx]
	return default_color


# region input

# Ghostty key constants (must match GhosttyKey / MinervaKey enum in event.h / minerva_vt.h)
# Values are sequential enum indices starting from 0.
const GK_UNIDENTIFIED := 0
# Writing System Keys (1-50)
const GK_BACKQUOTE := 1
const GK_BACKSLASH := 2
const GK_BRACKET_LEFT := 3
const GK_BRACKET_RIGHT := 4
const GK_COMMA := 5
const GK_DIGIT_0 := 6
const GK_DIGIT_1 := 7
const GK_DIGIT_2 := 8
const GK_DIGIT_3 := 9
const GK_DIGIT_4 := 10
const GK_DIGIT_5 := 11
const GK_DIGIT_6 := 12
const GK_DIGIT_7 := 13
const GK_DIGIT_8 := 14
const GK_DIGIT_9 := 15
const GK_EQUAL := 16
# 17=INTL_BACKSLASH, 18=INTL_RO, 19=INTL_YEN
const GK_A := 20
const GK_B := 21
const GK_C := 22
const GK_D := 23
const GK_E := 24
const GK_F := 25
const GK_G := 26
const GK_H := 27
const GK_I := 28
const GK_J := 29
const GK_K := 30
const GK_L := 31
const GK_M := 32
const GK_N := 33
const GK_O := 34
const GK_P := 35
const GK_Q := 36
const GK_R := 37
const GK_S := 38
const GK_T := 39
const GK_U := 40
const GK_V := 41
const GK_W := 42
const GK_X := 43
const GK_Y := 44
const GK_Z := 45
const GK_MINUS := 46
const GK_PERIOD := 47
const GK_QUOTE := 48
const GK_SEMICOLON := 49
const GK_SLASH := 50
# Functional Keys (51-67)
# 51=ALT_LEFT, 52=ALT_RIGHT
const GK_BACKSPACE := 53
# 54=CAPS_LOCK, 55=CONTEXT_MENU, 56=CONTROL_LEFT, 57=CONTROL_RIGHT
const GK_ENTER := 58
# 59=META_LEFT, 60=META_RIGHT, 61=SHIFT_LEFT, 62=SHIFT_RIGHT
const GK_SPACE := 63
const GK_TAB := 64
# 65=CONVERT, 66=KANA_MODE, 67=NON_CONVERT
# Control Pad (68-74)
const GK_DELETE := 68
const GK_END := 69
# 70=HELP
const GK_HOME := 71
const GK_INSERT := 72
const GK_PAGE_DOWN := 73
const GK_PAGE_UP := 74
# Arrow Pad (75-78)
const GK_ARROW_DOWN := 75
const GK_ARROW_LEFT := 76
const GK_ARROW_RIGHT := 77
const GK_ARROW_UP := 78
# Numpad (79-119) — skipped
# Function Keys (120+)
const GK_ESCAPE := 120
const GK_F1 := 121
const GK_F2 := 122
const GK_F3 := 123
const GK_F4 := 124
const GK_F5 := 125
const GK_F6 := 126
const GK_F7 := 127
const GK_F8 := 128
const GK_F9 := 129
const GK_F10 := 130
const GK_F11 := 131
const GK_F12 := 132

# Ghostty key action constants
const GK_ACTION_PRESS := 1
const GK_ACTION_REPEAT := 2

# Ghostty modifier bitmask constants
const GK_MODS_SHIFT := (1 << 0)
const GK_MODS_CTRL := (1 << 1)
const GK_MODS_ALT := (1 << 2)
const GK_MODS_SUPER := (1 << 3)

## Map Godot KEY_* constants to ghostty key codes.
## Only keys that produce terminal output are mapped here.
var _godot_to_ghostty: Dictionary = {
	KEY_QUOTELEFT: GK_BACKQUOTE,
	KEY_BACKSLASH: GK_BACKSLASH,
	KEY_BRACKETLEFT: GK_BRACKET_LEFT,
	KEY_BRACKETRIGHT: GK_BRACKET_RIGHT,
	KEY_COMMA: GK_COMMA,
	KEY_0: GK_DIGIT_0, KEY_1: GK_DIGIT_1, KEY_2: GK_DIGIT_2, KEY_3: GK_DIGIT_3,
	KEY_4: GK_DIGIT_4, KEY_5: GK_DIGIT_5, KEY_6: GK_DIGIT_6, KEY_7: GK_DIGIT_7,
	KEY_8: GK_DIGIT_8, KEY_9: GK_DIGIT_9,
	KEY_EQUAL: GK_EQUAL,
	KEY_A: GK_A, KEY_B: GK_B, KEY_C: GK_C, KEY_D: GK_D,
	KEY_E: GK_E, KEY_F: GK_F, KEY_G: GK_G, KEY_H: GK_H,
	KEY_I: GK_I, KEY_J: GK_J, KEY_K: GK_K, KEY_L: GK_L,
	KEY_M: GK_M, KEY_N: GK_N, KEY_O: GK_O, KEY_P: GK_P,
	KEY_Q: GK_Q, KEY_R: GK_R, KEY_S: GK_S, KEY_T: GK_T,
	KEY_U: GK_U, KEY_V: GK_V, KEY_W: GK_W, KEY_X: GK_X,
	KEY_Y: GK_Y, KEY_Z: GK_Z,
	KEY_MINUS: GK_MINUS,
	KEY_PERIOD: GK_PERIOD,
	KEY_APOSTROPHE: GK_QUOTE,
	KEY_SEMICOLON: GK_SEMICOLON,
	KEY_SLASH: GK_SLASH,
	KEY_BACKSPACE: GK_BACKSPACE,
	KEY_ENTER: GK_ENTER,
	KEY_SPACE: GK_SPACE,
	KEY_TAB: GK_TAB,
	KEY_DELETE: GK_DELETE,
	KEY_END: GK_END,
	KEY_HOME: GK_HOME,
	KEY_INSERT: GK_INSERT,
	KEY_PAGEDOWN: GK_PAGE_DOWN,
	KEY_PAGEUP: GK_PAGE_UP,
	KEY_DOWN: GK_ARROW_DOWN,
	KEY_LEFT: GK_ARROW_LEFT,
	KEY_RIGHT: GK_ARROW_RIGHT,
	KEY_UP: GK_ARROW_UP,
	KEY_ESCAPE: GK_ESCAPE,
	KEY_F1: GK_F1, KEY_F2: GK_F2, KEY_F3: GK_F3, KEY_F4: GK_F4,
	KEY_F5: GK_F5, KEY_F6: GK_F6, KEY_F7: GK_F7, KEY_F8: GK_F8,
	KEY_F9: GK_F9, KEY_F10: GK_F10, KEY_F11: GK_F11, KEY_F12: GK_F12,
}


func _shortcut_input(event: InputEvent) -> void:
	if not _terminal_available or text_layer == null:
		return
	if event is InputEventKey:
		if not event.is_pressed(): return
		if event.ctrl_pressed and event.keycode == KEY_C:
			DisplayServer.clipboard_set(text_layer.get_selected_text())
		if event.ctrl_pressed and event.keycode == KEY_V:
			terminal.write_input(DisplayServer.clipboard_get())


func _gui_input(event: InputEvent) -> void:
	if not _terminal_available or text_layer == null:
		return

	# Scroll wheel → ghostty viewport scrolling
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			terminal.scroll_viewport(-3)
			_scrolled_up = true
			text_layer.queue_redraw()
			cursor_layer.queue_redraw()
			if _vscrollbar:
				_scrollbar_updating = true
				_vscrollbar.value = maxf(0, _vscrollbar.value - 3)
				_scrollbar_updating = false
			get_viewport().set_input_as_handled()
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			terminal.scroll_viewport(3)
			text_layer.queue_redraw()
			cursor_layer.queue_redraw()
			if _vscrollbar:
				_scrollbar_updating = true
				var max_scroll = _vscrollbar.max_value - _vscrollbar.page
				_vscrollbar.value = minf(max_scroll, _vscrollbar.value + 3)
				_scrollbar_updating = false
				if _vscrollbar.value >= max_scroll:
					_scrolled_up = false
			get_viewport().set_input_as_handled()
			return

	if text_layer.selection_active:
		if event is InputEventKey:
			if not (event.keycode == KEY_CTRL or event.keycode == KEY_ALT):
				text_layer.reset_selection.call_deferred()
		return

	if event is InputEventKey and event.pressed:
		# Minerva-specific clipboard/signal shortcuts (not terminal pass-through)
		if event.ctrl_pressed and event.keycode == KEY_C:
			terminal.write_input(char(3))
			get_viewport().set_input_as_handled()
			return
		if event.ctrl_pressed and event.keycode == KEY_V:
			terminal.write_input(DisplayServer.clipboard_get())
			get_viewport().set_input_as_handled()
			return

		# Build ghostty modifier bitmask
		var mods: int = 0
		if event.shift_pressed: mods |= GK_MODS_SHIFT
		if event.ctrl_pressed:  mods |= GK_MODS_CTRL
		if event.alt_pressed:   mods |= GK_MODS_ALT
		if event.meta_pressed:  mods |= GK_MODS_SUPER

		# Determine action
		var action: int = GK_ACTION_PRESS if not event.is_echo() else GK_ACTION_REPEAT

		# Map Godot keycode to ghostty key
		var gk: int = _godot_to_ghostty.get(event.keycode, GK_UNIDENTIFIED)

		# Build UTF-8 text from the event's unicode codepoint
		var utf8_text: String = ""
		if event.unicode > 0:
			utf8_text = char(event.unicode)

		# Snap ghostty viewport to bottom on any keypress
		if _scrolled_up:
			_scrolled_up = false
			terminal.scroll_viewport(0)
			text_layer.queue_redraw()

		# Try ghostty key encoder
		var encoded: PackedByteArray = terminal.encode_key(gk, action, mods, utf8_text)

		if encoded.size() > 0:
			terminal.write_input(encoded.get_string_from_utf8())
		elif event.unicode > 0:
			# Fallback: send raw character if encoder produced nothing
			terminal.write_input(char(event.unicode))

		get_viewport().set_input_as_handled()

# endregion


# region CursorLayer

class CursorLayer extends Control:
	var terminal: TerminalNew
	var blink_time: float = 0.5
	var elapsed: float = 0
	var cursor_visible: = true
	var cursor_style: int = 0  # 0=block, 1=bar, 2=underline
	var cursor_blink: bool = true

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		queue_redraw()

	func _process(delta: float) -> void:
		if not cursor_blink:
			if not cursor_visible:
				cursor_visible = true
				queue_redraw()
			return
		elapsed += delta
		if elapsed > 0.5:
			elapsed = 0
			cursor_visible = not cursor_visible
			queue_redraw()

	func _draw() -> void:
		if not terminal or not terminal._terminal_available:
			return
		if not terminal.terminal.has_method("get_cursor"):
			return

		var cursor_info: Dictionary = terminal.terminal.get_cursor()
		if cursor_info.is_empty():
			return

		var cx: int = cursor_info.get("x", 0)
		var cy: int = cursor_info.get("y", 0)
		var visible: bool = cursor_info.get("visible", true)
		var tc: TerminalConfig = SingletonObject.get_terminal_config()
		var fg: Color = tc.get_theme_fg_bg().fg

		if visible and cursor_visible:
			var cw: float = terminal.char_width
			var lh: float = terminal.line_height
			match cursor_style:
				0:  # Block
					var draw_pos = Vector2(cx * cw, (cy + 1) * lh)
					draw_string(terminal.font, draw_pos, CURSOR_CHAR, HORIZONTAL_ALIGNMENT_LEFT, -1, terminal.font_size, fg)
				1:  # Bar
					var bar_x = cx * cw
					var bar_y = cy * lh
					draw_rect(Rect2(bar_x, bar_y, 2, lh), fg)
				2:  # Underline
					var ul_x = cx * cw
					var ul_y = (cy + 1) * lh - 2
					draw_rect(Rect2(ul_x, ul_y, cw, 2), fg)

# endregion


# region TextLayer

class TextLayer extends Control:
	var terminal: TerminalNew

	var _selection_background_color: = Color.WHITE_SMOKE
	var _draw_debug_printed: bool = false
	var _draw_count: int = 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = CursorShape.CURSOR_IBEAM
		queue_redraw()

	var selection_active: bool:
		get: return abs(_selection_start - _selection_end) > Vector2i.ZERO

	var _selecting: = false
	var _selection_start: Vector2i
	var _selection_end: Vector2i
	var p1: Vector2i
	var p2: Vector2i

	func reset_selection():
		_selection_start = Vector2i.ZERO
		_selection_end = Vector2i.ZERO
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if _selecting:
			accept_event()

		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_selecting = event.is_pressed()
			accept_event()
			if not _selecting: return

			var row: = maxi(0, floori(event.position.y / terminal.line_height))
			var column: = maxi(0, floori(event.position.x / terminal.char_width))

			p1 = Vector2i(column, row)
			p2 = p1

			var check = func(a, b):
				return a.y < b.y or (a.y == b.y and a.x < b.x)

			_selection_start = p1 if check.call(p1, p2) else p2
			_selection_end = p1 if check.call(p2, p1) else p2
			_selecting = event.is_pressed()
			queue_redraw()

		if _selecting:
			if event is InputEventMouseMotion:
				var row: = maxi(0, floori(event.position.y / terminal.line_height))
				var column: = maxi(0, floori(event.position.x / terminal.char_width))
				p2 = Vector2i(column, row)
				var check = func(a, b):
					return a.y < b.y or (a.y == b.y and a.x < b.x)
				_selection_start = p1 if check.call(p1, p2) else p2
				_selection_end = p1 if check.call(p2, p1) else p2
				queue_redraw()

		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed == false:
				_create_context_menu(event.global_position)

	func _draw() -> void:
		if not terminal or not terminal._terminal_available:
			return
		if not terminal.terminal.has_method("get_cell"):
			return

		var cols: int = terminal._cols
		var rows: int = terminal._rows
		var cw: float = terminal.char_width
		var lh: float = terminal.line_height

		# Clear background with configured color
		var tc: TerminalConfig = SingletonObject.get_terminal_config()
		var cfg_fg: Color = tc.get_theme_fg_bg().fg
		var cfg_bg: Color = tc.get_theme_fg_bg().bg
		draw_rect(Rect2(Vector2.ZERO, size), cfg_bg)

		_draw_count += 1

		for row in range(rows):
			var y_pos: float = (row + 1) * lh
			var row_top: float = row * lh

			for col in range(cols):
				var cell: Dictionary = terminal.terminal.get_cell(col, row)
				if cell.is_empty():
					continue

				var codepoint: int = cell.get("codepoint", 0)
				var wide_state: int = cell.get("wide", 0)

				# Skip spacer tail cells (right half of wide chars)
				if wide_state == 3:
					continue

				var fg: Color = terminal.resolve_color(cell, "fg", cfg_fg)
				var bg: Color = terminal.resolve_color(cell, "bg", Color.TRANSPARENT)

				if cell.get("inverse", false):
					var tmp = fg
					fg = bg if bg.a > 0 else cfg_bg
					bg = tmp

				# Snap to exact grid position — never accumulate float error
				var x_pos: float = col * cw
				var cell_w: float = cw * (2 if wide_state == 1 else 1)

				# Draw background
				if bg.a > 0:
					draw_rect(Rect2(x_pos, row_top, cell_w, lh), bg)

				# Draw selection highlight
				if selection_active:
					var in_sel = false
					if _selection_start.y == _selection_end.y:
						in_sel = row == _selection_start.y and col >= _selection_start.x and col <= _selection_end.x
					elif row == _selection_start.y:
						in_sel = col >= _selection_start.x
					elif row == _selection_end.y:
						in_sel = col <= _selection_end.x
					elif row > _selection_start.y and row < _selection_end.y:
						in_sel = true
					if in_sel:
						draw_rect(Rect2(x_pos, row_top, cw, lh), _selection_background_color)

				# Draw character at exact grid position
				if codepoint > 32:
					var ch: String = char(codepoint)
					# Use draw_char for pixel-perfect grid placement
					draw_char_outline(terminal.font, Vector2(x_pos, y_pos), ch, terminal.font_size, 2, Color.BLACK)
					draw_char(terminal.font, Vector2(x_pos, y_pos), ch, terminal.font_size, fg)

		custom_minimum_size.y = rows * lh

	var _context_menu: PopupMenu
	func _create_context_menu(at: Vector2) -> void:
		if not _context_menu:
			_context_menu = PopupMenu.new()
			_context_menu.initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
			add_child(_context_menu)
			_create_context_menu_item("Copy", KEY_CTRL, 0, func(): DisplayServer.clipboard_set(get_selected_text()); reset_selection())
			_create_context_menu_item("Paste", KEY_V, 1, func(): terminal.terminal.write_input(DisplayServer.clipboard_get()))
			_create_context_menu_item("Zoom In", KEY_PLUS, 2, func(): terminal.font_size += 1; terminal._update_font_metrics(); queue_redraw())
			_create_context_menu_item("Zoom Out", KEY_MINUS, 3, func(): terminal.font_size -= 1; terminal._update_font_metrics(); queue_redraw())
		_context_menu.popup()
		_context_menu.position = at + Vector2(0, _context_menu.size.y / 2.0)

	func _create_context_menu_item(text: String, keycode: Key, id: int, callback: Callable = Callable()):
		var shortcut: = Shortcut.new()
		var event: = InputEventKey.new()
		event.keycode = keycode
		event.ctrl_pressed = true
		shortcut.events.append(event)
		_context_menu.add_shortcut(shortcut, id)
		_context_menu.set_item_text(id, text)
		if callback.is_valid():
			_context_menu.id_pressed.connect(func(id_: int): if id_ == id: callback.call())

	func get_selected_text() -> String:
		if not terminal or not terminal._terminal_available:
			return ""
		if not terminal.terminal.has_method("get_plain_text"):
			return ""
		# Use libghostty-vt plain text extraction
		return terminal.terminal.get_plain_text()

# endregion
