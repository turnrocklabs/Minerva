class_name SpreadsheetAutoFilter
extends RefCounted
## Per-column filter criteria over a filter range whose first row is the
## header. Rows inside the range that fail any column's criterion are hidden;
## hiding is a view concern only, the sheet's cells and rows are untouched.
##
## SpreadsheetData owns one instance (always present; inactive until a range
## is set) and calls attach() so the filter can read displayed cell text.
## Visibility is cached and re-evaluated lazily after any data or structure
## change of the owning sheet, so hidden rows always follow the cell values
## rather than stored row indices.
##
## Row geometry that skips hidden rows lives in SpreadsheetRowGeometry.

## Emitted when the range or any criterion changes.
signal changed()

## One column's criterion. VALUES keeps rows whose displayed text is in
## `values` ("" stands for a blank cell); TEXT keeps rows whose displayed text
## contains `text`, case-insensitively.
class ColumnCriterion:
	enum Kind { VALUES, TEXT }

	var kind: Kind = Kind.VALUES
	var values: PackedStringArray = PackedStringArray()
	var text: String = ""

	func matches(display_text: String) -> bool:
		if kind == Kind.TEXT:
			return text.is_empty() or display_text.to_lower().contains(text.to_lower())
		var key := "" if display_text.strip_edges().is_empty() else display_text
		return values.has(key)

	func to_dict() -> Dictionary:
		if kind == Kind.TEXT:
			return {"type": "text", "text": text}
		return {"type": "values", "values": Array(values)}

	static func from_dict(d: Dictionary) -> ColumnCriterion:
		var c := ColumnCriterion.new()
		if str(d.get("type", "values")) == "text":
			c.kind = Kind.TEXT
			c.text = str(d.get("text", ""))
		else:
			for v: Variant in d.get("values", []):
				c.values.append(str(v))
		return c


## Filter range: x = first column, y = header row, size includes the header
## row. A zero-sized range means no filter.
var filter_range: Rect2i = Rect2i()

## Column index (absolute sheet column) -> ColumnCriterion
var _criteria: Dictionary = {}

## Owning SpreadsheetData, held weakly so the sheet can own this filter
## without a reference cycle.
var _sheet: WeakRef = null

## Rows currently hidden (row -> true); rebuilt when _dirty.
var _hidden: Dictionary = {}
var _dirty: bool = true


## Bind to the owning sheet. The sheet must provide get_cell_display(row, col),
## row_count, header_row_count and the data_changed / structure_changed signals.
func attach(sheet: RefCounted) -> void:
	_sheet = weakref(sheet)
	sheet.connect("data_changed", invalidate)
	sheet.connect("structure_changed", invalidate)
	invalidate()


func is_active() -> bool:
	return filter_range.size.x > 0 and filter_range.size.y > 0


## Set the filter range (header row first). Criteria on columns outside the
## new range are dropped.
func set_range(new_range: Rect2i) -> void:
	filter_range = new_range
	for col: int in _criteria.keys():
		if col < filter_range.position.x or col >= filter_range.end.x:
			_criteria.erase(col)
	_notify()


## Remove the range and every criterion.
func clear() -> void:
	filter_range = Rect2i()
	_criteria.clear()
	_notify()


## Keep rows whose displayed text in `col` is one of `allowed` ("" = blank).
func set_value_filter(col: int, allowed: PackedStringArray) -> void:
	var c := ColumnCriterion.new()
	c.kind = ColumnCriterion.Kind.VALUES
	c.values = allowed.duplicate()
	_set_criterion(col, c)


## Keep rows whose displayed text in `col` contains `needle` (case-insensitive).
func set_text_filter(col: int, needle: String) -> void:
	var c := ColumnCriterion.new()
	c.kind = ColumnCriterion.Kind.TEXT
	c.text = needle
	_set_criterion(col, c)


func clear_column(col: int) -> void:
	if _criteria.erase(col):
		_notify()


## Remove every criterion but keep the filter_range.
func clear_criteria() -> void:
	_criteria.clear()
	_notify()


func has_criterion(col: int) -> bool:
	return _criteria.has(col)


## Serialized form of one column's criterion, or {} when the column has none.
func get_criterion(col: int) -> Dictionary:
	if not _criteria.has(col):
		return {}
	return (_criteria[col] as ColumnCriterion).to_dict()


func filtered_columns() -> PackedInt32Array:
	var cols := PackedInt32Array(_criteria.keys())
	cols.sort()
	return cols


## True when `row` is shown. Header rows (row < header_row_count), the range's
## own header row and rows outside the range are always shown.
func is_row_visible(row: int) -> bool:
	if _criteria.is_empty():
		return true
	_refresh()
	return not _hidden.has(row)


## Number of sheet rows (of row_count) currently shown.
func visible_count() -> int:
	var sheet := _get_sheet()
	if sheet == null:
		return 0
	var total: int = sheet.get("row_count")
	if _criteria.is_empty():
		return total
	_refresh()
	return total - _hidden.size()


## Mark cached visibility stale; the next query re-evaluates every row.
func invalidate() -> void:
	_dirty = true


# --- Structural edits of the sheet -----------------------------------------
# The sheet calls these so the range and criteria keep covering the same
# logical rows and columns. Visibility itself is re-evaluated from cell values.

func on_row_inserted(at_row: int) -> void:
	if not is_active():
		return
	if at_row <= filter_range.position.y:
		filter_range.position.y += 1
	elif at_row < filter_range.end.y:
		filter_range.size.y += 1
	invalidate()


func on_row_deleted(row: int) -> void:
	if not is_active():
		return
	if row < filter_range.position.y:
		filter_range.position.y -= 1
	elif row == filter_range.position.y:
		clear()
		return
	elif row < filter_range.end.y:
		filter_range.size.y -= 1
	invalidate()


func on_column_inserted(at_col: int) -> void:
	if not is_active():
		return
	if at_col <= filter_range.position.x:
		filter_range.position.x += 1
	elif at_col < filter_range.end.x:
		filter_range.size.x += 1
	else:
		return
	_shift_criteria(at_col, 1)
	invalidate()


func on_column_deleted(col: int) -> void:
	if not is_active():
		return
	if col < filter_range.position.x:
		filter_range.position.x -= 1
	elif col < filter_range.end.x:
		filter_range.size.x -= 1
		_criteria.erase(col)
		if filter_range.size.x <= 0:
			clear()
			return
	else:
		return
	_shift_criteria(col + 1, -1)
	invalidate()


# --- Persistence ------------------------------------------------------------

func to_dict() -> Dictionary:
	var cols: Array = []
	for col: int in filtered_columns():
		var entry := get_criterion(col)
		entry["col"] = col
		cols.append(entry)
	return {
		"range": [filter_range.position.x, filter_range.position.y, filter_range.size.x, filter_range.size.y],
		"columns": cols,
	}


## Load from to_dict() output; an empty dictionary leaves the filter inactive.
func load_from_dict(d: Dictionary) -> void:
	filter_range = Rect2i()
	_criteria.clear()
	var r: Array = d.get("range", [])
	if r.size() == 4:
		filter_range = Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
	for entry: Variant in d.get("columns", []):
		if entry is Dictionary:
			var col := int((entry as Dictionary).get("col", -1))
			if col >= 0:
				_criteria[col] = ColumnCriterion.from_dict(entry)
	_notify()


# --- Internals --------------------------------------------------------------

func _set_criterion(col: int, c: ColumnCriterion) -> void:
	if col < filter_range.position.x or col >= filter_range.end.x:
		push_warning("SpreadsheetAutoFilter: column %d is outside the filter range" % col)
		return
	_criteria[col] = c
	_notify()


## Move every criterion keyed at or after `from_col` by `delta` columns.
func _shift_criteria(from_col: int, delta: int) -> void:
	var moved: Dictionary = {}
	for col: int in _criteria.keys():
		moved[col + delta if col >= from_col else col] = _criteria[col]
	_criteria = moved


func _notify() -> void:
	invalidate()
	changed.emit()


func _get_sheet() -> RefCounted:
	if _sheet == null:
		return null
	return _sheet.get_ref() as RefCounted


func _refresh() -> void:
	if not _dirty:
		return
	_dirty = false
	_hidden.clear()
	var sheet := _get_sheet()
	if sheet == null or not is_active():
		return
	var header_rows: int = sheet.get("header_row_count")
	var row_count: int = sheet.get("row_count")
	var first := maxi(filter_range.position.y + 1, header_rows)
	var last := mini(filter_range.end.y, row_count)
	for row in range(first, last):
		for col: int in _criteria:
			var text: String = sheet.call("get_cell_display", row, col)
			if not (_criteria[col] as ColumnCriterion).matches(text):
				_hidden[row] = true
				break
