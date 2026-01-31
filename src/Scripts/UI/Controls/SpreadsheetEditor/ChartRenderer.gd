class_name ChartRenderer
extends RefCounted
## Processes spreadsheet data for chart rendering.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")

## Processed chart data ready for rendering
class ChartData:
	var x_labels: PackedStringArray = []       # X-axis labels (dates/categories)
	var x_values: PackedFloat64Array = []      # Numeric X values (for date plotting)
	var series_data: Array = []                 # Array of {name, color, values: PackedFloat64Array}
	var y_min: float = 0.0
	var y_max: float = 100.0
	var x_min: float = 0.0
	var x_max: float = 1.0
	var has_data: bool = false


## Process chart definition against spreadsheet data
static func process(chart: SpreadsheetChartScript, data: SpreadsheetDataScript) -> ChartData:
	var result := ChartData.new()

	# Parse X-axis range
	var x_range := _parse_range(chart.x_range)
	if x_range.is_empty():
		return result

	# Get X values (skip header row if configured)
	var x_raw := _get_range_values(x_range, data, chart.first_row_is_header)
	if x_raw.is_empty():
		return result

	# Process X values (convert dates if needed)
	if chart.x_is_date:
		result.x_values = _parse_dates(x_raw, chart.date_format)
		result.x_labels = x_raw
	else:
		# Try to parse as numbers, otherwise use as labels
		var numeric_x := _try_parse_numbers(x_raw)
		if numeric_x.size() > 0:
			result.x_values = numeric_x
			result.x_labels = x_raw
		else:
			# Use indices for X values
			result.x_values.resize(x_raw.size())
			for i in range(x_raw.size()):
				result.x_values[i] = float(i)
			result.x_labels = x_raw

	if result.x_values.size() == 0:
		return result

	# Calculate X bounds
	result.x_min = result.x_values[0]
	result.x_max = result.x_values[0]
	for x in result.x_values:
		result.x_min = minf(result.x_min, x)
		result.x_max = maxf(result.x_max, x)

	# Process each series
	var all_y_values: PackedFloat64Array = []

	for series_def in chart.series:
		var series_range := _parse_range(series_def["range"])
		if series_range.is_empty():
			continue

		# Get series name - use header row if available and name is generic
		var series_name: String = series_def["name"]
		if chart.first_row_is_header:
			var header_value := _get_header_value(series_range, data)
			if not header_value.is_empty():
				# Use header value if no custom name was provided or if it's a generic "Series N" name
				if series_name.is_empty() or series_name.begins_with("Series "):
					series_name = header_value

		# Get data values (skip header row if configured)
		var raw_values := _get_range_values(series_range, data, chart.first_row_is_header)
		var y_values := _parse_numbers(raw_values)

		# Pad or trim to match X values count
		y_values.resize(result.x_values.size())

		result.series_data.append({
			"name": series_name,
			"color": series_def["color"],
			"values": y_values,
		})

		# Collect all Y values for auto-scaling
		for y in y_values:
			if not is_nan(y):
				all_y_values.append(y)

	# Calculate Y bounds
	if chart.y_auto_scale and all_y_values.size() > 0:
		result.y_min = all_y_values[0]
		result.y_max = all_y_values[0]
		for y in all_y_values:
			result.y_min = minf(result.y_min, y)
			result.y_max = maxf(result.y_max, y)

		# Add some padding
		var y_range := result.y_max - result.y_min
		if y_range < 0.001:
			y_range = 1.0
		result.y_min -= y_range * 0.05
		result.y_max += y_range * 0.05

		# Round to nice values
		result.y_min = _floor_to_nice(result.y_min)
		result.y_max = _ceil_to_nice(result.y_max)
	else:
		result.y_min = chart.y_min
		result.y_max = chart.y_max

	result.has_data = result.series_data.size() > 0
	return result


## Parse a range string like "A1:A10" or "B2:B20"
static func _parse_range(range_str: String) -> Dictionary:
	if range_str.is_empty():
		return {}

	var parts: PackedStringArray = range_str.split(":")
	if parts.size() != 2:
		# Single cell
		var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(range_str)
		if pos.x >= 0 and pos.y >= 0:
			return {
				"start_row": pos.y,
				"start_col": pos.x,
				"end_row": pos.y,
				"end_col": pos.x,
			}
		return {}

	var start_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[0].strip_edges())
	var end_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[1].strip_edges())

	if start_pos.x < 0 or start_pos.y < 0 or end_pos.x < 0 or end_pos.y < 0:
		return {}

	return {
		"start_row": mini(start_pos.y, end_pos.y),
		"start_col": mini(start_pos.x, end_pos.x),
		"end_row": maxi(start_pos.y, end_pos.y),
		"end_col": maxi(start_pos.x, end_pos.x),
	}


## Get values from a range
## If skip_first is true, skips the first row/column (for header rows)
static func _get_range_values(range_def: Dictionary, data: SpreadsheetDataScript, skip_first: bool = false) -> PackedStringArray:
	var values: PackedStringArray = []

	var start_row: int = range_def.get("start_row", 0)
	var start_col: int = range_def.get("start_col", 0)
	var end_row: int = range_def.get("end_row", 0)
	var end_col: int = range_def.get("end_col", 0)

	# Determine if range is vertical or horizontal
	var is_vertical := (end_row - start_row) >= (end_col - start_col)

	if is_vertical:
		var actual_start := start_row + 1 if skip_first else start_row
		for row in range(actual_start, end_row + 1):
			values.append(data.get_cell_display(row, start_col))
	else:
		var actual_start := start_col + 1 if skip_first else start_col
		for col in range(actual_start, end_col + 1):
			values.append(data.get_cell_display(start_row, col))

	return values


## Get the header value (first cell) from a range
static func _get_header_value(range_def: Dictionary, data: SpreadsheetDataScript) -> String:
	var start_row: int = range_def.get("start_row", 0)
	var start_col: int = range_def.get("start_col", 0)
	return data.get_cell_display(start_row, start_col)


## Parse string values to numbers
static func _parse_numbers(values: PackedStringArray) -> PackedFloat64Array:
	var result: PackedFloat64Array = []
	result.resize(values.size())

	for i in range(values.size()):
		var val := _clean_number_string(values[i])
		if val.is_valid_float():
			result[i] = val.to_float()
		elif val.is_valid_int():
			result[i] = float(val.to_int())
		else:
			result[i] = NAN

	return result


## Clean a string for number parsing (strip currency symbols, commas, etc.)
static func _clean_number_string(text: String) -> String:
	var val := text.strip_edges()

	# Handle empty string
	if val.is_empty():
		return ""

	# Check for negative in parentheses: (123.45) -> -123.45
	var is_negative := false
	if val.begins_with("(") and val.ends_with(")"):
		is_negative = true
		val = val.substr(1, val.length() - 2)

	# Check for leading minus
	if val.begins_with("-"):
		is_negative = true
		val = val.substr(1)

	# Strip currency symbols
	val = val.replace("$", "")
	val = val.replace("€", "")
	val = val.replace("£", "")
	val = val.replace("¥", "")

	# Remove thousands separators (commas)
	val = val.replace(",", "")

	# Remove percent sign and note for later (handled separately)
	val = val.replace("%", "")

	val = val.strip_edges()

	# Re-add negative sign if needed
	if is_negative and not val.is_empty():
		val = "-" + val

	return val


## Try to parse values as numbers, return empty array if any fail
static func _try_parse_numbers(values: PackedStringArray) -> PackedFloat64Array:
	var result: PackedFloat64Array = []
	result.resize(values.size())

	for i in range(values.size()):
		var val := _clean_number_string(values[i])
		if val.is_valid_float():
			result[i] = val.to_float()
		elif val.is_valid_int():
			result[i] = float(val.to_int())
		else:
			return PackedFloat64Array()  # Return empty on failure

	return result


## Parse date strings to numeric values (days since epoch)
static func _parse_dates(values: PackedStringArray, format: String) -> PackedFloat64Array:
	var result: PackedFloat64Array = []
	result.resize(values.size())

	for i in range(values.size()):
		var date_val := _parse_date(values[i], format)
		result[i] = date_val

	return result


## Parse a single date string
static func _parse_date(date_str: String, format: String) -> float:
	var cleaned := date_str.strip_edges()
	if cleaned.is_empty():
		return NAN

	# Try common date formats
	var year := 0
	var month := 1
	var day := 1

	# YYYY-MM-DD
	if cleaned.contains("-"):
		var parts := cleaned.split("-")
		if parts.size() >= 3:
			year = parts[0].to_int()
			month = parts[1].to_int()
			day = parts[2].to_int()
		elif parts.size() == 2:
			year = parts[0].to_int()
			month = parts[1].to_int()
	# MM/DD/YYYY or DD/MM/YYYY
	elif cleaned.contains("/"):
		var parts := cleaned.split("/")
		if parts.size() >= 3:
			if format.begins_with("DD"):
				day = parts[0].to_int()
				month = parts[1].to_int()
				year = parts[2].to_int()
			else:
				month = parts[0].to_int()
				day = parts[1].to_int()
				year = parts[2].to_int()

	if year < 1900 or year > 2100 or month < 1 or month > 12 or day < 1 or day > 31:
		return NAN

	# Convert to days since epoch (Jan 1, 1970)
	var datetime := {
		"year": year,
		"month": month,
		"day": day,
		"hour": 0,
		"minute": 0,
		"second": 0,
	}

	return float(Time.get_unix_time_from_datetime_dict(datetime)) / 86400.0


## Floor to a nice round number
static func _floor_to_nice(value: float) -> float:
	if value == 0:
		return 0

	var magnitude := pow(10, floor(log(absf(value)) / log(10)))
	var normalized := value / magnitude

	if value < 0:
		if normalized <= -5:
			return -10 * magnitude
		elif normalized <= -2:
			return -5 * magnitude
		elif normalized <= -1:
			return -2 * magnitude
		else:
			return -magnitude
	else:
		if normalized >= 5:
			return 5 * magnitude
		elif normalized >= 2:
			return 2 * magnitude
		elif normalized >= 1:
			return magnitude
		else:
			return 0


## Ceiling to a nice round number
static func _ceil_to_nice(value: float) -> float:
	if value == 0:
		return 0

	var magnitude := pow(10, floor(log(absf(value)) / log(10)))
	var normalized := value / magnitude

	if value < 0:
		if normalized >= -1:
			return 0
		elif normalized >= -2:
			return -magnitude
		elif normalized >= -5:
			return -2 * magnitude
		else:
			return -5 * magnitude
	else:
		if normalized <= 1:
			return magnitude
		elif normalized <= 2:
			return 2 * magnitude
		elif normalized <= 5:
			return 5 * magnitude
		else:
			return 10 * magnitude


## Calculate nice tick values for an axis
static func calculate_ticks(min_val: float, max_val: float, max_ticks: int = 10) -> PackedFloat64Array:
	var ticks: PackedFloat64Array = []

	var range_val := max_val - min_val
	if range_val <= 0:
		ticks.append(min_val)
		return ticks

	# Calculate step size
	var rough_step := range_val / float(max_ticks)
	var magnitude := pow(10, floor(log(rough_step) / log(10)))
	var normalized := rough_step / magnitude

	var step: float
	if normalized <= 1:
		step = magnitude
	elif normalized <= 2:
		step = 2 * magnitude
	elif normalized <= 5:
		step = 5 * magnitude
	else:
		step = 10 * magnitude

	# Generate ticks
	var tick: float = ceil(min_val / step) * step
	while tick <= max_val:
		ticks.append(tick)
		tick += step

	return ticks


## Format a date value (days since epoch) as a string
static func format_date(days: float, format: String = "MMM DD") -> String:
	var unix_time := int(days * 86400.0)
	var datetime := Time.get_datetime_dict_from_unix_time(unix_time)

	var month_names: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var month_idx: int = datetime.get("month", 1) - 1
	var month_name: String = month_names[clampi(month_idx, 0, 11)]

	match format:
		"YYYY-MM-DD":
			return "%04d-%02d-%02d" % [datetime.get("year", 2000), datetime.get("month", 1), datetime.get("day", 1)]
		"MMM DD":
			return "%s %02d" % [month_name, datetime.get("day", 1)]
		"MMM YYYY":
			return "%s %04d" % [month_name, datetime.get("year", 2000)]
		_:
			return "%s %02d" % [month_name, datetime.get("day", 1)]
