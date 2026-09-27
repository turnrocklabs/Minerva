extends SceneTree
## Spreadsheet AutoFilter: filter model, shared row geometry, save/reopen, a
## structural edit under an active filter, and editor bulk edits (delete,
## fill-down) over a selection that spans hidden rows.
##
## ORACLE: the fixture below is a plain array of row strings. The expected
## visible rows are computed in this file by applying the two criteria to
## those strings directly (a value set that includes blank, and a
## case-insensitive text match), never by asking the filter. Row positions
## are likewise summed here from the fixture's own row heights over the
## expected-visible rows. After a row insert, the expected sheet is the
## fixture with a blank row spliced in, and every fixture row must be found
## with its values and bold flag on its shifted row. For bulk edits, hidden
## rows must still hold their fixture strings, shown rows in the selection
## must be blank (delete) or carry the top shown row's value (fill-down), and
## undo must bring back the fixture strings. Boundary rows for row_at_y and
## the rows a resize handle picks under a frozen row while scrolled are
## derived from the fixture's hidden set and row heights.
##
## Run:
##   godot --headless --path ~/github/Minerva/src --script test/test_spreadsheet_autofilter.gd

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const RowGeometry := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetRowGeometry.gd")
const CellsCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/CellsCanvas.gd")
const RowHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/RowHeaders.gd")
const SpreadsheetEditorScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetEditor.gd")

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
	await test_bulk_edits_skip_hidden_rows()
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

	# row_at_y at the boundaries: above the grid clamps to the first shown row,
	# an exact row edge belongs to the row below it, past the end clamps to the
	# last shown row. Expected rows come from the fixture's hidden set.
	var first_shown := -1
	var last_shown := -1
	for r in range(ROWS):
		if not expected_hidden.has(r):
			if first_shown < 0:
				first_shown = r
			last_shown = r
	var after_first := first_shown + 1
	while expected_hidden.has(after_first):
		after_first += 1
	_check("row_at_y(-1) is the first shown row %d" % first_shown,
		RowGeometry.row_at_y(data, -1.0) == first_shown)
	_check("row_at_y at the first shown row's bottom edge is row %d" % after_first,
		RowGeometry.row_at_y(data, _height_of(first_shown)) == after_first)
	_check("row_at_y past the end is the last shown row %d" % last_shown,
		RowGeometry.row_at_y(data, y + 100.0) == last_shown)

	# Resize handles with frozen row 0 while scrolled: the frozen row's bottom
	# edge sits at its own height on screen, and a scrollable row's bottom edge
	# sits at its content bottom minus the scroll. The scroll is chosen so the
	# target row's content bottom maps onto row 0's screen edge.
	var target_bottom := 0.0
	for r in range(target + 1):
		if not expected_hidden.has(r):
			target_bottom += _height_of(r)
	var next_shown := target + 1
	while expected_hidden.has(next_shown):
		next_shown += 1
	var next_bottom := target_bottom + _height_of(next_shown)
	var scroll := target_bottom - _height_of(0)
	headers.set_scroll_offset(scroll)
	var resized: Array[int] = []
	headers.row_resize_started.connect(func(row: int) -> void: resized.append(row))
	_click(headers, Vector2(10, _height_of(0)))
	_check("scrolled by %.0f, row 0's bottom edge resizes frozen row 0: %s" % [scroll, resized],
		resized == [0])
	resized.clear()
	_click(headers, Vector2(10, next_bottom - scroll))
	_check("scrolled by %.0f, row %d's bottom edge resizes row %d: %s" % [scroll, next_shown, next_shown, resized],
		resized == [next_shown])
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


func test_bulk_edits_skip_hidden_rows() -> void:
	print("test_bulk_edits_skip_hidden_rows:")
	var data := _build_sheet()
	_apply_filters(data)
	var hidden := _expected_hidden(FIXTURE)
	var editor := SpreadsheetEditorScript.new()
	editor.spreadsheet_data = data
	root.add_child(editor)
	await process_frame

	# Delete over rows 1..5, columns 0..2 (the rectangle spans hidden rows).
	var first := 1
	var last := 5
	_check("delete rectangle spans a hidden and a shown row",
		range(first, last + 1).any(func(r: int) -> bool: return hidden.has(r)) \
		and range(first, last + 1).any(func(r: int) -> bool: return not hidden.has(r)))
	editor.cells_canvas.select_range(first, 0, last, 2)
	editor._delete_selection()
	var hidden_intact := true
	var shown_cleared := true
	for r in range(first, last + 1):
		for c in range(3):
			var text := data.get_cell_display(r, c)
			if hidden.has(r):
				hidden_intact = hidden_intact and text == str(FIXTURE[r][c])
			else:
				shown_cleared = shown_cleared and text.is_empty()
	_check("delete leaves hidden rows' values intact", hidden_intact)
	_check("delete clears the shown rows in the selection", shown_cleared)

	editor.undo()
	var restored := true
	for r in range(FIXTURE.size()):
		for c in range(3):
			restored = restored and data.get_cell_display(r, c) == str(FIXTURE[r][c])
	_check("undo restores every cleared row", restored)

	# Fill down column 0 over rows 5..8: the top shown row fills the shown
	# rows below it; hidden rows keep their names.
	var fill_first := 5
	var fill_last := 8
	editor.cells_canvas.select_range(fill_first, 0, fill_last, 0)
	editor._fill_down()
	var fill_ok := true
	for r in range(fill_first + 1, fill_last + 1):
		var expected: String = FIXTURE[r][0] if hidden.has(r) else FIXTURE[fill_first][0]
		fill_ok = fill_ok and data.get_cell_display(r, 0) == expected
	_check("fill-down writes shown rows only (hidden rows keep their names)", fill_ok)
	_check("fill-down range spans a hidden row",
		range(fill_first + 1, fill_last + 1).any(func(r: int) -> bool: return hidden.has(r)))
	editor.queue_free()
	await process_frame
