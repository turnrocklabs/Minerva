extends SceneTree
## Spreadsheet AutoFilter changes as the filter popup makes them: apply a
## value set, add a second column's text filter, undo, redo, clear one
## column, clear all. Drives SpreadsheetAutoFilterActions (the path the popup
## and column-header menu use) with a real SpreadsheetHistory, and replays
## undo/redo exactly as the editor's history dispatch does.
##
## ORACLE: the expected visible rows after each step are computed in this file
## from the fixture strings and the criteria active at that step, never by
## asking the filter. Distinct values are checked against the fixture column,
## including values on rows hidden by another column's filter.
##
## Run:
##   godot --headless --path ~/github/Minerva/src --script test/test_spreadsheet_autofilter_undo.gd

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetHistoryScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetHistory.gd")
const Actions := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetAutoFilterActions.gd")

const ROWS := 15
const COLS := 4
const STATUS_COL := 1
const NOTE_COL := 2
const ALLOWED_STATUS := ["open", ""]
const NOTE_NEEDLE := "urgent"

## Row 0 is the header; rows 1..9 are data. [name, status, note]
const FIXTURE := [
	["Name", "Status", "Note"],
	["a", "open", "URGENT fix"],
	["b", "closed", "urgent"],
	["c", "", "not urgent"],
	["d", "open", "later"],
	["e", "open", "urgent"],
	["f", "", "someday"],
	["g", "wip", "urgent too"],
	["h", "", "Urgent"],
	["i", "open", ""],
]
## Rows given a yellow fill, to check formatting stays with its logical row.
const FILLED_ROWS := [2, 4, 7]
const FILL := Color(1.0, 1.0, 0.0, 1.0)

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	print("=== spreadsheet autofilter undo ===\n")
	test_popup_changes_undo_redo_and_clear()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s" % description)


## Independent oracle: sheet rows shown under the given criteria. Rows past
## the fixture are outside the filter range and always shown.
func _expected_visible(status_filter: bool, note_filter: bool) -> Array[int]:
	var visible: Array[int] = []
	for r in range(ROWS):
		var keep := true
		if r >= 1 and r < FIXTURE.size():
			var status: String = FIXTURE[r][STATUS_COL]
			var note: String = FIXTURE[r][NOTE_COL]
			if status_filter:
				keep = keep and ALLOWED_STATUS.has(status)
			if note_filter:
				keep = keep and note.to_lower().contains(NOTE_NEEDLE)
		if keep:
			visible.append(r)
	return visible


func _actual_visible(data: SpreadsheetDataScript) -> Array[int]:
	var visible: Array[int] = []
	for r in range(ROWS):
		if data.autofilter.is_row_visible(r):
			visible.append(r)
	return visible


## Undo/redo the way SpreadsheetEditor._apply_history_action dispatches it.
func _undo(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript) -> void:
	var action := history.undo()
	_check("undo pops an AUTOFILTER action",
		action != null and action.type == SpreadsheetHistoryScript.ActionType.AUTOFILTER)
	if action:
		Actions.replay(data, action, true)


func _redo(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript) -> void:
	var action := history.redo()
	_check("redo pops an AUTOFILTER action",
		action != null and action.type == SpreadsheetHistoryScript.ActionType.AUTOFILTER)
	if action:
		Actions.replay(data, action, false)


func _step(label: String, data: SpreadsheetDataScript, status_filter: bool, note_filter: bool) -> void:
	var expected := _expected_visible(status_filter, note_filter)
	var actual := _actual_visible(data)
	_check("%s: visible rows %s == %s" % [label, actual, expected], actual == expected)
	# The count only exists while a filter range does.
	var data_rows := FIXTURE.size() - 1 if data.autofilter.is_active() else 0
	var expected_shown := 0
	for r in expected:
		if data_rows > 0 and r >= 1 and r < FIXTURE.size():
			expected_shown += 1
	_check("%s: row count %d of %d" % [label, expected_shown, data_rows],
		Actions.row_counts(data) == Vector2i(expected_shown, data_rows))


func test_popup_changes_undo_redo_and_clear() -> void:
	print("test_popup_changes_undo_redo_and_clear:")
	var data := SpreadsheetDataScript.new(ROWS, COLS)
	for r in range(FIXTURE.size()):
		for c in range(FIXTURE[r].size()):
			data.set_cell_value(r, c, FIXTURE[r][c])
	for r: int in FILLED_ROWS:
		data.get_cell(r, 0).bg_color = FILL
	var history := SpreadsheetHistoryScript.new()

	# Enable from the column-header menu with the header row..last data row
	# selected; the range is exactly that selection.
	var selection: Array[Rect2i] = [Rect2i(0, 0, 3, FIXTURE.size())]
	_check("enable records a change", Actions.enable(data, history, selection[0]))
	_check("range is the selection", data.autofilter.filter_range == selection[0])
	_step("enabled, no criteria", data, false, false)

	# Distinct values come from the fixture column, blank included, blank last.
	var expected_status: Array = []
	for r in range(1, FIXTURE.size()):
		var v: String = FIXTURE[r][STATUS_COL]
		if not expected_status.has(v):
			expected_status.append(v)
	var listed := Array(Actions.distinct_values(data, STATUS_COL))
	_check("status distinct values %s cover the fixture exactly" % [listed],
		listed.size() == expected_status.size() and expected_status.all(func(v: String) -> bool: return listed.has(v)))
	_check("blank is listed last", listed.back() == "")

	# 1. Apply a value set (the popup's OK with some values unchecked).
	Actions.set_values(data, history, STATUS_COL, PackedStringArray(ALLOWED_STATUS))
	_step("status value set", data, true, false)

	# The note column's list still offers values from rows the status filter hides.
	var notes := Array(Actions.distinct_values(data, NOTE_COL))
	var all_notes := true
	for r in range(1, FIXTURE.size()):
		all_notes = all_notes and notes.has(FIXTURE[r][NOTE_COL])
	_check("second column lists values of hidden rows too", all_notes)

	# 2. A second column filter narrows further (AND).
	Actions.set_text(data, history, NOTE_COL, NOTE_NEEDLE)
	_step("status + note", data, true, true)

	# Re-applying the same criterion is not a new history entry.
	var depth := history.get_undo_count()
	_check("unchanged apply records nothing",
		not Actions.set_text(data, history, NOTE_COL, NOTE_NEEDLE) and history.get_undo_count() == depth)

	# 3. Undo, then redo.
	_undo(data, history)
	_step("after undo", data, true, false)
	_check("undo restored the note column to no criterion", not data.autofilter.has_criterion(NOTE_COL))
	_redo(data, history)
	_step("after redo", data, true, true)
	_check("redo restored the text criterion",
		data.autofilter.get_criterion(NOTE_COL) == {"type": "text", "text": NOTE_NEEDLE})

	# 4. Clear one column, then clear all.
	Actions.clear_column(data, history, STATUS_COL)
	_step("status cleared", data, false, true)
	Actions.clear_all(data, history)
	_step("all cleared", data, false, false)
	_check("clear all keeps the range", data.autofilter.filter_range == selection[0])

	# Original values, order and fill are untouched on every row.
	var intact := true
	for r in range(FIXTURE.size()):
		for c in range(3):
			intact = intact and data.get_cell_display(r, c) == str(FIXTURE[r][c])
		var cell = data.get_cell_if_exists(r, 0)
		var filled: bool = cell != null and cell.bg_color == FILL
		intact = intact and filled == FILLED_ROWS.has(r)
	_check("values, order and fill are unchanged after clear all", intact)

	# Undo walks back through clear all and clear column to both filters.
	_undo(data, history)
	_step("undo clear all", data, false, true)
	_undo(data, history)
	_step("undo clear column", data, true, true)

	# Remove the filter entirely, and undo brings it back with its criteria.
	Actions.remove(data, history)
	_check("remove turns the filter off", not data.autofilter.is_active())
	_step("removed", data, false, false)
	_undo(data, history)
	_check("undo remove restores the range", data.autofilter.filter_range == selection[0])
	_step("undo remove", data, true, true)
