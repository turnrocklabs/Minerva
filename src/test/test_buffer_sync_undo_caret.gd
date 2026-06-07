extends SceneTree
## Regression tests for P1 (DCR 019ea404ffcd): the buffer→editor sync contract.
##
## Locks two things the re-scoped P1 depends on:
##  1. Godot's CodeEdit records `text =` as a SINGLE undoable step that also
##     preserves prior keystroke history — so agent/MCP edits arriving via the
##     buffer stay undoable on the existing Undo button. If a future Godot
##     upgrade changes this, this test fails and we revisit the design.
##  2. The caret/scroll save→assign→clamp-restore sequence used by
##     Editor._set_code_edit_text_from_buffer preserves the caret across an
##     agent-driven replace (and clamps when the new text is shorter).
##
## Run: godot --headless --path src --script test/test_buffer_sync_undo_caret.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== buffer-sync undo + caret tests ===")
	test_text_assign_is_single_undo_step_preserving_history()
	test_caret_preserved_across_replace()
	test_caret_clamped_when_text_shrinks()
	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _eq(desc: String, actual: Variant, expected: Variant) -> void:
	_check("%s (got %s, want %s)" % [desc, str(actual), str(expected)], actual == expected)


# Mirrors Editor._set_code_edit_text_from_buffer's caret/scroll preservation so
# the contract is testable without booting the full Editor scene.
func _sync(ce: CodeEdit, new_text: String) -> void:
	if ce.text == new_text:
		return
	var caret_line := ce.get_caret_line()
	var caret_col := ce.get_caret_column()
	var v_scroll := ce.scroll_vertical
	var h_scroll := ce.scroll_horizontal
	ce.text = new_text
	var last_line := maxi(0, ce.get_line_count() - 1)
	caret_line = clampi(caret_line, 0, last_line)
	caret_col = clampi(caret_col, 0, ce.get_line(caret_line).length())
	ce.set_caret_line(caret_line)
	ce.set_caret_column(caret_col)
	ce.scroll_vertical = v_scroll
	ce.scroll_horizontal = h_scroll


func test_text_assign_is_single_undo_step_preserving_history() -> void:
	print("test_text_assign_is_single_undo_step_preserving_history:")
	var ce := CodeEdit.new()
	get_root().add_child(ce)
	ce.text = "v0"
	ce.clear_undo_history()
	ce.set_caret_line(0); ce.set_caret_column(2)
	ce.insert_text_at_caret("A")   # human keystroke
	ce.insert_text_at_caret("B")   # human keystroke  -> v0AB
	_eq("history built", ce.text, "v0AB")
	ce.text = "AGENT EDIT"         # the buffer-driven sync (agent edit)
	ce.undo()
	_eq("undo reverts agent edit as one step", ce.text, "v0AB")
	ce.undo()
	_eq("prior keystroke history preserved (1)", ce.text, "v0A")
	ce.undo()
	_eq("prior keystroke history preserved (2)", ce.text, "v0")
	ce.redo()
	_eq("redo restores keystroke", ce.text, "v0A")
	ce.queue_free()


func test_caret_preserved_across_replace() -> void:
	print("test_caret_preserved_across_replace:")
	var ce := CodeEdit.new()
	get_root().add_child(ce)
	ce.text = "aaa\nbbb\nccc"
	ce.set_caret_line(1); ce.set_caret_column(2)   # inside "bbb"
	_sync(ce, "xxx\nyyy\nzzz")                       # agent replace, same shape
	_eq("caret line preserved", ce.get_caret_line(), 1)
	_eq("caret col preserved", ce.get_caret_column(), 2)
	ce.queue_free()


func test_caret_clamped_when_text_shrinks() -> void:
	print("test_caret_clamped_when_text_shrinks:")
	var ce := CodeEdit.new()
	get_root().add_child(ce)
	ce.text = "aaa\nbbb\nccc"
	ce.set_caret_line(2); ce.set_caret_column(3)   # end of "ccc"
	_sync(ce, "hi")                                 # shrinks to one short line
	_eq("caret line clamped to last line", ce.get_caret_line(), 0)
	_eq("caret col clamped to line length", ce.get_caret_column(), 2)
	ce.queue_free()
