class_name ChartCanvas
extends Control
## Renders charts (line and bar) for spreadsheet data.

const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")
const ChartRendererScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ChartRenderer.gd")

## The chart definition to render
var chart: SpreadsheetChartScript = null

## Processed chart data
var chart_data: ChartRendererScript.ChartData = null

## Margins for axis labels
var margin_left: float = 60.0
var margin_right: float = 20.0
var margin_top: float = 40.0
var margin_bottom: float = 50.0
var legend_height: float = 30.0

## Font
var font: Font
var font_size: int = 12
var title_font_size: int = 16

## Bar chart settings
var bar_spacing: float = 0.2  # Fraction of bar width for spacing
var bar_group_spacing: float = 0.1  # Spacing between bar groups


func _ready() -> void:
	font = ThemeDB.fallback_font
	clip_contents = true


func _draw() -> void:
	if not chart or not chart_data or not chart_data.has_data:
		_draw_no_data()
		return

	# Draw background
	draw_rect(Rect2(Vector2.ZERO, size), chart.background_color)

	# Calculate plot area
	var legend_space := legend_height if chart.show_legend else 0.0
	var plot_rect := Rect2(
		margin_left,
		margin_top,
		size.x - margin_left - margin_right,
		size.y - margin_top - margin_bottom - legend_space
	)

	# Draw title
	_draw_title(plot_rect)

	# Draw grid
	if chart.show_grid:
		_draw_grid(plot_rect)

	# Draw axes
	_draw_axes(plot_rect)

	# Draw data
	match chart.type:
		SpreadsheetChartScript.ChartType.LINE:
			_draw_line_chart(plot_rect)
		SpreadsheetChartScript.ChartType.BAR:
			_draw_bar_chart(plot_rect)

	# Draw legend
	if chart.show_legend:
		_draw_legend(plot_rect)


func _draw_no_data() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.15, 0.15, 0.18, 1.0))

	var text := "No chart data"
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var text_pos := (size - text_size) / 2.0
	text_pos.y += font.get_ascent(font_size)

	draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.5, 0.5, 0.55, 1.0))


func _draw_title(plot_rect: Rect2) -> void:
	if chart.title.is_empty():
		return

	var text_size := font.get_string_size(chart.title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_font_size)
	var text_x := plot_rect.position.x + (plot_rect.size.x - text_size.x) / 2.0
	var text_y := margin_top / 2.0 + font.get_ascent(title_font_size) / 2.0

	draw_string(font, Vector2(text_x, text_y), chart.title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_font_size, chart.text_color)


func _draw_grid(plot_rect: Rect2) -> void:
	# Y-axis grid lines
	var y_ticks := ChartRendererScript.calculate_ticks(chart_data.y_min, chart_data.y_max, 8)
	for tick in y_ticks:
		var y := _value_to_y(tick, plot_rect)
		draw_line(
			Vector2(plot_rect.position.x, y),
			Vector2(plot_rect.end.x, y),
			chart.grid_color,
			1.0
		)

	# X-axis grid lines (vertical)
	var num_x_ticks := mini(chart_data.x_labels.size(), 10)
	if num_x_ticks > 0:
		var step := maxi(1, chart_data.x_labels.size() / num_x_ticks)
		for i in range(0, chart_data.x_labels.size(), step):
			var x := _index_to_x(i, plot_rect)
			draw_line(
				Vector2(x, plot_rect.position.y),
				Vector2(x, plot_rect.end.y),
				chart.grid_color,
				1.0
			)


func _draw_axes(plot_rect: Rect2) -> void:
	# Y-axis
	draw_line(
		Vector2(plot_rect.position.x, plot_rect.position.y),
		Vector2(plot_rect.position.x, plot_rect.end.y),
		chart.axis_color,
		2.0
	)

	# X-axis
	draw_line(
		Vector2(plot_rect.position.x, plot_rect.end.y),
		Vector2(plot_rect.end.x, plot_rect.end.y),
		chart.axis_color,
		2.0
	)

	# Y-axis labels
	var y_ticks := ChartRendererScript.calculate_ticks(chart_data.y_min, chart_data.y_max, 8)
	for tick in y_ticks:
		var y := _value_to_y(tick, plot_rect)
		var label := _format_number(tick)
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var text_x := plot_rect.position.x - text_size.x - 8
		var text_y := y + font.get_ascent(font_size) / 2.0

		draw_string(font, Vector2(text_x, text_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, chart.text_color)

		# Tick mark
		draw_line(
			Vector2(plot_rect.position.x - 4, y),
			Vector2(plot_rect.position.x, y),
			chart.axis_color,
			1.0
		)

	# X-axis labels
	var num_x_labels := mini(chart_data.x_labels.size(), 10)
	if num_x_labels > 0:
		var step := maxi(1, chart_data.x_labels.size() / num_x_labels)
		for i in range(0, chart_data.x_labels.size(), step):
			var x := _index_to_x(i, plot_rect)
			var label := chart_data.x_labels[i]

			# Truncate long labels
			if label.length() > 10:
				label = label.substr(0, 10)

			var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var text_x := x - text_size.x / 2.0
			var text_y := plot_rect.end.y + font.get_ascent(font_size) + 8

			draw_string(font, Vector2(text_x, text_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, chart.text_color)

			# Tick mark
			draw_line(
				Vector2(x, plot_rect.end.y),
				Vector2(x, plot_rect.end.y + 4),
				chart.axis_color,
				1.0
			)

	# Y-axis label
	if not chart.y_axis_label.is_empty():
		var label := chart.y_axis_label
		# Draw rotated text (approximated by drawing character by character vertically)
		var text_x := 12.0
		var text_y := plot_rect.position.y + plot_rect.size.y / 2.0
		_draw_vertical_text(Vector2(text_x, text_y), label, chart.text_color)

	# X-axis label
	if not chart.x_axis_label.is_empty():
		var text_size := font.get_string_size(chart.x_axis_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var text_x := plot_rect.position.x + (plot_rect.size.x - text_size.x) / 2.0
		var text_y := size.y - 8

		draw_string(font, Vector2(text_x, text_y), chart.x_axis_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, chart.text_color)


func _draw_line_chart(plot_rect: Rect2) -> void:
	for series_idx in range(chart_data.series_data.size()):
		var series: Dictionary = chart_data.series_data[series_idx]
		var values: PackedFloat64Array = series["values"]
		var color: Color = series["color"]

		var points: PackedVector2Array = []
		for i in range(values.size()):
			if not is_nan(values[i]):
				var x := _index_to_x(i, plot_rect)
				var y := _value_to_y(values[i], plot_rect)
				points.append(Vector2(x, y))

		# Draw line
		if points.size() >= 2:
			draw_polyline(points, color, 2.0, true)

		# Draw points
		for point in points:
			draw_circle(point, 4.0, color)
			draw_circle(point, 2.0, chart.background_color)


func _draw_bar_chart(plot_rect: Rect2) -> void:
	var num_series := chart_data.series_data.size()
	var num_points := chart_data.x_labels.size()

	if num_series == 0 or num_points == 0:
		return

	var total_width := plot_rect.size.x / float(num_points)
	var group_width := total_width * (1.0 - bar_group_spacing)
	var bar_width := group_width / float(num_series)
	var actual_bar_width := bar_width * (1.0 - bar_spacing)

	for i in range(num_points):
		var group_x := plot_rect.position.x + total_width * i + total_width * bar_group_spacing / 2.0

		for series_idx in range(num_series):
			var series: Dictionary = chart_data.series_data[series_idx]
			var values: PackedFloat64Array = series["values"]
			var color: Color = series["color"]

			if i >= values.size() or is_nan(values[i]):
				continue

			var bar_x := group_x + bar_width * series_idx + bar_spacing * bar_width / 2.0
			var bar_y := _value_to_y(values[i], plot_rect)
			var baseline_y := _value_to_y(maxf(0.0, chart_data.y_min), plot_rect)

			var bar_height := baseline_y - bar_y
			var bar_rect := Rect2(bar_x, bar_y, actual_bar_width, bar_height)

			# Draw bar
			draw_rect(bar_rect, color)

			# Draw border
			draw_rect(bar_rect, color.darkened(0.3), false, 1.0)


func _draw_legend(plot_rect: Rect2) -> void:
	if chart_data.series_data.is_empty():
		return

	var legend_y := plot_rect.end.y + margin_bottom - 5
	var legend_x := plot_rect.position.x

	var item_spacing := 20.0
	var swatch_size := 12.0
	var total_width := 0.0

	# Calculate total legend width
	for series in chart_data.series_data:
		var name: String = series["name"]
		var text_width := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		total_width += swatch_size + 6 + text_width + item_spacing

	# Center the legend
	legend_x = plot_rect.position.x + (plot_rect.size.x - total_width) / 2.0

	# Draw legend items
	for series in chart_data.series_data:
		var name: String = series["name"]
		var color: Color = series["color"]

		# Draw color swatch
		draw_rect(Rect2(legend_x, legend_y, swatch_size, swatch_size), color)

		# Draw label
		var text_x := legend_x + swatch_size + 6
		var text_y := legend_y + font.get_ascent(font_size) - 2

		draw_string(font, Vector2(text_x, text_y), name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, chart.text_color)

		var text_width := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		legend_x += swatch_size + 6 + text_width + item_spacing


func _value_to_y(value: float, plot_rect: Rect2) -> float:
	var range_val := chart_data.y_max - chart_data.y_min
	if range_val < 0.001:
		range_val = 1.0

	var normalized := (value - chart_data.y_min) / range_val
	return plot_rect.end.y - normalized * plot_rect.size.y


func _index_to_x(index: int, plot_rect: Rect2) -> float:
	var num_points := chart_data.x_labels.size()
	if num_points <= 1:
		return plot_rect.position.x + plot_rect.size.x / 2.0

	var normalized := float(index) / float(num_points - 1)
	return plot_rect.position.x + normalized * plot_rect.size.x


func _format_number(value: float) -> String:
	if absf(value) >= 1000000:
		return "%.1fM" % (value / 1000000.0)
	elif absf(value) >= 1000:
		return "%.1fK" % (value / 1000.0)
	elif absf(value) < 0.01 and value != 0:
		return "%.2e" % value
	elif absf(value - roundf(value)) < 0.001:
		return str(int(value))
	else:
		return "%.2f" % value


func _draw_vertical_text(pos: Vector2, text: String, color: Color) -> void:
	# Simple approximation: draw each character stacked vertically
	var char_height := font.get_height(font_size)
	var start_y := pos.y - (text.length() * char_height) / 2.0

	for i in range(text.length()):
		var c := text[i]
		var char_x := pos.x
		var char_y := start_y + i * char_height + font.get_ascent(font_size)
		draw_string(font, Vector2(char_x, char_y), c, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Set the chart to render
func set_chart(new_chart: SpreadsheetChartScript) -> void:
	chart = new_chart
	queue_redraw()


## Set the processed chart data
func set_chart_data(new_data: ChartRendererScript.ChartData) -> void:
	chart_data = new_data
	queue_redraw()


## Update the chart with new data from spreadsheet
func update_from_spreadsheet(spreadsheet_data) -> void:
	if chart:
		chart_data = ChartRendererScript.process(chart, spreadsheet_data)
		queue_redraw()
