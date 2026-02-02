class_name SpreadsheetColumnHeaders
extends Control
## Renders the column headers (A, B, C, ...) for the spreadsheet.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")

signal column_clicked(col: int)
signal column_resize_started(col: int)
signal column_resize(col: int, new_width: float)
signal column_resize_ended(col: int)
signal column_autofit_requested(col: int)

## Reference to spreadsheet data
var data: SpreadsheetDataScript = null

## Scroll offset (synced with cells canvas)
var scroll_offset_x: float = 0.0

## Header height
var header_height: float = 24.0

## Colors
var bg_color: Color = Color(0.2, 0.2, 0.25, 1.0)
var border_color: Color = Color(0.3, 0.3, 0.35, 1.0)
var text_color: Color = Color(0.8, 0.8, 0.8, 1.0)
var selected_bg_color: Color = Color(0.3, 0.4, 0.5, 1.0)
var hover_color: Color = Color(0.25, 0.25, 0.3, 1.0)

## Font
var font: Font
var font_size: int = 12

## Selection state (which columns are in the selection range)
var selected_cols: Array[int] = []

## Hover state
var hovered_col: int = -1

## Resize state
var resize_handle_width: float = 6.0
var resizing_col: int = -1
var resize_start_x: float = 0.0
var resize_start_width: float = 0.0
var is_over_resize_handle: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size.y = header_height

	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size - 2


func _draw() -> void:
	if not data:
		return

	# Background
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)

	var frozen_cols := data.frozen_cols
	var frozen_col_width := _get_col_x(frozen_cols)

	# Draw scrollable column headers (after frozen columns)
	var start_col := _get_col_at_x(frozen_col_width + scroll_offset_x)
	start_col = maxi(frozen_cols, start_col)
	var end_col := _get_col_at_x(scroll_offset_x + size.x) + 1
	end_col = mini(data.column_count, end_col)

	for col in range(start_col, end_col):
		_draw_column_header(col, scroll_offset_x)

	# Draw frozen column headers (always visible at left)
	if frozen_cols > 0:
		for col in range(frozen_cols):
			_draw_column_header(col, 0)
		# Draw separator line
		draw_line(
			Vector2(frozen_col_width, 0),
			Vector2(frozen_col_width, size.y),
			Color(0.5, 0.5, 0.6, 1.0),
			2.0
		)

	# Draw resize handle indicator if hovering
	if is_over_resize_handle and resizing_col < 0:
		var offset := 0.0 if hovered_col < frozen_cols else scroll_offset_x
		var handle_x := _get_col_x(hovered_col + 1) - offset
		draw_line(
			Vector2(handle_x, 0),
			Vector2(handle_x, size.y),
			Color.WHITE,
			2.0
		)


func _draw_column_header(col: int, offset: float = 0.0) -> void:
	var x := _get_col_x(col) - offset
	var width := data.get_column_width(col)
	var rect := Rect2(x, 0, width, size.y)

	# Background
	var bg := bg_color
	if col < data.frozen_cols:
		bg = bg.lightened(0.05)  # Slightly lighter for frozen columns
	if col in selected_cols:
		bg = selected_bg_color
	elif col == hovered_col:
		bg = hover_color
	draw_rect(rect, bg)

	# Border
	draw_line(Vector2(rect.end.x, 0), Vector2(rect.end.x, size.y), border_color)
	draw_line(Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.end.y), border_color)

	# Label
	var label := SpreadsheetDataScript.get_column_label(col)

	# Custom header name
	if col < data.column_meta.size() and not data.column_meta[col].header_name.is_empty():
		label = data.column_meta[col].header_name

	var text_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var text_x := x + (width - text_width) / 2.0
	var text_y := (size.y + font.get_height(font_size)) / 2.0 - font.get_descent(font_size)

	draw_string(font, Vector2(text_x, text_y), label, HORIZONTAL_ALIGNMENT_LEFT, width - 4, font_size, text_color)


func _gui_input(event: InputEvent) -> void:
	if not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	var x := event.position.x + scroll_offset_x

	if event.pressed:
		# Check if double-clicking on resize handle (auto-fit)
		var resize_col := _get_resize_handle_col(event.position.x)
		if resize_col >= 0:
			if event.double_click:
				# Auto-fit column width
				column_autofit_requested.emit(resize_col)
				return
			resizing_col = resize_col
			resize_start_x = event.position.x
			resize_start_width = data.get_column_width(resize_col)
			column_resize_started.emit(resize_col)
			return

		# Column selection
		var col := _get_col_at_x(x)
		if col >= 0:
			column_clicked.emit(col)
	else:
		# End resize
		if resizing_col >= 0:
			column_resize_ended.emit(resizing_col)
			resizing_col = -1


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var x := event.position.x + scroll_offset_x

	if resizing_col >= 0:
		# Resizing column
		var delta := event.position.x - resize_start_x
		var new_width := maxf(SpreadsheetDataScript.MIN_COLUMN_WIDTH, resize_start_width + delta)
		new_width = minf(SpreadsheetDataScript.MAX_COLUMN_WIDTH, new_width)
		column_resize.emit(resizing_col, new_width)
		return

	# Check for resize handle hover
	var resize_col := _get_resize_handle_col(event.position.x)
	if resize_col >= 0:
		is_over_resize_handle = true
		hovered_col = resize_col
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	else:
		is_over_resize_handle = false
		mouse_default_cursor_shape = Control.CURSOR_ARROW

		# Update hover
		var col := _get_col_at_x(x)
		if col != hovered_col:
			hovered_col = col
			queue_redraw()


func _get_resize_handle_col(screen_x: float) -> int:
	var x := screen_x + scroll_offset_x

	var col_x := 0.0
	for col in range(data.column_count):
		col_x += data.get_column_width(col)
		var handle_start := col_x - resize_handle_width / 2.0
		var handle_end := col_x + resize_handle_width / 2.0

		if x >= handle_start and x <= handle_end:
			return col

	return -1


func _get_col_at_x(x: float) -> int:
	var current_x := 0.0

	for col in range(data.column_count):
		var width := data.get_column_width(col)
		if x >= current_x and x < current_x + width:
			return col
		current_x += width

	# Return last column for coordinates beyond data bounds
	return data.column_count - 1 if data.column_count > 0 else -1


func _get_col_x(col: int) -> float:
	var x := 0.0
	for c in range(mini(col, data.column_count)):
		x += data.get_column_width(c)
	return x


func set_scroll_offset(offset: float) -> void:
	scroll_offset_x = offset
	queue_redraw()


func set_selected_columns(cols: Array[int]) -> void:
	selected_cols = cols
	queue_redraw()


func set_data(new_data: SpreadsheetDataScript) -> void:
	data = new_data
	queue_redraw()
