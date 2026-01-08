class_name SpreadsheetCell
extends RefCounted
## Represents a single cell in the spreadsheet with value, type, and formatting.

enum CellType {
	EMPTY,
	TEXT,
	NUMBER,
	DATE,
	FORMULA
}

## The raw value (String, float, or null)
var value: Variant = ""

## The computed display value (result of formula evaluation)
var display_value: String = ""

## Cell type
var type: CellType = CellType.EMPTY

## Original formula string if type is FORMULA (e.g., "=SUM(A1:A10)")
var formula: String = ""

## Error message if formula evaluation failed
var error: String = ""

## Formatting properties
var bold: bool = false
var italic: bool = false
var alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
var text_color: Color = Color.WHITE
var bg_color: Color = Color.TRANSPARENT

## Date format string for DATE type cells
var date_format: String = "YYYY-MM-DD"


func _init(initial_value: Variant = "") -> void:
	set_value(initial_value)


## Set the cell value and auto-detect type
func set_value(new_value: Variant) -> void:
	error = ""

	if new_value == null or (new_value is String and new_value.is_empty()):
		value = ""
		display_value = ""
		type = CellType.EMPTY
		formula = ""
		return

	if new_value is String:
		var str_val: String = new_value

		# Check if it's a formula
		if str_val.begins_with("="):
			formula = str_val
			type = CellType.FORMULA
			value = str_val
			display_value = str_val  # Will be updated by formula engine
			return

		# Try to parse as number
		if str_val.is_valid_float():
			value = str_val.to_float()
			display_value = _format_number(value)
			type = CellType.NUMBER
			formula = ""
			return

		# Try to parse as date
		var date_result := _try_parse_date(str_val)
		if date_result.valid:
			value = date_result.timestamp
			display_value = str_val
			type = CellType.DATE
			formula = ""
			return

		# It's a text value
		value = str_val
		display_value = str_val
		type = CellType.TEXT
		formula = ""

	elif new_value is float or new_value is int:
		value = float(new_value)
		display_value = _format_number(value)
		type = CellType.NUMBER
		formula = ""

	else:
		value = str(new_value)
		display_value = str(new_value)
		type = CellType.TEXT
		formula = ""


## Set formula and mark cell as FORMULA type
func set_formula(formula_str: String) -> void:
	if not formula_str.begins_with("="):
		formula_str = "=" + formula_str

	formula = formula_str
	value = formula_str
	type = CellType.FORMULA
	display_value = formula_str  # Will be updated by formula engine


## Update display value after formula evaluation
func set_computed_value(computed: Variant, err: String = "") -> void:
	error = err

	if not err.is_empty():
		display_value = "#ERROR"
		return

	if computed is float or computed is int:
		display_value = _format_number(float(computed))
	else:
		display_value = str(computed)


## Get the value to display in the cell
func get_display_text() -> String:
	if not error.is_empty():
		return "#ERROR"
	return display_value


## Check if cell has content
func is_empty() -> bool:
	return type == CellType.EMPTY


## Check if cell has a formula
func has_formula() -> bool:
	return type == CellType.FORMULA and not formula.is_empty()


## Create a duplicate of this cell
func duplicate_cell() -> RefCounted:
	var copy = get_script().new()
	copy.value = value
	copy.display_value = display_value
	copy.type = type
	copy.formula = formula
	copy.error = error
	copy.bold = bold
	copy.italic = italic
	copy.alignment = alignment
	copy.text_color = text_color
	copy.bg_color = bg_color
	copy.date_format = date_format
	return copy


## Serialize cell to dictionary
func to_dict() -> Dictionary:
	var data := {
		"value": value,
		"type": type,
	}

	if not formula.is_empty():
		data["formula"] = formula

	# Only save non-default formatting
	if bold:
		data["bold"] = true
	if italic:
		data["italic"] = true
	if alignment != HORIZONTAL_ALIGNMENT_LEFT:
		data["alignment"] = alignment
	if text_color != Color.WHITE:
		data["text_color"] = text_color.to_html()
	if bg_color != Color.TRANSPARENT:
		data["bg_color"] = bg_color.to_html()
	if date_format != "YYYY-MM-DD":
		data["date_format"] = date_format

	return data


## Deserialize cell from dictionary (use create_from_dict() instead of static)
func load_from_dict(data: Dictionary) -> void:
	type = data.get("type", CellType.EMPTY)
	value = data.get("value", "")
	formula = data.get("formula", "")
	bold = data.get("bold", false)
	italic = data.get("italic", false)
	alignment = data.get("alignment", HORIZONTAL_ALIGNMENT_LEFT)

	if data.has("text_color"):
		text_color = Color.html(data["text_color"])
	if data.has("bg_color"):
		bg_color = Color.html(data["bg_color"])
	if data.has("date_format"):
		date_format = data["date_format"]

	# Compute display value
	if type == CellType.NUMBER and value is float:
		display_value = _format_number(value)
	elif type == CellType.FORMULA:
		display_value = formula  # Will be updated by formula engine
	else:
		display_value = str(value)


## Format a number for display
func _format_number(num: float) -> String:
	# Remove unnecessary decimals
	if num == int(num):
		return str(int(num))

	# Limit to reasonable precision
	var formatted := "%.10f" % num
	# Trim trailing zeros
	formatted = formatted.rstrip("0").rstrip(".")
	return formatted


## Try to parse a string as a date
func _try_parse_date(text: String) -> Dictionary:
	# Common date patterns
	var patterns := [
		{"regex": "^(\\d{4})-(\\d{2})-(\\d{2})$", "order": ["year", "month", "day"]},  # YYYY-MM-DD
		{"regex": "^(\\d{2})/(\\d{2})/(\\d{4})$", "order": ["month", "day", "year"]},  # MM/DD/YYYY
		{"regex": "^(\\d{2})-(\\d{2})-(\\d{4})$", "order": ["day", "month", "year"]},  # DD-MM-YYYY
		{"regex": "^(\\d{4})/(\\d{2})/(\\d{2})$", "order": ["year", "month", "day"]},  # YYYY/MM/DD
	]

	var regex := RegEx.new()

	for pattern in patterns:
		regex.compile(pattern.regex)
		var result := regex.search(text)
		if result:
			var parts := {}
			for i in range(pattern.order.size()):
				parts[pattern.order[i]] = result.get_string(i + 1).to_int()

			# Validate date parts
			var year: int = parts.get("year", 0)
			var month: int = parts.get("month", 0)
			var day: int = parts.get("day", 0)

			if year >= 1900 and year <= 2100 and month >= 1 and month <= 12 and day >= 1 and day <= 31:
				# Convert to Unix timestamp (approximate, for sorting)
				var timestamp := year * 10000 + month * 100 + day
				return {"valid": true, "timestamp": timestamp, "year": year, "month": month, "day": day}

	return {"valid": false, "timestamp": 0}
