class_name SpreadsheetData
extends RefCounted
## Main data model for spreadsheet containing cells, metadata, and charts.

const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")
const FormulaEngineScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/FormulaEngine.gd")
const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")

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

## Reverse dependency map: which cells does this cell depend on?
## Key: "row,col" -> Array of cell keys this cell references
var _cell_references: Dictionary = {}

## Formula engine instance
var _formula_engine = null

## Flag to prevent recursive recalculation during batch updates
var _is_recalculating: bool = false


func _init(rows: int = 100, cols: int = 26) -> void:
	_formula_engine = FormulaEngineScript.new()
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
	var key := cell_key(row, col)

	# Remove old dependencies
	_remove_cell_dependencies(key)

	# Set the value
	cell.set_value(value)
	_expand_if_needed(row, col)

	# If it's a formula, evaluate it and set up dependencies
	if cell.has_formula():
		_setup_formula_dependencies(row, col, cell.formula)
		_evaluate_cell_formula(row, col, cell)

	# Recalculate cells that depend on this cell
	if not _is_recalculating:
		_recalculate_dependents(key)

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


## Clear all cells (used when importing new data)
func clear() -> void:
	cells.clear()
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
		n = int(n / 26.0)

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

	# Adjust formula references in all cells
	_adjust_formulas_for_row_insertion(at_row)

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

	# Adjust formula references in all cells
	_adjust_formulas_for_column_insertion(at_col)

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

	# Adjust formula references in all remaining cells
	_adjust_formulas_for_row_deletion(row)

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

	# Adjust formula references in all remaining cells
	_adjust_formulas_for_column_deletion(col)

	# Remove column metadata
	if col < column_meta.size():
		column_meta.remove_at(col)
	column_count = maxi(1, column_count - 1)

	structure_changed.emit()
	data_changed.emit()


## Adjust all formula references when a row is deleted.
## Row references > deleted_row are decremented by 1.
## References to the deleted row become #REF!.
func _adjust_formulas_for_row_deletion(deleted_row: int) -> void:
	var regex := RegEx.new()
	# Match cell references: optional sheet prefix, optional $ for col, column letters, optional $ for row, row number
	regex.compile("((?:'[^']+?'!|[A-Za-z_][A-Za-z0-9_]*!)?)(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")

	for key in cells:
		var cell = cells[key]
		if not cell.has_formula():
			continue

		var formula: String = cell.formula
		var new_formula := ""
		var last_end := 0
		var has_ref_error := false

		for match_result in regex.search_all(formula):
			# Add text before this match
			new_formula += formula.substr(last_end, match_result.get_start() - last_end)

			var sheet_prefix: String = match_result.get_string(1)  # e.g., "Sheet1!" or "'My Sheet'!"
			var col_absolute: String = match_result.get_string(2)  # "$" or ""
			var col_letters: String = match_result.get_string(3)   # e.g., "A", "BC"
			var row_absolute: String = match_result.get_string(4)  # "$" or ""
			var row_num_str: String = match_result.get_string(5)   # e.g., "1", "25"

			var row_num := row_num_str.to_int()
			var ref_row := row_num - 1  # Convert to 0-based

			if ref_row == deleted_row:
				# Reference to deleted row - becomes #REF!
				new_formula += "#REF!"
				has_ref_error = true
			elif ref_row > deleted_row and row_absolute.is_empty():
				# Reference below deleted row (and not absolute) - decrement
				var new_row_num := row_num - 1
				new_formula += sheet_prefix + col_absolute + col_letters + row_absolute + str(new_row_num)
			else:
				# Reference above deleted row or absolute - keep as is
				new_formula += match_result.get_string(0)

			last_end = match_result.get_end()

		# Add remaining text after last match
		new_formula += formula.substr(last_end)

		# Update the cell's formula if it changed
		if new_formula != formula:
			cell.formula = new_formula
			if has_ref_error:
				cell.set_computed_value(0, "#REF!")


## Adjust all formula references when a column is deleted.
## Column references > deleted_col are decremented by 1.
## References to the deleted column become #REF!.
func _adjust_formulas_for_column_deletion(deleted_col: int) -> void:
	var regex := RegEx.new()
	regex.compile("((?:'[^']+?'!|[A-Za-z_][A-Za-z0-9_]*!)?)(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")

	for key in cells:
		var cell = cells[key]
		if not cell.has_formula():
			continue

		var formula: String = cell.formula
		var new_formula := ""
		var last_end := 0
		var has_ref_error := false

		for match_result in regex.search_all(formula):
			# Add text before this match
			new_formula += formula.substr(last_end, match_result.get_start() - last_end)

			var sheet_prefix: String = match_result.get_string(1)
			var col_absolute: String = match_result.get_string(2)
			var col_letters: String = match_result.get_string(3)
			var row_absolute: String = match_result.get_string(4)
			var row_num_str: String = match_result.get_string(5)

			var col_index := parse_column_label(col_letters)

			if col_index == deleted_col:
				# Reference to deleted column - becomes #REF!
				new_formula += "#REF!"
				has_ref_error = true
			elif col_index > deleted_col and col_absolute.is_empty():
				# Reference to the right of deleted column (and not absolute) - decrement
				var new_col_letters := get_column_label(col_index - 1)
				new_formula += sheet_prefix + col_absolute + new_col_letters + row_absolute + row_num_str
			else:
				# Reference to the left of deleted column or absolute - keep as is
				new_formula += match_result.get_string(0)

			last_end = match_result.get_end()

		# Add remaining text after last match
		new_formula += formula.substr(last_end)

		# Update the cell's formula if it changed
		if new_formula != formula:
			cell.formula = new_formula
			if has_ref_error:
				cell.set_computed_value(0, "#REF!")


## Adjust all formula references when a row is inserted.
## Row references >= inserted_row are incremented by 1.
func _adjust_formulas_for_row_insertion(inserted_row: int) -> void:
	var regex := RegEx.new()
	regex.compile("((?:'[^']+?'!|[A-Za-z_][A-Za-z0-9_]*!)?)(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")

	for key in cells:
		var cell = cells[key]
		if not cell.has_formula():
			continue

		var formula: String = cell.formula
		var new_formula := ""
		var last_end := 0

		for match_result in regex.search_all(formula):
			new_formula += formula.substr(last_end, match_result.get_start() - last_end)

			var sheet_prefix: String = match_result.get_string(1)
			var col_absolute: String = match_result.get_string(2)
			var col_letters: String = match_result.get_string(3)
			var row_absolute: String = match_result.get_string(4)
			var row_num_str: String = match_result.get_string(5)

			var row_num := row_num_str.to_int()
			var ref_row := row_num - 1  # Convert to 0-based

			if ref_row >= inserted_row and row_absolute.is_empty():
				# Reference at or below inserted row (and not absolute) - increment
				var new_row_num := row_num + 1
				new_formula += sheet_prefix + col_absolute + col_letters + row_absolute + str(new_row_num)
			else:
				# Reference above inserted row or absolute - keep as is
				new_formula += match_result.get_string(0)

			last_end = match_result.get_end()

		new_formula += formula.substr(last_end)

		if new_formula != formula:
			cell.formula = new_formula


## Adjust all formula references when a column is inserted.
## Column references >= inserted_col are incremented by 1.
func _adjust_formulas_for_column_insertion(inserted_col: int) -> void:
	var regex := RegEx.new()
	regex.compile("((?:'[^']+?'!|[A-Za-z_][A-Za-z0-9_]*!)?)(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")

	for key in cells:
		var cell = cells[key]
		if not cell.has_formula():
			continue

		var formula: String = cell.formula
		var new_formula := ""
		var last_end := 0

		for match_result in regex.search_all(formula):
			new_formula += formula.substr(last_end, match_result.get_start() - last_end)

			var sheet_prefix: String = match_result.get_string(1)
			var col_absolute: String = match_result.get_string(2)
			var col_letters: String = match_result.get_string(3)
			var row_absolute: String = match_result.get_string(4)
			var row_num_str: String = match_result.get_string(5)

			var col_index := parse_column_label(col_letters)

			if col_index >= inserted_col and col_absolute.is_empty():
				# Reference at or to the right of inserted column (and not absolute) - increment
				var new_col_letters := get_column_label(col_index + 1)
				new_formula += sheet_prefix + col_absolute + new_col_letters + row_absolute + row_num_str
			else:
				# Reference to the left of inserted column or absolute - keep as is
				new_formula += match_result.get_string(0)

			last_end = match_result.get_end()

		new_formula += formula.substr(last_end)

		if new_formula != formula:
			cell.formula = new_formula


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


## Load data from CSV string
func from_csv(csv_text: String, delimiter: String = ",") -> void:
	# Clear existing cells
	cells.clear()

	var lines := csv_text.split("\n")
	var max_cols := 0
	var actual_rows := 0

	for row_idx in range(lines.size()):
		var line := lines[row_idx].strip_edges()
		if line.is_empty():
			continue

		var values: Array = _parse_csv_line(line, delimiter)
		max_cols = maxi(max_cols, values.size())
		actual_rows = row_idx + 1

		for col_idx in range(values.size()):
			var val: String = values[col_idx]
			if not val.is_empty():
				set_cell_value(row_idx, col_idx, val)

	# Update counts and metadata
	if max_cols > column_count:
		column_count = max_cols
	if actual_rows > row_count:
		row_count = actual_rows

	_init_metadata()

	structure_changed.emit()
	data_changed.emit()


## Parse a CSV line handling quoted fields
func _parse_csv_line(line: String, delimiter: String) -> Array:
	var values := []
	var current := ""
	var in_quotes := false
	var i := 0

	while i < line.length():
		var ch := line[i]

		if in_quotes:
			if ch == '"':
				# Check for escaped quote
				if i + 1 < line.length() and line[i + 1] == '"':
					current += '"'
					i += 1
				else:
					in_quotes = false
			else:
				current += ch
		else:
			if ch == '"':
				in_quotes = true
			elif ch == delimiter:
				values.append(current)
				current = ""
			else:
				current += ch
		i += 1

	values.append(current)
	return values


# ============================================================================
# FORMULA EVALUATION AND DEPENDENCY TRACKING
# ============================================================================

## Evaluate a cell's formula and update its computed value
func _evaluate_cell_formula(row: int, col: int, cell) -> void:
	if not cell.has_formula():
		return

	# Check for circular reference
	var key := cell_key(row, col)
	if _has_circular_reference(key):
		cell.set_computed_value(0, "#CIRCULAR!")
		return

	var result = _formula_engine.evaluate_formula(cell.formula, self, row, col)

	if result.is_error:
		cell.set_computed_value(0, result.error)
	else:
		cell.value = result.value
		cell.set_computed_value(result.value)


## Set up dependency tracking for a formula cell
func _setup_formula_dependencies(row: int, col: int, formula: String) -> void:
	var key := cell_key(row, col)
	var refs: Array = _formula_engine.get_all_references(formula)

	# Track what this cell references
	var ref_keys: Array = []
	for ref in refs:
		var ref_key := cell_key(ref.y, ref.x)
		ref_keys.append(ref_key)

		# Add this cell to the dependency list of the referenced cell
		if not _cell_dependencies.has(ref_key):
			_cell_dependencies[ref_key] = []
		if key not in _cell_dependencies[ref_key]:
			_cell_dependencies[ref_key].append(key)

	_cell_references[key] = ref_keys


## Remove dependency tracking for a cell
func _remove_cell_dependencies(key: String) -> void:
	# Get the cells this cell was referencing
	if not _cell_references.has(key):
		return

	var old_refs: Array = _cell_references[key]
	for ref_key in old_refs:
		if _cell_dependencies.has(ref_key):
			var idx: int = _cell_dependencies[ref_key].find(key)
			if idx >= 0:
				_cell_dependencies[ref_key].remove_at(idx)

	_cell_references.erase(key)


## Recalculate all cells that depend on the changed cell
func _recalculate_dependents(key: String) -> void:
	if not _cell_dependencies.has(key):
		return

	_is_recalculating = true

	# Get list of dependent cells
	var dependents: Array = _cell_dependencies[key].duplicate()

	# Recalculate each dependent cell
	for dep_key in dependents:
		var pos := parse_cell_key(dep_key)
		if pos.x >= 0 and pos.y >= 0:
			var cell := get_cell_if_exists(pos.y, pos.x)
			if cell and cell.has_formula():
				_evaluate_cell_formula(pos.y, pos.x, cell)
				# Recursively recalculate cells that depend on this one
				_recalculate_dependents(dep_key)

	_is_recalculating = false


## Check if a cell has a circular reference
func _has_circular_reference(start_key: String, visited: Dictionary = {}) -> bool:
	if visited.has(start_key):
		return true

	if not _cell_references.has(start_key):
		return false

	visited[start_key] = true

	for ref_key in _cell_references[start_key]:
		if _has_circular_reference(ref_key, visited):
			return true

	visited.erase(start_key)
	return false


## Recalculate all formula cells in the spreadsheet
func recalculate_all() -> void:
	_is_recalculating = true

	# Build a list of all formula cells
	var formula_cells: Array = []
	for key in cells:
		var cell = cells[key]
		if cell.has_formula():
			formula_cells.append(key)

	# Sort by dependency order (cells with no dependencies first)
	var sorted_cells := _topological_sort(formula_cells)

	# Evaluate in order
	for key in sorted_cells:
		var pos := parse_cell_key(key)
		if pos.x >= 0 and pos.y >= 0:
			var cell := get_cell_if_exists(pos.y, pos.x)
			if cell and cell.has_formula():
				_evaluate_cell_formula(pos.y, pos.x, cell)

	_is_recalculating = false
	data_changed.emit()


## Topological sort of formula cells for dependency-order evaluation
func _topological_sort(cell_keys: Array) -> Array:
	var result: Array = []
	var visited: Dictionary = {}
	var temp_visited: Dictionary = {}

	for key in cell_keys:
		if not visited.has(key):
			_topological_visit(key, visited, temp_visited, result)

	return result


func _topological_visit(key: String, visited: Dictionary, temp_visited: Dictionary, result: Array) -> void:
	if temp_visited.has(key):
		return  # Circular reference - skip
	if visited.has(key):
		return

	temp_visited[key] = true

	# Visit all cells this cell depends on
	if _cell_references.has(key):
		for ref_key in _cell_references[key]:
			_topological_visit(ref_key, visited, temp_visited, result)

	temp_visited.erase(key)
	visited[key] = true
	result.append(key)


## Convert spreadsheet data to markdown table format
func to_markdown(include_formulas: bool = false) -> String:
	var bounds := get_used_range()
	if bounds.size.x == 0 or bounds.size.y == 0:
		return ""

	var lines: PackedStringArray = []
	var col_widths: Array[int] = []

	# Calculate column widths for alignment
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var max_width := 3  # Minimum width
		for row in range(bounds.position.y, bounds.position.y + bounds.size.y):
			var text := _get_markdown_cell_text(row, col, include_formulas)
			max_width = maxi(max_width, text.length())
		col_widths.append(mini(max_width, 30))  # Cap at 30 chars

	# Build header row (first row of data)
	var header_parts: PackedStringArray = []
	for col_idx in range(bounds.size.x):
		var col := bounds.position.x + col_idx
		var row := bounds.position.y
		var text := _get_markdown_cell_text(row, col, include_formulas)
		header_parts.append(_pad_cell(text, col_widths[col_idx]))

	lines.append("| " + " | ".join(header_parts) + " |")

	# Build separator row
	var sep_parts: PackedStringArray = []
	for col_idx in range(bounds.size.x):
		sep_parts.append("-".repeat(col_widths[col_idx]))
	lines.append("| " + " | ".join(sep_parts) + " |")

	# Build data rows
	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var row_parts: PackedStringArray = []
		for col_idx in range(bounds.size.x):
			var col := bounds.position.x + col_idx
			var text := _get_markdown_cell_text(row, col, include_formulas)
			row_parts.append(_pad_cell(text, col_widths[col_idx]))
		lines.append("| " + " | ".join(row_parts) + " |")

	# Append chart definitions if any
	if charts.size() > 0:
		var charts_data: Array = []
		for chart in charts:
			charts_data.append(chart.to_dict())
		lines.append("")
		lines.append("<!-- SPREADSHEET_CHARTS")
		lines.append(JSON.stringify(charts_data))
		lines.append("-->")

	return "\n".join(lines)


## Get cell text for markdown (escapes pipes)
func _get_markdown_cell_text(row: int, col: int, include_formulas: bool) -> String:
	var cell := get_cell_if_exists(row, col)
	if not cell:
		return ""

	var text: String
	if include_formulas and cell.has_formula():
		text = cell.formula
	else:
		text = cell.get_display_text()

	# Escape pipe characters
	text = text.replace("|", "\\|")
	# Remove newlines
	text = text.replace("\n", " ")

	return text


## Pad cell text for aligned markdown table
func _pad_cell(text: String, width: int) -> String:
	if text.length() > width:
		return text.substr(0, width - 1) + "…"
	return text + " ".repeat(width - text.length())


## Parse markdown table and update spreadsheet data
func from_markdown(markdown: String) -> void:
	var lines := markdown.strip_edges().split("\n")
	if lines.size() < 2:
		return

	# Clear existing data and charts
	clear()
	charts.clear()

	var data_rows: Array[PackedStringArray] = []
	var in_chart_block := false
	var chart_json_lines: PackedStringArray = []

	for line in lines:
		var trimmed := line.strip_edges()

		# Check for chart block start
		if trimmed == "<!-- SPREADSHEET_CHARTS":
			in_chart_block = true
			continue

		# Check for chart block end
		if in_chart_block and trimmed == "-->":
			in_chart_block = false
			# Parse chart JSON
			var chart_json := "\n".join(chart_json_lines)
			_parse_charts_json(chart_json)
			chart_json_lines.clear()
			continue

		# Collect chart JSON lines
		if in_chart_block:
			chart_json_lines.append(line)
			continue

		# Skip empty lines
		if trimmed.is_empty():
			continue

		# Skip separator rows (|---|---|)
		if _is_markdown_separator(trimmed):
			continue

		# Parse table row
		if trimmed.begins_with("|") and trimmed.ends_with("|"):
			var row_data := _parse_markdown_row(trimmed)
			if row_data.size() > 0:
				data_rows.append(row_data)

	# Populate spreadsheet
	for row_idx in range(data_rows.size()):
		var row_data: PackedStringArray = data_rows[row_idx]
		for col_idx in range(row_data.size()):
			var value := row_data[col_idx]
			if not value.is_empty():
				set_cell_value(row_idx, col_idx, value)

	# Update row/column counts
	if data_rows.size() > 0:
		row_count = maxi(row_count, data_rows.size())
		var max_cols := 0
		for row_data in data_rows:
			max_cols = maxi(max_cols, row_data.size())
		column_count = maxi(column_count, max_cols)

	structure_changed.emit()
	data_changed.emit()


## Parse chart definitions from JSON string
func _parse_charts_json(json_str: String) -> void:
	var json := JSON.new()
	var error := json.parse(json_str)
	if error != OK:
		push_warning("Failed to parse chart JSON: %s" % json.get_error_message())
		return

	var charts_data = json.get_data()
	if not charts_data is Array:
		return

	for chart_dict in charts_data:
		if chart_dict is Dictionary:
			var chart := SpreadsheetChartScript.new()
			chart.load_from_dict(chart_dict)
			charts.append(chart)


## Check if a line is a markdown table separator
func _is_markdown_separator(line: String) -> bool:
	# Separator lines contain only |, -, :, and spaces
	var cleaned := line.replace("|", "").replace("-", "").replace(":", "").replace(" ", "")
	return cleaned.is_empty() and line.contains("-")


## Parse a markdown table row into cell values
func _parse_markdown_row(line: String) -> PackedStringArray:
	var result: PackedStringArray = []

	# Remove leading/trailing pipes
	if line.begins_with("|"):
		line = line.substr(1)
	if line.ends_with("|"):
		line = line.substr(0, line.length() - 1)

	# Split by pipe, handling escaped pipes
	var _cells := _split_markdown_cells(line)

	for cell_text in _cells:
		# Unescape pipes and trim
		var value := cell_text.strip_edges().replace("\\|", "|")
		result.append(value)

	return result


## Split markdown row by pipes, handling escaped pipes
func _split_markdown_cells(line: String) -> PackedStringArray:
	var result: PackedStringArray = []
	var current := ""
	var i := 0

	while i < line.length():
		if i < line.length() - 1 and line[i] == "\\" and line[i + 1] == "|":
			# Escaped pipe - keep it
			current += "\\|"
			i += 2
		elif line[i] == "|":
			# Cell separator
			result.append(current)
			current = ""
			i += 1
		else:
			current += line[i]
			i += 1

	# Add last cell
	result.append(current)

	return result
