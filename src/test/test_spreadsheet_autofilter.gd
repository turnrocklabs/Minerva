extends SceneTree
## Spreadsheet AutoFilter: filter model, shared row geometry, save/reopen and
## a structural edit under an active filter.
##
## ORACLE: the fixture below is a plain array of row strings. The expected
## visible rows are computed in this file by applying the two criteria to
## those strings directly (a value set that includes blank, and a
## case-insensitive text match), never by asking the filter. Row positions
## are likewise summed here from the fixture's own row heights over the
## expected-visible rows. After a row insert, the expected sheet is the
## fixture with a blank row spliced in, and every fixture row must be found
## with its values and bold flag on its shifted row.
##
## Run:
##   godot --headless --path ~/github/Minerva/src --script test/test_spreadsheet_autofilter.gd

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const RowGeometry := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetRowGeometry.gd")
const CellsCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/CellsCanvas.gd")
const RowHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/RowHeaders.gd")

const ROWS := 20
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
## Taller rows make the geometry non-uniform.
const ROW_HEIGHTS := {2: 40.0, 5: 32.0, 8: 50.0}
## Rows whose name cell is bold, to check formatting follows the row.
const BOLD_ROWS := [3, 5, 8]

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	print("=== spreadsheet autofilter ===\n")
	await test_filter_geometry_persistence_and_insert()
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


## Independent oracle: is a fixture data row kept by both criteria?
func _row_passes(values: Array) -> bool:
	var status: String = values[STATUS_COL]
	var note: String = values[NOTE_COL]
	return ALLOWED_STATUS.has(status) and note.to_lower().contains(NOTE_NEEDLE)


## Expected set of hidden sheet rows for `rows` (fixture layout, row 0 header).
func _expected_hidden(rows: Array) -> Array[int]:
	var hidden: Array[int] = []
	for r in range(1, rows.size()):
		if not _row_passes(rows[r]):
			hidden.append(r)
	return hidden


func _actual_hidden(data: SpreadsheetDataScript) -> Array[int]:
	var hidden: Array[int] = []
	for r in range(data.row_count):
		if not data.autofilter.is_row_visible(r):
			hidden.append(r)
	return hidden


func _build_sheet() -> SpreadsheetDataScript:
	var data := SpreadsheetDataScript.new(ROWS, COLS)
	for r in range(FIXTURE.size()):
		for c in range(FIXTURE[r].size()):
			data.set_cell_value(r, c, FIXTURE[r][c])
	for r: int in ROW_HEIGHTS:
		data.set_row_height(r, ROW_HEIGHTS[r])
	for r: int in BOLD_ROWS:
		data.get_cell(r, 0).bold = true
	return data


func _apply_filters(data: SpreadsheetDataScript) -> void:
	data.autofilter.set_range(Rect2i(0, 0, 3, FIXTURE.size()))
	data.autofilter.set_value_filter(STATUS_COL, PackedStringArray(ALLOWED_STATUS))
	data.autofilter.set_text_filter(NOTE_COL, NOTE_NEEDLE)


func _height_of(r: int) -> float:
	return ROW_HEIGHTS.get(r, SpreadsheetDataScript.DEFAULT_ROW_HEIGHT)


func _click(control: Control, pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	control._gui_input(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	control._gui_input(release)


func test_filter_geometry_persistence_and_insert() -> void:
	print("test_filter_geometry_persistence_and_insert:")

	# An unfiltered sheet writes no autofilter key.
	_check("unfiltered sheet saves without an autofilter key",
		not _build_sheet().to_dict().has("autofilter"))

	var data := _build_sheet()
	_apply_filters(data)
	var expected_hidden := _expected_hidden(FIXTURE)
	_check("oracle hides some rows and keeps some", expected_hidden.size() > 0 \
		and expected_hidden.size() < FIXTURE.size() - 1)
	_check("visible set matches the fixture oracle: %s" % [_actual_hidden(data)],
		_actual_hidden(data) == expected_hidden)
	_check("visible_count = row_count - expected hidden",
		data.autofilter.visible_count() == ROWS - expected_hidden.size())
	_check("geometry helper reports the same visible count",
		RowGeometry.visible_row_count(data) == ROWS - expected_hidden.size())
	_check("header row is never hidden", data.autofilter.is_row_visible(0))

	# Geometry: hidden rows take no height; shown rows stack by their own heights.
	var geometry_ok := true
	var y := 0.0
	for r in range(ROWS):
		if not is_equal_approx(RowGeometry.row_y(data, r), y):
			geometry_ok = false
		if expected_hidden.has(r):
			geometry_ok = geometry_ok and RowGeometry.shown_height(data, r) == 0.0
		else:
			y += _height_of(r)
	_check("row_y skips hidden rows and sums shown heights", geometry_ok)
	_check("total height covers shown rows only", is_equal_approx(RowGeometry.total_height(data), y))

	# Clicking just inside the first shown row after a hidden run addresses that
	# underlying row in both the cells canvas and the row headers.
	var target := -1
	for r in range(2, FIXTURE.size()):
		if not expected_hidden.has(r) and expected_hidden.has(r - 1):
			target = r
			break
	_check("fixture has a shown row directly after a hidden run", target > 0)
	var target_y := RowGeometry.row_y(data, target) + 2.0

	data.frozen_rows = 1
	var canvas := CellsCanvasScript.new()
	root.add_child(canvas)
	canvas.size = Vector2(800, 600)
	canvas.set_data(data)
	var selected: Array[Vector2i] = []
	canvas.cell_selected.connect(func(row: int, col: int) -> void: selected.append(Vector2i(col, row)))
	_click(canvas, Vector2(SpreadsheetDataScript.DEFAULT_COLUMN_WIDTH * NOTE_COL + 5.0, target_y))
	_check("cells canvas click below a hidden run selects row %d col %d: %s" % [target, NOTE_COL, selected],
		selected.size() == 1 and selected[0] == Vector2i(NOTE_COL, target))

	var headers := RowHeadersScript.new()
	root.add_child(headers)
	headers.size = Vector2(50, 600)
	headers.set_data(data)
	var clicked_rows: Array[int] = []
	headers.row_clicked.connect(func(row: int) -> void: clicked_rows.append(row))
	# Click mid-row so the resize handle at the row's bottom edge is not hit.
	_click(headers, Vector2(10, RowGeometry.row_y(data, target) + _height_of(target) / 2.0))
	_check("row headers click below a hidden run picks row %d: %s" % [target, clicked_rows],
		clicked_rows == [target])

	# Frozen row 0 still freezes the header row.
	selected.clear()
	_click(canvas, Vector2(5.0, 2.0))
	_check("frozen header row still resolves to row 0", selected.size() == 1 and selected[0] == Vector2i(0, 0))
	canvas.queue_free()
	headers.queue_free()
	await process_frame

	# Save and reopen through the native dictionary + JSON path.
	var saved: Dictionary = data.to_dict()
	_check("filtered sheet saves an autofilter key", saved.has("autofilter"))
	var parsed: Variant = JSON.parse_string(JSON.stringify(saved))
	var reopened := SpreadsheetDataScript.new()
	reopened.load_from_dict(parsed as Dictionary)
	_check("reopened range matches", reopened.autofilter.filter_range == Rect2i(0, 0, 3, FIXTURE.size()))
	_check("reopened value-set criterion (with blank) matches",
		reopened.autofilter.get_criterion(STATUS_COL) == {"type": "values", "values": ALLOWED_STATUS})
	_check("reopened text criterion matches",
		reopened.autofilter.get_criterion(NOTE_COL) == {"type": "text", "text": NOTE_NEEDLE})
	_check("reopened has no other criteria",
		reopened.autofilter.filtered_columns() == PackedInt32Array([STATUS_COL, NOTE_COL]))
	_check("reopened visible set matches the oracle", _actual_hidden(reopened) == expected_hidden)

	# Insert a row inside the filtered range; every row keeps its values,
	# formatting follows its row, and visibility is recomputed from values.
	var insert_at := 4
	reopened.insert_row(insert_at)
	var shifted: Array = FIXTURE.duplicate(true)
	shifted.insert(insert_at, ["", "", ""])
	var aligned := true
	for r in range(shifted.size()):
		for c in range(3):
			if reopened.get_cell_display(r, c) != str(shifted[r][c]):
				aligned = false
	_check("no row lost or misaligned after insert", aligned)
	var bold_ok := true
	for r: int in BOLD_ROWS:
		var moved := r + 1 if r >= insert_at else r
		var cell = reopened.get_cell_if_exists(moved, 0)
		bold_ok = bold_ok and cell != null and cell.bold
	_check("bold formatting followed its rows", bold_ok)
	_check("filter range grew by the inserted row",
		reopened.autofilter.filter_range == Rect2i(0, 0, 3, FIXTURE.size() + 1))
	var expected_after := _expected_hidden(shifted)
	_check("visible set after insert matches the oracle: %s" % [_actual_hidden(reopened)],
		_actual_hidden(reopened) == expected_after)
	_check("visible_count after insert",
		reopened.autofilter.visible_count() == reopened.row_count - expected_after.size())
