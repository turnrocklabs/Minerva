extends SceneTree
## Terminal copy takes the highlighted text, not the whole screen (bug
## 01a0ca18bfd3). Two levels: TerminalNew's static selection_text over a fake viewport
## grid, and the real TextLayer wiring (selection, context menu, copy
## actions) over a fake native terminal that counts which read it gets.
##
## Run: godot --headless --path src --script test/test_terminal_selection_copy.gd
##
## ORACLES
##   selection_text:
##   - a partial single-row selection copies exactly those columns;
##   - a multi-row selection copies from the start column to row end, whole
##     rows between, and up to the end column on the last row;
##   - trailing blanks on each row are dropped, inner blanks kept;
##   - a wide character's spacer cell is skipped, so it appears once;
##   - an end column past the grid is clamped to the last column.
##   TextLayer wiring:
##   - get_selected_text reads the selected cells and never the whole-screen
##     export (the original bug); with no selection it is empty and reads nothing;
##   - a drag made backwards (bottom-right to top-left) copies the same text as
##     the same drag made forwards;
##   - opening the menu with a right-click keeps the selection; "Copy selection"
##     is enabled with a selection and disabled without one;
##   - choosing "Copy selection" reads cells only, "Copy screen" reads the
##     whole-screen export; each clears the highlight afterwards.
##
## TerminalNew names the SingletonObject autoload, so it is load()ed at run
## time and used duck-typed, never named as a compile-time global: a --script
## test compiles before autoloads register (see test_background_terminals.gd).

const TERMINAL_SCRIPT_PATH := "res://Scripts/UI/Controls/TerminalNew.gd"
var Terminal: GDScript

var _passed := 0
var _failed := 0

const ROWS := ["hello world", "second line", "  indented  ", "中文 ok"]
const COLS := 12
const CELL := 10.0


## Stands in for the Terminal extension node: the ROWS grid, and a count of
## which read was used.
class FakeNative extends RefCounted:
	var cell_calls := 0
	var plain_calls := 0

	func get_cell(col: int, row: int) -> Dictionary:
		cell_calls += 1
		return grid_cell(col, row)

	func get_plain_text() -> String:
		plain_calls += 1
		return "WHOLE SCREEN"

	func scroll_viewport(_lines: int) -> void:
		pass

	## Each row's text left-aligned; wide characters as a wide=1 cell followed
	## by a wide=3 spacer; blanks as codepoint 0.
	static func grid_cell(col: int, row: int) -> Dictionary:
		var cells: Array = []
		for ch in ROWS[row]:
			if ch.unicode_at(0) > 0x2E80:
				cells.append({"codepoint": ch.unicode_at(0), "wide": 1})
				cells.append({"codepoint": 0, "wide": 3})
			else:
				cells.append({"codepoint": ch.unicode_at(0), "wide": 0})
		while cells.size() < COLS:
			cells.append({"codepoint": 0, "wide": 0})
		return cells[col]


class FakeSession extends RefCounted:
	var terminal
	var terminal_available := true

	func get_cols() -> int:
		return COLS

	func get_rows() -> int:
		return ROWS.size()


func _check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("PASS: %s" % what)
	else:
		_failed += 1
		print("FAIL: %s %s" % [what, detail])


func _check_text(what: String, got: String, want: String) -> void:
	_check(what, got == want, "got %s, want %s" % [JSON.stringify(got), JSON.stringify(want)])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	Terminal = load(TERMINAL_SCRIPT_PATH)
	_test_selection_text()
	_test_text_layer_wiring()
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)


func _test_selection_text() -> void:
	var get_cell := func(col: int, row: int) -> Dictionary: return FakeNative.grid_cell(col, row)
	_check_text("partial row", Terminal.selection_text(get_cell, Vector2i(0, 0), Vector2i(4, 0), COLS), "hello")
	_check_text("inner columns", Terminal.selection_text(get_cell, Vector2i(6, 0), Vector2i(10, 0), COLS), "world")
	_check_text("multi row", Terminal.selection_text(get_cell, Vector2i(6, 0), Vector2i(5, 1), COLS),
			"world\nsecond")
	_check_text("whole rows between", Terminal.selection_text(get_cell, Vector2i(6, 0), Vector2i(3, 2), COLS),
			"world\nsecond line\n  in")
	_check_text("trailing blanks dropped", Terminal.selection_text(get_cell, Vector2i(0, 2), Vector2i(11, 2), COLS),
			"  indented")
	_check_text("wide character once", Terminal.selection_text(get_cell, Vector2i(0, 3), Vector2i(7, 3), COLS),
			"中文 ok")
	_check_text("end past the grid clamps", Terminal.selection_text(get_cell, Vector2i(0, 1), Vector2i(40, 1), COLS),
			"second line")


## A TextLayer wired to a TerminalNew whose session holds the fake native terminal.
func _make_layer() -> Array:
	var native := FakeNative.new()
	var session := FakeSession.new()
	session.terminal = native
	var term = Terminal.new()
	term._auto_create_session = false
	term._session = session
	term.line_height = CELL
	term.char_width = CELL
	var layer = Terminal.TextLayer.new()
	layer.terminal = term
	term.text_layer = layer
	root.add_child(layer)
	return [layer, native, term]


func _drag(layer, from: Vector2i, to: Vector2i) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(from) * CELL + Vector2(1, 1)
	layer._gui_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(to) * CELL + Vector2(1, 1)
	layer._gui_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = motion.position
	layer._gui_input(release)


func _right_click(layer) -> void:
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		click.pressed = pressed
		click.global_position = Vector2(5, 5)
		layer._gui_input(click)


func _test_text_layer_wiring() -> void:
	var made: Array = _make_layer()
	var layer = made[0]
	var native: FakeNative = made[1]

	_check_text("no selection copies nothing", layer.get_selected_text(), "")
	_check("no selection reads nothing", native.cell_calls == 0 and native.plain_calls == 0)

	_drag(layer, Vector2i(6, 0), Vector2i(5, 1))
	_check_text("forward drag", layer.get_selected_text(), "world\nsecond")
	_check("selection reads cells, never the whole-screen export",
			native.cell_calls > 0 and native.plain_calls == 0,
			"cells=%d plain=%d" % [native.cell_calls, native.plain_calls])
	_drag(layer, Vector2i(5, 1), Vector2i(6, 0))
	_check_text("backward drag copies the same text", layer.get_selected_text(), "world\nsecond")

	var start: Vector2i = layer._selection_start
	var end: Vector2i = layer._selection_end
	_right_click(layer)
	var menu: PopupMenu = layer._context_menu
	_check("right-click keeps the selection", layer._selection_start == start and layer._selection_end == end)
	_check("Copy selection enabled with a selection",
			not menu.is_item_disabled(menu.get_item_index(layer.MENU_COPY)))
	_check_text("menu labels", "%s|%s" % [menu.get_item_text(menu.get_item_index(layer.MENU_COPY)),
			menu.get_item_text(menu.get_item_index(layer.MENU_COPY_SCREEN))], "Copy selection|Copy screen")

	native.cell_calls = 0
	menu.id_pressed.emit(layer.MENU_COPY)
	_check("Copy selection reads cells only", native.cell_calls > 0 and native.plain_calls == 0,
			"cells=%d plain=%d" % [native.cell_calls, native.plain_calls])
	_check("Copy selection clears the highlight", not layer.selection_active)

	menu.hide()
	_right_click(layer)
	_check("Copy selection disabled without a selection",
			menu.is_item_disabled(menu.get_item_index(layer.MENU_COPY)))
	menu.id_pressed.emit(layer.MENU_COPY_SCREEN)
	_check("Copy screen reads the whole-screen export", native.plain_calls == 1,
			"plain=%d" % native.plain_calls)
	menu.hide()
	layer.queue_free()
	made[2].free()
