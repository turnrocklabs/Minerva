extends SceneTree
## Spreadsheet AutoFilter through MCP: enable, set a value set (blank
## included), add a text criterion, read, clear one column, clear all and
## remove, all by calling MCPSpreadsheetFilterTools.handle() on a fixture
## sheet with a real SpreadsheetHistory. The module's find_sheet points at the
## fixture instead of an editor tab; nothing else is replaced.
##
## ORACLE: expected visible rows are computed in this file from the fixture
## strings and the criteria active at each step. A second fixture sheet driven
## through SpreadsheetAutoFilterActions (the UI path) must give the same
## criteria and visible rows. Every read must carry the scope field. Range
## and criterion-type rejections expect the error strings written here from
## the fixture's dimensions.
##
## Run:
##   godot --headless --path ~/github/Minerva/src --script test/test_mcp_spreadsheet_filter_tools.gd

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetHistoryScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetHistory.gd")
const Actions := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetAutoFilterActions.gd")
const ModuleScript := preload("res://Scripts/Services/MCP/Modules/MCPSpreadsheetFilterTools.gd")

const EDITOR := "Tasks"
const ROWS := 14
const COLS := 4
const STATUS_COL := 1  # column B, 0-based
const NOTE_COL := 2    # column C, 0-based
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

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	print("=== MCP spreadsheet filter tools ===\n")
	test_set_read_clear_round_trip()
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


func _make_sheet() -> SpreadsheetDataScript:
	var data := SpreadsheetDataScript.new(ROWS, COLS)
	for r in range(FIXTURE.size()):
		for c in range(FIXTURE[r].size()):
			data.set_cell_value(r, c, FIXTURE[r][c])
	return data


## Independent oracle: 1-based sheet rows of the data rows shown.
func _expected_visible(status_filter: bool, note_filter: bool) -> Array:
	var visible: Array = []
	for r in range(1, FIXTURE.size()):
		var status: String = FIXTURE[r][STATUS_COL]
		var note: String = FIXTURE[r][NOTE_COL]
		var keep := true
		if status_filter:
			keep = keep and ALLOWED_STATUS.has(status)
		if note_filter:
			keep = keep and note.to_lower().contains(NOTE_NEEDLE)
		if keep:
			visible.append(r + 1)
	return visible


## 1-based data rows the UI-path sheet shows. With the filter off every row
## below the used range's first row shows.
func _ui_visible(data: SpreadsheetDataScript) -> Array:
	var visible: Array = []
	var span := Actions.data_row_span(data)
	if not data.autofilter.is_active():
		var used := data.get_used_range()
		span = Vector2i(used.position.y + 1, used.end.y)
	for r in range(span.x, span.y):
		if data.autofilter.is_row_visible(r):
			visible.append(r + 1)
	return visible


## Check one MCP result against the oracle and the UI-path sheet.
func _step(label: String, result: Dictionary, ui: SpreadsheetDataScript,
		status_filter: bool, note_filter: bool) -> void:
	_check("%s: success" % label, result.get("success", false) == true)
	var expected := _expected_visible(status_filter, note_filter)
	var rows: Array = Array(result.get("visible_rows", []))
	_check("%s: visible_rows %s == %s" % [label, rows, expected], rows == expected)
	_check("%s: visible_count" % label, result.get("visible_count", -1) == expected.size())
	_check("%s: total_rows" % label, result.get("total_rows", -1) == FIXTURE.size() - 1)
	var filtered := status_filter or note_filter
	_check("%s: scope is %s" % [label, "visible" if filtered else "all"],
		result.get("scope", "") == ("visible" if filtered else "all"))
	_check("%s: same rows as the UI path" % label, rows == _ui_visible(ui))
	var ui_criteria: Array = []
	for col: int in ui.autofilter.filtered_columns():
		var entry := ui.autofilter.get_criterion(col)
		entry["column"] = col + 1
		entry["column_label"] = SpreadsheetDataScript.get_column_label(col)
		ui_criteria.append(entry)
	_check("%s: same criteria as the UI path" % label, result.get("criteria", []) == ui_criteria)


func _read(tools) -> Dictionary:
	return tools.handle("minerva_spreadsheet_autofilter_get", {"editor_name": EDITOR})


func test_set_read_clear_round_trip() -> void:
	print("test_set_read_clear_round_trip:")
	var data := _make_sheet()
	var history := SpreadsheetHistoryScript.new()
	var ui := _make_sheet()
	var ui_history := SpreadsheetHistoryScript.new()

	var tools = ModuleScript.new(null)
	tools.find_sheet = func(name: String) -> ModuleScript.SheetTarget:
		var target := ModuleScript.SheetTarget.new()
		if name == EDITOR:
			target.data = data
			target.history = history
		else:
			target.error = "Spreadsheet editor not found: %s" % name
		return target

	# Before enabling, the read covers every data row of the used range.
	_step("no filter", _read(tools), ui, false, false)
	_check("no filter: enabled is false", _read(tools).get("enabled", true) == false)

	var r: Dictionary = tools.handle("minerva_spreadsheet_autofilter_enable", {"editor_name": EDITOR, "range": "A1:C10"})
	Actions.enable(ui, ui_history, Rect2i(0, 0, 3, FIXTURE.size()))
	_step("enabled", r, ui, false, false)
	_check("enabled: filter_range A1:C10", r.get("filter_range", "") == "A1:C10")

	# A value set that keeps blanks; column B is 2 at the API.
	r = tools.handle("minerva_spreadsheet_autofilter_set",
		{"editor_name": EDITOR, "column": STATUS_COL + 1, "values": ALLOWED_STATUS})
	Actions.set_values(ui, ui_history, STATUS_COL, PackedStringArray(ALLOWED_STATUS))
	_step("status values", r, ui, true, false)
	_step("status values (read)", _read(tools), ui, true, false)

	r = tools.handle("minerva_spreadsheet_autofilter_set",
		{"editor_name": EDITOR, "column": NOTE_COL + 1, "contains": NOTE_NEEDLE})
	Actions.set_text(ui, ui_history, NOTE_COL, NOTE_NEEDLE)
	_step("status + note", r, ui, true, true)

	# The MCP change landed in the sheet's history: undo restores one column.
	_check("three MCP changes recorded", history.get_undo_count() == 3)
	var action := history.undo()
	Actions.replay(data, action, true)
	_step("after undo (read)", _read(tools), _ui_status_only(), true, false)
	Actions.replay(data, history.redo(), false)
	_step("after redo (read)", _read(tools), ui, true, true)

	r = tools.handle("minerva_spreadsheet_autofilter_clear", {"editor_name": EDITOR, "column": STATUS_COL + 1})
	Actions.clear_column(ui, ui_history, STATUS_COL)
	_step("status cleared", r, ui, false, true)

	r = tools.handle("minerva_spreadsheet_autofilter_clear", {"editor_name": EDITOR})
	Actions.clear_all(ui, ui_history)
	_step("all cleared", r, ui, false, false)
	_check("all cleared: range kept", r.get("filter_range", "") == "A1:C10")

	r = tools.handle("minerva_spreadsheet_autofilter_clear", {"editor_name": EDITOR, "remove": true})
	Actions.remove(ui, ui_history)
	_step("removed", r, ui, false, false)
	_check("removed: enabled is false", r.get("enabled", true) == false)

	# Errors use the shared error shape.
	var err: Dictionary = tools.handle("minerva_spreadsheet_autofilter_set",
		{"editor_name": EDITOR, "column": 2, "contains": "x"})
	_check("set without a filter is an error", err.get("success", true) == false and err.has("error"))
	err = tools.handle("minerva_spreadsheet_autofilter_get", {"editor_name": "Nope"})
	_check("unknown editor is an error",
		err.get("error", "") == "Spreadsheet editor not found: Nope")

	# Explicit ranges must fit the fixture sheet (ROWS x COLS); criterion
	# inputs must be strings. Each rejection leaves the filter unchanged.
	var outside_col := SpreadsheetDataScript.get_column_label(COLS) + "1:" \
		+ SpreadsheetDataScript.get_column_label(COLS) + "10"
	err = tools.handle("minerva_spreadsheet_autofilter_enable", {"editor_name": EDITOR, "range": outside_col})
	_check("range %s past the last column is an error: %s" % [outside_col, err.get("error", "")],
		err.get("error", "") == "Range %s is outside the sheet (%d rows, %d columns)" % [outside_col, ROWS, COLS])
	var outside_row := "A1:C%d" % (ROWS + 1)
	err = tools.handle("minerva_spreadsheet_autofilter_enable", {"editor_name": EDITOR, "range": outside_row})
	_check("range %s past the last row is an error" % outside_row,
		err.get("error", "") == "Range %s is outside the sheet (%d rows, %d columns)" % [outside_row, ROWS, COLS])
	_check("rejected ranges left the filter off", not data.autofilter.is_active())
	tools.handle("minerva_spreadsheet_autofilter_enable", {"editor_name": EDITOR, "range": "A1:C10"})
	err = tools.handle("minerva_spreadsheet_autofilter_set",
		{"editor_name": EDITOR, "column": STATUS_COL + 1, "values": [null]})
	_check("values [null] is an error", err.get("error", "") == "values must be an array of strings")
	err = tools.handle("minerva_spreadsheet_autofilter_set",
		{"editor_name": EDITOR, "column": NOTE_COL + 1, "contains": 123})
	_check("contains 123 is an error", err.get("error", "") == "contains must be a string")
	_check("rejected criteria added none", data.autofilter.filtered_columns().is_empty())
	tools.handle("minerva_spreadsheet_autofilter_clear", {"editor_name": EDITOR, "remove": true})

	# Cell values are untouched by every step.
	var intact := true
	for row in range(FIXTURE.size()):
		for c in range(3):
			intact = intact and data.get_cell_display(row, c) == str(FIXTURE[row][c])
	_check("values unchanged", intact)


## A fresh UI-path sheet holding only the status criterion, for comparing the
## state an undo of the note criterion should restore.
func _ui_status_only() -> SpreadsheetDataScript:
	var sheet := _make_sheet()
	Actions.enable(sheet, null, Rect2i(0, 0, 3, FIXTURE.size()))
	Actions.set_values(sheet, null, STATUS_COL, PackedStringArray(ALLOWED_STATUS))
	return sheet
