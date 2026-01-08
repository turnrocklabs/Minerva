class_name SpreadsheetData
extends RefCounted
## Main data model for spreadsheet containing cells, metadata, and charts.

const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")

signal data_changed()
signal cell_changed(row: int, col: int)
signal structure_changed()  # Rows/columns added/removed

## Column metadata
class ColumnMeta:
	var width: float = 100.0
	var header_name: String = ""  # Custom header name (empty = use A, B, C...)
	var is_date_column: bool = false

	func to_dict() -> Dictionary:
		return {
			"width": width,
			"header_name": header_name,
			"is_date_column": is_date_column
		}

	static func from_dict(data: Dictionary) -> ColumnMeta:
		var meta := ColumnMeta.new()
		meta.width = data.get("width", 100.0)
		meta.header_name = data.get("header_name", "")
		meta.is_date_column = data.get("is_date_column", false)
		return meta


## Row metadata
class RowMeta:
	var height: float = 24.0
	var is_header: bool = false

	func to_dict() -> Dictionary:
		return {
			"height": height,
			"is_header": is_header
		}

	static func from_dict(data: Dictionary) -> RowMeta:
		var meta := RowMeta.new()
		meta.height = data.get("height", 24.0)
		meta.is_header = data.get("is_header", false)
		return meta


## Cell storage: "row,col" -> SpreadsheetCell
var cells: Dictionary = {}

## Column metadata array
var column_meta: Array[ColumnMeta] = []

## Row metadata array
var row_meta: Array[RowMeta] = []

## Chart definitions
var charts: Array = []  # Array of SpreadsheetChart

## Number of header rows
var header_row_count: int = 1

## Total row/column counts (for display purposes)
var row_count: int = 100
var column_count: int = 26  # A-Z

## Freeze pane settings
var frozen_rows: int = 0
var frozen_cols: int = 0

## Default cell dimensions
const DEFAULT_COLUMN_WIDTH := 100.0
const DEFAULT_ROW_HEIGHT := 24.0
const MIN_COLUMN_WIDTH := 30.0
const MIN_ROW_HEIGHT := 16.0
const MAX_COLUMN_WIDTH := 500.0
const MAX_ROW_HEIGHT := 200.0

## Dependency graph for formula recalculation
## Key: "row,col" -> Array of dependent cell keys that reference this cell
var _cell_dependencies: Dictionary = {}


func _init(rows: int = 100, cols: int = 26) -> void:
	row_count = rows
	column_count = cols
	_init_metadata()


## Initialize column and row metadata
func _init_metadata() -> void:
	column_meta.clear()
	row_meta.clear()

	for i in range(column_count):
		var meta := ColumnMeta.new()
		column_meta.append(meta)

	for i in range(row_count):
		var meta := RowMeta.new()
		if i == 0:
			meta.is_header = true
		row_meta.append(meta)


## Get cell key string
static func cell_key(row: int, col: int) -> String:
	return "%d,%d" % [row, col]


## Parse cell key string
static func parse_cell_key(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() == 2:
		return Vector2i(parts[1].to_int(), parts[0].to_int())
	return Vector2i(-1, -1)


## Get cell at position (creates if doesn't exist)
func get_cell(row: int, col: int) -> RefCounted:
	var key := cell_key(row, col)
	if cells.has(key):
		return cells[key]

	var cell := SpreadsheetCellScript.new()
	cells[key] = cell
	return cell


## Get cell if it exists (returns null if not)
func get_cell_if_exists(row: int, col: int) -> RefCounted:
	var key := cell_key(row, col)
	return cells.get(key, null)


## Set cell at position
func set_cell(row: int, col: int, cell: RefCounted) -> void:
	var key := cell_key(row, col)
	cells[key] = cell
	_expand_if_needed(row, col)
	cell_changed.emit(row, col)
	data_changed.emit()


## Get cell value
func get_cell_value(row: int, col: int) -> Variant:
	var cell := get_cell_if_exists(row, col)
	if cell:
		return cell.value
	return ""


## Set cell value (creates cell if needed)
func set_cell_value(row: int, col: int, value: Variant) -> void:
	var cell := get_cell(row, col)
	cell.set_value(value)
	_expand_if_needed(row, col)
	cell_changed.emit(row, col)
	data_changed.emit()


## Get display text for a cell
func get_cell_display(row: int, col: int) -> String:
	var cell := get_cell_if_exists(row, col)
	if cell:
		return cell.get_display_text()
	return ""


## Check if cell is empty
func is_cell_empty(row: int, col: int) -> bool:
	var cell := get_cell_if_exists(row, col)
	return cell == null or cell.is_empty()


## Clear a cell
func clear_cell(row: int, col: int) -> void:
	var key := cell_key(row, col)
	if cells.has(key):
		cells.erase(key)
		cell_changed.emit(row, col)
		data_changed.emit()


## Clear all cells in a range
func clear_range(start_row: int, start_col: int, end_row: int, end_col: int) -> void:
	for row in range(start_row, end_row + 1):
		for col in range(start_col, end_col + 1):
			var key := cell_key(row, col)
			cells.erase(key)

	data_changed.emit()


## Expand row/column count if needed
func _expand_if_needed(row: int, col: int) -> void:
	var changed := false

	if row >= row_count:
		var old_count := row_count
		row_count = row + 10  # Add some buffer
		for i in range(old_count, row_count):
			row_meta.append(RowMeta.new())
		changed = true

	if col >= column_count:
		var old_count := column_count
		column_count = col + 5  # Add some buffer
		for i in range(old_count, column_count):
			column_meta.append(ColumnMeta.new())
		changed = true

	if changed:
		structure_changed.emit()


## Get column width
func get_column_width(col: int) -> float:
	if col >= 0 and col < column_meta.size():
		return column_meta[col].width
	return DEFAULT_COLUMN_WIDTH


## Set column width
func set_column_width(col: int, width: float) -> void:
	if col >= 0 and col < column_meta.size():
		column_meta[col].width = clampf(width, MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH)
		structure_changed.emit()


## Get row height
func get_row_height(row: int) -> float:
	if row >= 0 and row < row_meta.size():
		return row_meta[row].height
	return DEFAULT_ROW_HEIGHT


## Set row height
func set_row_height(row: int, height: float) -> void:
	if row >= 0 and row < row_meta.size():
		row_meta[row].height = clampf(height, MIN_ROW_HEIGHT, MAX_ROW_HEIGHT)
		structure_changed.emit()


## Get column label (A, B, C, ... AA, AB, ...)
static func get_column_label(col: int) -> String:
	var result := ""
	var n := col + 1

	while n > 0:
		n -= 1
		result = char(65 + (n % 26)) + result  # 65 = 'A'
		n = n / 26

	return result


## Parse column label to index (A=0, B=1, ... Z=25, AA=26, ...)
static func parse_column_label(label: String) -> int:
	label = label.to_upper()
	var result := 0

	for i in range(label.length()):
		var c := label.unicode_at(i)
		if c < 65 or c > 90:  # Not A-Z
			return -1
		result = result * 26 + (c - 65 + 1)

	return result - 1


## Parse cell reference (e.g., "A1" -> Vector2i(0, 0), "B5" -> Vector2i(4, 1))
static func parse_cell_reference(ref: String) -> Vector2i:
	ref = ref.to_upper().strip_edges()

	# Remove $ for absolute references
	ref = ref.replace("$", "")

	var regex := RegEx.new()
	regex.compile("^([A-Z]+)(\\d+)$")
	var result := regex.search(ref)

	if result:
		var col_str := result.get_string(1)
		var row_str := result.get_string(2)

		var col := parse_column_label(col_str)
		var row := row_str.to_int() - 1  # 1-indexed to 0-indexed

		if col >= 0 and row >= 0:
			return Vector2i(col, row)

	return Vector2i(-1, -1)


## Convert cell position to reference string (e.g., Vector2i(0, 0) -> "A1")
static func cell_to_reference(row: int, col: int) -> String:
	return get_column_label(col) + str(row + 1)


## Get all data in a column (for charts)
func get_column_data(col: int, skip_header: bool = true) -> Array:
	var result := []
	var start_row := header_row_count if skip_header else 0

	for row in range(start_row, row_count):
		var cell := get_cell_if_exists(row, col)
		if cell and not cell.is_empty():
			result.append(cell.value)
		else:
			result.append(null)

	# Trim trailing nulls
	while result.size() > 0 and result.back() == null:
		result.pop_back()

	return result


## Get all data in a row
func get_row_data(row: int) -> Array:
	var result := []

	for col in range(column_count):
		var cell := get_cell_if_exists(row, col)
		if cell and not cell.is_empty():
			result.append(cell.value)
		else:
			result.append(null)

	# Trim trailing nulls
	while result.size() > 0 and result.back() == null:
		result.pop_back()

	return result


## Get the actual used range (bounding box of non-empty cells)
func get_used_range() -> Rect2i:
	var min_row := row_count
	var max_row := -1
	var min_col := column_count
	var max_col := -1

	for key in cells:
		var cell = cells[key]
		if not cell.is_empty():
			var pos := parse_cell_key(key)
			var row := pos.y
			var col := pos.x
			min_row = mini(min_row, row)
			max_row = maxi(max_row, row)
			min_col = mini(min_col, col)
			max_col = maxi(max_col, col)

	if max_row < 0:
		return Rect2i(0, 0, 0, 0)

	return Rect2i(min_col, min_row, max_col - min_col + 1, max_row - min_row + 1)


## Insert a row at position
func insert_row(at_row: int) -> void:
	# Shift cells down
	var keys_to_move := []
	for key in cells:
		var pos := parse_cell_key(key)
		if pos.y >= at_row:
			keys_to_move.append(key)

	# Sort by row descending to avoid overwriting
	keys_to_move.sort_custom(func(a, b):
		return parse_cell_key(a).y > parse_cell_key(b).y
	)

	for key in keys_to_move:
		var pos := parse_cell_key(key)
		var new_key := cell_key(pos.y + 1, pos.x)
		cells[new_key] = cells[key]
		cells.erase(key)

	# Insert row metadata
	var new_meta := RowMeta.new()
	row_meta.insert(at_row, new_meta)
	row_count += 1

	structure_changed.emit()
	data_changed.emit()


## Insert a column at position
func insert_column(at_col: int) -> void:
	# Shift cells right
	var keys_to_move := []
	for key in cells:
		var pos := parse_cell_key(key)
		if pos.x >= at_col:
			keys_to_move.append(key)

	# Sort by column descending
	keys_to_move.sort_custom(func(a, b):
		return parse_cell_key(a).x > parse_cell_key(b).x
	)

	for key in keys_to_move:
		var pos := parse_cell_key(key)
		var new_key := cell_key(pos.y, pos.x + 1)
		cells[new_key] = cells[key]
		cells.erase(key)

	# Insert column metadata
	var new_meta := ColumnMeta.new()
	column_meta.insert(at_col, new_meta)
	column_count += 1

	structure_changed.emit()
	data_changed.emit()


## Delete a row
func delete_row(row: int) -> void:
	# Delete cells in the row
	for col in range(column_count):
		var key := cell_key(row, col)
		cells.erase(key)

	# Shift cells up
	var keys_to_move := []
	for key in cells:
		var pos := parse_cell_key(key)
		if pos.y > row:
			keys_to_move.append(key)

	# Sort by row ascending
	keys_to_move.sort_custom(func(a, b):
		return parse_cell_key(a).y < parse_cell_key(b).y
	)

	for key in keys_to_move:
		var pos := parse_cell_key(key)
		var new_key := cell_key(pos.y - 1, pos.x)
		cells[new_key] = cells[key]
		cells.erase(key)

	# Remove row metadata
	if row < row_meta.size():
		row_meta.remove_at(row)
	row_count = maxi(1, row_count - 1)

	structure_changed.emit()
	data_changed.emit()


## Delete a column
func delete_column(col: int) -> void:
	# Delete cells in the column
	for row in range(row_count):
		var key := cell_key(row, col)
		cells.erase(key)

	# Shift cells left
	var keys_to_move := []
	for key in cells:
		var pos := parse_cell_key(key)
		if pos.x > col:
			keys_to_move.append(key)

	# Sort by column ascending
	keys_to_move.sort_custom(func(a, b):
		return parse_cell_key(a).x < parse_cell_key(b).x
	)

	for key in keys_to_move:
		var pos := parse_cell_key(key)
		var new_key := cell_key(pos.y, pos.x - 1)
		cells[new_key] = cells[key]
		cells.erase(key)

	# Remove column metadata
	if col < column_meta.size():
		column_meta.remove_at(col)
	column_count = maxi(1, column_count - 1)

	structure_changed.emit()
	data_changed.emit()


## Serialize to dictionary
func to_dict() -> Dictionary:
	var cells_dict := {}
	for key in cells:
		var cell = cells[key]
		if not cell.is_empty():
			cells_dict[key] = cell.to_dict()

	var columns_arr := []
	for meta in column_meta:
		columns_arr.append(meta.to_dict())

	var rows_arr := []
	for meta in row_meta:
		rows_arr.append(meta.to_dict())

	return {
		"version": 1,
		"row_count": row_count,
		"column_count": column_count,
		"header_row_count": header_row_count,
		"frozen_rows": frozen_rows,
		"frozen_cols": frozen_cols,
		"columns": columns_arr,
		"rows": rows_arr,
		"cells": cells_dict,
		"charts": []  # TODO: Serialize charts
	}


## Deserialize from dictionary (loads into this instance)
func load_from_dict(data: Dictionary) -> void:
	row_count = data.get("row_count", 100)
	column_count = data.get("column_count", 26)
	header_row_count = data.get("header_row_count", 1)
	frozen_rows = data.get("frozen_rows", 0)
	frozen_cols = data.get("frozen_cols", 0)

	# Load column metadata
	column_meta.clear()
	var columns_arr: Array = data.get("columns", [])
	for col_data in columns_arr:
		column_meta.append(ColumnMeta.from_dict(col_data))

	# Ensure we have enough column metadata
	while column_meta.size() < column_count:
		column_meta.append(ColumnMeta.new())

	# Load row metadata
	row_meta.clear()
	var rows_arr: Array = data.get("rows", [])
	for row_data in rows_arr:
		row_meta.append(RowMeta.from_dict(row_data))

	# Ensure we have enough row metadata
	while row_meta.size() < row_count:
		row_meta.append(RowMeta.new())

	# Load cells
	cells.clear()
	var cells_dict: Dictionary = data.get("cells", {})
	for key in cells_dict:
		var cell = SpreadsheetCellScript.new()
		cell.load_from_dict(cells_dict[key])
		cells[key] = cell

	# TODO: Load charts


## Convert to CSV string
func to_csv(delimiter: String = ",") -> String:
	var used_range := get_used_range()
	if used_range.size == Vector2i.ZERO:
		return ""

	var lines := PackedStringArray()

	for row in range(used_range.position.y, used_range.end.y):
		var values := PackedStringArray()
		for col in range(used_range.position.x, used_range.end.x):
			var cell := get_cell_if_exists(row, col)
			var val := ""
			if cell and not cell.is_empty():
				val = str(cell.value)
				# Escape delimiter and quotes
				if delimiter in val or '"' in val or '\n' in val:
					val = '"' + val.replace('"', '""') + '"'
			values.append(val)
		lines.append(delimiter.join(values))

	return "\n".join(lines)


## Convert to markdown table string
func to_markdown() -> String:
	var used_range := get_used_range()
	if used_range.size == Vector2i.ZERO:
		return ""

	var lines := PackedStringArray()

	for row in range(used_range.position.y, used_range.end.y):
		var values := PackedStringArray()
		for col in range(used_range.position.x, used_range.end.x):
			values.append(get_cell_display(row, col))

		lines.append("| " + " | ".join(values) + " |")

		# Add header separator after first row
		if row == used_range.position.y:
			var sep := PackedStringArray()
			for col in range(used_range.position.x, used_range.end.x):
				sep.append("---")
			lines.append("| " + " | ".join(sep) + " |")

	return "\n".join(lines)


## Convert to JSON array format
func to_json_array() -> Array:
	var used_range := get_used_range()
	if used_range.size == Vector2i.ZERO:
		return []

	var result := []

	for row in range(used_range.position.y, used_range.end.y):
		var row_data := []
		for col in range(used_range.position.x, used_range.end.x):
			var cell := get_cell_if_exists(row, col)
			if cell and not cell.is_empty():
				row_data.append(cell.value)
			else:
				row_data.append(null)
		result.append(row_data)

	return result
