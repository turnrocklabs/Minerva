extends SceneTree
## Paste and the context menu reach the terminal a person clicked, once.
##
## Run: godot --headless --path src --script test/test_terminal_input_routing.gd
##      (scripts/dev-test.sh --display adds the popup-placement checks)
##
## Two real TerminalNew views, one shown and one hidden as a background tab
## is, sit under a chat composer. Every event goes through the root
## viewport's own routing (push_input): hit-testing, click-to-focus, _gui_input
## and _shortcut_input, as a person's clicks and keys do. Each view's session
## is a stand-in that records writes, so the oracle is WHICH terminal received
## a paste and how many times — the headless display server has no clipboard,
## so the pasted text itself may be empty.
##
## ORACLES
##   - a click on a terminal's text gives that terminal keyboard focus;
##   - Ctrl+V pastes exactly once, into the focused terminal only — with or
##     without a selection, never into the hidden one;
##   - with focus elsewhere (the composer, a button) no terminal pastes;
##   - Ctrl+C with no selection sends one ^C to the focused terminal only;
##   - with a display: the right-click menu opens at the click, on screen,
##     even when the window is not at the screen origin.

const TERMINAL_SCRIPT_PATH := "res://Scripts/UI/Controls/TerminalNew.gd"
var TerminalScript: GDScript

var _passed := 0
var _failed := 0


## Stands in for the native terminal: a blank 40×10 grid.
class FakeNative extends RefCounted:
	func get_cell(_col: int, _row: int) -> Dictionary:
		return {"codepoint": 0x61, "wide": 0}

	func get_plain_text() -> String:
		return ""

	func get_scroll_info() -> Dictionary:
		return {"total_rows": 10, "viewport_rows": 10, "is_at_bottom": true}

	func get_cursor() -> Dictionary:
		return {"x": 0, "y": 0}

	func scroll_viewport(_lines: int) -> void:
		pass

	func encode_key(_key: int, _action: int, _mods: int, _text: String) -> PackedByteArray:
		return PackedByteArray()


## Stands in for TerminalSession: records every human write. The view reads
## and assigns its grid fields and connects/disconnects these signals.
class FakeSession extends RefCounted:
	signal vt_state_changed
	signal output_received
	signal prompt_start
	signal prompt_end
	signal bell_rung
	signal shell_exited
	var terminal := FakeNative.new()
	var terminal_available := true
	var started := true
	var bell_serial := 0
	var _cols := 40
	var _rows := 10
	var writes: Array[String] = []

	func get_cols() -> int:
		return 40

	func get_rows() -> int:
		return 10

	func resize(_cols: int, _rows: int) -> void:
		pass

	func note_human_input() -> void:
		pass

	func write_human_input(text: String) -> void:
		writes.append(text)


func _check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("PASS: %s" % what)
	else:
		_failed += 1
		printerr("FAIL: %s %s" % [what, detail])


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	TerminalScript = load(TERMINAL_SCRIPT_PATH)
	root.size = Vector2i(1000, 700)  # the headless root starts at 64×64
	await process_frame

	var stage := VBoxContainer.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(stage)
	var composer := LineEdit.new()
	var button := Button.new()
	button.text = "elsewhere"
	stage.add_child(composer)
	stage.add_child(button)
	var tabs := PanelContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.add_child(tabs)
	var shown = _add_terminal(tabs, true)
	var hidden = _add_terminal(tabs, false)
	for _i in 4:
		await process_frame
	var a: FakeSession = shown._session
	var b: FakeSession = hidden._session

	composer.grab_focus()
	_key(KEY_V)
	_check("focus in the composer: no terminal pastes", a.writes.is_empty() and b.writes.is_empty(),
		"%s / %s" % [a.writes, b.writes])

	var at: Vector2 = shown.text_layer.get_global_rect().get_center()
	_click(at, MOUSE_BUTTON_LEFT)
	_check("a click on the text focuses that terminal", shown.has_focus(),
		"focus owner %s" % root.gui_get_focus_owner())

	_key(KEY_V)
	_check("Ctrl+V pastes once, into the clicked terminal only", a.writes.size() == 1 and b.writes.is_empty(),
		"%s / %s" % [a.writes, b.writes])

	_key(KEY_C)
	_check("Ctrl+C without a selection sends one ^C to it", a.writes.size() == 2 and a.writes[1] == char(3)
		and b.writes.is_empty(), "%s / %s" % [a.writes, b.writes])

	_drag(at, at + Vector2(shown.char_width * 4, 0))
	_check("the drag made a selection", shown.text_layer.selection_active)
	_key(KEY_V)
	_check("Ctrl+V with a selection still pastes once, only there", a.writes.size() == 3 and b.writes.is_empty(),
		"%s / %s" % [a.writes, b.writes])
	shown.text_layer.reset_selection()

	button.grab_focus()
	_key(KEY_V)
	_check("focus on another control: no terminal pastes", a.writes.size() == 3 and b.writes.is_empty(),
		"%s / %s" % [a.writes, b.writes])

	await _check_menu_placement(shown, at)

	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)


func _add_terminal(parent: Control, visible: bool):
	var view = TerminalScript.create()
	view._auto_create_session = false
	view._session = FakeSession.new()
	view.visible = visible
	parent.add_child(view)
	return view


func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.ctrl_pressed = true
		event.pressed = pressed
		root.push_input(event)


func _click(at: Vector2, button: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = at
		event.global_position = at
		root.push_input(event)


func _drag(from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	root.push_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = to
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	root.push_input(release)


## The menu must open where the person right-clicked, inside the screen, both
## as a separate OS window (Minerva's setting) and embedded in the root
## viewport. The window is moved off the screen origin first, where viewport
## and screen coordinates differ. Needs a display: headless has no windows.
func _check_menu_placement(view, at: Vector2) -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP: right-click menu placement needs a display (scripts/dev-test.sh --display)")
		return
	root.position = Vector2i(120, 80)
	await process_frame
	var click := at + Vector2(0, view.text_layer.size.y / 2.0 - 2.0)  # near the pane's bottom
	for embedded in [false, true]:
		root.gui_embed_subwindows = embedded
		var layer = view.text_layer
		if layer._context_menu:
			layer._context_menu.free()
			layer._context_menu = null
		_click(click, MOUSE_BUTTON_RIGHT)
		await process_frame
		var menu: PopupMenu = layer._context_menu
		var mode := "embedded" if embedded else "native window"
		_check("%s: right-click opens the menu" % mode, menu != null and menu.visible)
		if menu == null:
			continue
		# Expected position, from the OS window's own position: an embedded
		# menu lives in root-viewport coordinates, a native one on the screen.
		var expected := Vector2i(click) if embedded \
			else Vector2i(click) + DisplayServer.window_get_position()
		var bounds := Rect2i(Vector2i.ZERO, root.size) if embedded \
			else DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
		var rect := Rect2i(menu.position, menu.size)
		_check("%s: the menu lies inside its bounds" % mode, bounds.encloses(rect), "%s in %s" % [rect, bounds])
		_check("%s: the menu opens at the click (or is only shifted up to fit)" % mode,
			rect.position.x == expected.x and (rect.position.y == expected.y or rect.end.y == bounds.end.y),
			"menu %s, click %s" % [rect, expected])
		menu.hide()
	root.gui_embed_subwindows = false
