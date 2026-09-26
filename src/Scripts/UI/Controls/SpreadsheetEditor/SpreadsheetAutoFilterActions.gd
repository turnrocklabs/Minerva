class_name SpreadsheetAutoFilterActions
extends RefCounted
## Undoable AutoFilter changes and the queries the filter popup needs.
##
## Every user-facing filter change (popup apply, clear column, clear all,
## enabling or removing the filter from the column-header menu) goes through
## one of the change functions here. Each snapshots the filter before and
## after the change and records one AUTOFILTER history action when they
## differ; replay() restores a snapshot on undo/redo. The filter model itself
## is SpreadsheetAutoFilter; hidden rows follow from its criteria.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetHistoryScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetHistory.gd")


# --- Undoable changes ---------------------------------------------------------
# Each returns true when the filter changed (and a history entry was recorded
# if `history` is not null).

## Turn the filter on over `filter_range` (header row first).
static func enable(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript, filter_range: Rect2i) -> bool:
	return _change(data, history, func() -> void: data.autofilter.set_range(filter_range))


## Remove the filter range and every criterion.
static func remove(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript) -> bool:
	return _change(data, history, data.autofilter.clear)


## Keep rows whose displayed text in `col` is one of `allowed` ("" = blank).
static func set_values(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript, col: int, allowed: PackedStringArray) -> bool:
	return _change(data, history, func() -> void: data.autofilter.set_value_filter(col, allowed))


## Keep rows whose displayed text in `col` contains `needle` (case-insensitive).
static func set_text(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript, col: int, needle: String) -> bool:
	return _change(data, history, func() -> void: data.autofilter.set_text_filter(col, needle))


static func clear_column(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript, col: int) -> bool:
	return _change(data, history, func() -> void: data.autofilter.clear_column(col))


## Remove every criterion; the filter range (and its dropdowns) stays.
static func clear_all(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript) -> bool:
	return _change(data, history, data.autofilter.clear_criteria)


## Apply an AUTOFILTER history action: the "before" snapshot on undo, the
## "after" snapshot on redo.
static func replay(data: SpreadsheetDataScript, action: SpreadsheetHistoryScript.HistoryAction, is_undo: bool) -> void:
	var state: Dictionary = action.data["old_state" if is_undo else "new_state"]
	data.autofilter.load_from_dict(state)


# --- Queries ------------------------------------------------------------------

## Distinct displayed values of `col` over every data row of the filter range,
## hidden rows included, so a second filter can always widen. "" stands for
## blank and sorts last; the rest sort naturally, case-insensitively.
static func distinct_values(data: SpreadsheetDataScript, col: int) -> PackedStringArray:
	var seen: Dictionary = {}
	var span := data_row_span(data)
	for row in range(span.x, span.y):
		var text := data.get_cell_display(row, col)
		seen["" if text.strip_edges().is_empty() else text] = true
	var values: Array = seen.keys()
	values.sort_custom(func(a: String, b: String) -> bool:
		if a.is_empty() != b.is_empty():
			return b.is_empty()
		return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(values)


## [first, end) of the filter range's data rows (below its header row and any
## sheet header rows), clamped to the sheet. Empty when the filter is off.
static func data_row_span(data: SpreadsheetDataScript) -> Vector2i:
	var filter := data.autofilter
	if not filter.is_active():
		return Vector2i.ZERO
	var first := maxi(filter.filter_range.position.y + 1, data.header_row_count)
	var end := mini(filter.filter_range.end.y, data.row_count)
	return Vector2i(first, maxi(first, end))


## (shown, total) data rows of the filter range, for the "N of M rows" count.
static func row_counts(data: SpreadsheetDataScript) -> Vector2i:
	var span := data_row_span(data)
	var shown := 0
	for row in range(span.x, span.y):
		if data.autofilter.is_row_visible(row):
			shown += 1
	return Vector2i(shown, span.y - span.x)


## Range to filter when the user enables AutoFilter on column `col`: a
## selection that contains `col` and spans several rows but not whole columns
## (its rows clipped to the used rows), otherwise the sheet's used range
## widened to include `col`, as Excel does for a single cell or a column
## header. The top row is the header. Returns an empty Rect2i when there is
## no data row to filter.
static func range_for_enable(data: SpreadsheetDataScript, selection: Array[Rect2i], col: int) -> Rect2i:
	var used := data.get_used_range()
	if used.size.y < 2:
		return Rect2i()
	for rect in selection:
		var whole_columns := rect.position.y == 0 and rect.end.y >= data.row_count
		if rect.size.y > 1 and not whole_columns and col >= rect.position.x and col < rect.end.x:
			var top := maxi(rect.position.y, used.position.y)
			var bottom := mini(rect.end.y, used.end.y)
			return Rect2i(rect.position.x, top, rect.size.x, bottom - top) if bottom - top > 1 else Rect2i()
	var first_col := mini(used.position.x, col)
	var end_col := maxi(used.end.x, col + 1)
	return Rect2i(first_col, used.position.y, end_col - first_col, used.size.y)


# --- Internals ----------------------------------------------------------------

## Serialized filter state; {} when no range is set.
static func _snapshot(data: SpreadsheetDataScript) -> Dictionary:
	return data.autofilter.to_dict() if data.autofilter.is_active() else {}


static func _change(data: SpreadsheetDataScript, history: SpreadsheetHistoryScript, mutate: Callable) -> bool:
	var before := _snapshot(data)
	mutate.call()
	var after := _snapshot(data)
	if before == after:
		return false
	if history != null:
		history.record_autofilter(before, after)
	return true
