class_name SpreadsheetRowGeometry
extends RefCounted
## The single source of vertical row geometry for the cells canvas and the
## row headers. Rows hidden by the sheet's AutoFilter are skipped: they take
## no height, so the next shown row starts where the hidden run began. Every
## function takes and returns underlying row indices, so hit-tests, scrolling,
## selection and editing keep addressing the real rows. Bulk edits over a
## selection use shown_rows_in() so they leave hidden rows untouched.
##
## All y values are in content space (before scroll offset is subtracted).

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")


static func is_row_shown(data: SpreadsheetDataScript, row: int) -> bool:
	return data.autofilter.is_row_visible(row)


## Drawn height of `row`: its stored height when shown, 0 when hidden.
static func shown_height(data: SpreadsheetDataScript, row: int) -> float:
	return data.get_row_height(row) if is_row_shown(data, row) else 0.0


## Top y of `row` (rows past row_count are clamped to the end of the sheet).
static func row_y(data: SpreadsheetDataScript, row: int) -> float:
	var y := 0.0
	for r in range(mini(row, data.row_count)):
		y += shown_height(data, r)
	return y


## Shown row containing `y`. Coordinates above the first shown row return that
## row and coordinates past the last shown row return that row (so dragging
## outside the grid and scrolling past the end still resolve); -1 when no row
## is shown.
static func row_at_y(data: SpreadsheetDataScript, y: float) -> int:
	var current_y := 0.0
	var last_shown := -1
	for row in range(data.row_count):
		if not is_row_shown(data, row):
			continue
		var height := data.get_row_height(row)
		if y < current_y + height:
			return row
		current_y += height
		last_shown = row
	return last_shown


## Shown row whose bottom edge lies within `tolerance` of `y`, or -1.
static func row_bottom_near_y(data: SpreadsheetDataScript, y: float, tolerance: float) -> int:
	var bottom := 0.0
	for row in range(data.row_count):
		if not is_row_shown(data, row):
			continue
		bottom += data.get_row_height(row)
		if absf(y - bottom) <= tolerance:
			return row
	return -1


## Height of all shown rows.
static func total_height(data: SpreadsheetDataScript) -> float:
	return row_y(data, data.row_count)


## Last shown row, or -1 when every row is hidden.
static func last_shown_row(data: SpreadsheetDataScript) -> int:
	for row in range(data.row_count - 1, -1, -1):
		if is_row_shown(data, row):
			return row
	return -1


## Shown rows in [from_row, to_row), ascending.
static func shown_rows_in(data: SpreadsheetDataScript, from_row: int, to_row: int) -> PackedInt32Array:
	var rows := PackedInt32Array()
	for row in range(from_row, to_row):
		if is_row_shown(data, row):
			rows.append(row)
	return rows


## Number of rows shown.
static func visible_row_count(data: SpreadsheetDataScript) -> int:
	return data.autofilter.visible_count()
