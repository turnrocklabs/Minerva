class_name SpreadsheetChart
extends RefCounted
## Data structure representing a chart in a spreadsheet.

enum ChartType {
	LINE,
	BAR,
}

## Unique identifier for this chart
var id: String = ""

## Chart title
var title: String = "Chart"

## Chart type
var type: ChartType = ChartType.LINE

## Data range for X-axis (e.g., "A1:A10" for dates/categories)
var x_range: String = ""

## Data series - array of dictionaries with:
## - "range": String (e.g., "B1:B10")
## - "name": String (series label for legend)
## - "color": Color
var series: Array[Dictionary] = []

## Whether X-axis contains date values
var x_is_date: bool = false

## Whether first row contains headers (skip for data, use for labels)
var first_row_is_header: bool = true

## Date format for parsing (if x_is_date is true)
var date_format: String = "YYYY-MM-DD"

## Chart dimensions
var width: float = 600.0
var height: float = 300.0

## Axis labels
var x_axis_label: String = ""
var y_axis_label: String = ""

## Show legend
var show_legend: bool = true

## Show grid lines
var show_grid: bool = true

## Auto-scale Y axis
var y_auto_scale: bool = true
var y_min: float = 0.0
var y_max: float = 100.0

## Colors
var background_color: Color = Color(0.15, 0.15, 0.18, 1.0)
var grid_color: Color = Color(0.3, 0.3, 0.35, 0.5)
var axis_color: Color = Color(0.6, 0.6, 0.65, 1.0)
var text_color: Color = Color(0.8, 0.8, 0.85, 1.0)

## Default series colors
const DEFAULT_COLORS: Array[Color] = [
	Color(0.3, 0.6, 0.9, 1.0),   # Blue
	Color(0.9, 0.4, 0.3, 1.0),   # Red
	Color(0.3, 0.8, 0.4, 1.0),   # Green
	Color(0.9, 0.7, 0.2, 1.0),   # Yellow
	Color(0.7, 0.4, 0.9, 1.0),   # Purple
	Color(0.2, 0.8, 0.8, 1.0),   # Cyan
	Color(0.9, 0.5, 0.1, 1.0),   # Orange
	Color(0.6, 0.6, 0.6, 1.0),   # Gray
]


func _init() -> void:
	id = _generate_id()


static func _generate_id() -> String:
	return "chart_%d" % Time.get_ticks_msec()


## Add a data series to the chart
func add_series(data_range: String, name: String = "", color: Color = Color.TRANSPARENT) -> void:
	var series_color := color
	if series_color == Color.TRANSPARENT:
		series_color = DEFAULT_COLORS[series.size() % DEFAULT_COLORS.size()]

	var series_name := name
	if series_name.is_empty():
		series_name = "Series %d" % (series.size() + 1)

	series.append({
		"range": data_range,
		"name": series_name,
		"color": series_color,
	})


## Remove a series by index
func remove_series(index: int) -> void:
	if index >= 0 and index < series.size():
		series.remove_at(index)


## Clear all series
func clear_series() -> void:
	series.clear()


## Serialize chart to dictionary
func to_dict() -> Dictionary:
	var series_data: Array[Dictionary] = []
	for s in series:
		series_data.append({
			"range": s["range"],
			"name": s["name"],
			"color_r": s["color"].r,
			"color_g": s["color"].g,
			"color_b": s["color"].b,
			"color_a": s["color"].a,
		})

	return {
		"id": id,
		"title": title,
		"type": type,
		"x_range": x_range,
		"series": series_data,
		"x_is_date": x_is_date,
		"first_row_is_header": first_row_is_header,
		"date_format": date_format,
		"width": width,
		"height": height,
		"x_axis_label": x_axis_label,
		"y_axis_label": y_axis_label,
		"show_legend": show_legend,
		"show_grid": show_grid,
		"y_auto_scale": y_auto_scale,
		"y_min": y_min,
		"y_max": y_max,
		"background_color_r": background_color.r,
		"background_color_g": background_color.g,
		"background_color_b": background_color.b,
		"background_color_a": background_color.a,
	}


## Load chart from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", _generate_id())
	title = data.get("title", "Chart")
	type = data.get("type", ChartType.LINE)
	x_range = data.get("x_range", "")
	x_is_date = data.get("x_is_date", false)
	first_row_is_header = data.get("first_row_is_header", true)
	date_format = data.get("date_format", "YYYY-MM-DD")
	width = data.get("width", 600.0)
	height = data.get("height", 300.0)
	x_axis_label = data.get("x_axis_label", "")
	y_axis_label = data.get("y_axis_label", "")
	show_legend = data.get("show_legend", true)
	show_grid = data.get("show_grid", true)
	y_auto_scale = data.get("y_auto_scale", true)
	y_min = data.get("y_min", 0.0)
	y_max = data.get("y_max", 100.0)

	if data.has("background_color_r"):
		background_color = Color(
			data.get("background_color_r", 0.15),
			data.get("background_color_g", 0.15),
			data.get("background_color_b", 0.18),
			data.get("background_color_a", 1.0)
		)

	series.clear()
	var series_data: Array = data.get("series", [])
	for s in series_data:
		series.append({
			"range": s.get("range", ""),
			"name": s.get("name", ""),
			"color": Color(
				s.get("color_r", 0.5),
				s.get("color_g", 0.5),
				s.get("color_b", 0.9),
				s.get("color_a", 1.0)
			),
		})


## Create a copy of this chart
func duplicate() -> RefCounted:
	var copy = get_script().new()
	copy.load_from_dict(to_dict())
	copy.id = _generate_id()  # Give it a new ID
	return copy
