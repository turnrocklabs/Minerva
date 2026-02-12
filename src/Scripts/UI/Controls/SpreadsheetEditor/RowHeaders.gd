class_name SpreadsheetRowHeaders
extends Control
## Renders the row headers (1, 2, 3, ...) for the spreadsheet.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")

signal row_clicked(row: int)
signal row_resize_started(row: int)
signal row_resize(row: int, new_height: float)
signal row_resize_ended(row: int)
signal row_context_menu_requested(row: int, screen_pos: Vector2)

## Reference to spreadsheet data
var data: SpreadsheetDataScript = null

## Scroll offset (synced with cells canvas)
var scroll_offset_y: float = 0.0

## Header width
var header_width: float = 50.0

## Colors
var bg_color: Color = Color(0.2, 0.2, 0.25, 1.0)
var border_color: Color = Color(0.3, 0.3, 0.35, 1.0)
var text_color: Color = Color(0.8, 0.8, 0.8, 1.0)
var selected_bg_color: Color = Color(0.3, 0.4, 0.5, 1.0)
var hover_color: Color = Color(0.25, 0.25, 0.3, 1.0)

## Font
var font: Font
var font_size: int = 12

## Selection state (which rows are in the selection range)
var selected_rows: Array[int] = []

## Hover state
var hovered_row: int = -1

## Resize state
var resize_handle_height: float = 6.0
var resizing_row: int = -1
var resize_start_y: float = 0.0
var resize_start_height: float = 0.0
var is_over_resize_handle: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size.x = header_width

	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size - 2


func _draw() -> void:
	if not data:
		return

	# Background
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)

	var frozen_rows := data.frozen_rows
	var frozen_row_height := _get_row_y(frozen_rows)

	# Draw scrollable row headers (after frozen rows)
	var start_row := _get_row_at_y(frozen_row_height + scroll_offset_y)
	start_row = maxi(frozen_rows, start_row)
	var end_row := _get_row_at_y(scroll_offset_y + size.y) + 1
	end_row = mini(data.row_count, end_row)

	for row in range(start_row, end_row):
		_draw_row_header(row, scroll_offset_y)

	# Draw frozen row headers (always visible at top)
	if frozen_rows > 0:
		for row in range(frozen_rows):
			_draw_row_header(row, 0)
		# Draw separator line
		draw_line(
			Vector2(0, frozen_row_height),
			Vector2(size.x, frozen_row_height),
			Color(0.5, 0.5, 0.6, 1.0),
			2.0
		)

	# Draw resize handle indicator if hovering
	if is_over_resize_handle and resizing_row < 0:
		var offset := 0.0 if hovered_row < frozen_rows else scroll_offset_y
		var handle_y := _get_row_y(hovered_row + 1) - offset
		draw_line(
			Vector2(0, handle_y),
			Vector2(size.x, handle_y),
			Color.WHITE,
			2.0
		)


func _draw_row_header(row: int, offset: float = 0.0) -> void:
	var y := _get_row_y(row) - offset
	var height := data.get_row_height(row)
	var rect := Rect2(0, y, size.x, height)

	# Background
	var bg := bg_color
	if row < data.frozen_rows:
		bg = bg.lightened(0.05)  # Slightly lighter for frozen rows
	if row in selected_rows:
		bg = selected_bg_color
	elif row == hovered_row:
		bg = hover_color
	draw_rect(rect, bg)

	# Border
	draw_line(Vector2(0, rect.end.y), Vector2(size.x, rect.end.y), border_color)
	draw_line(Vector2(rect.end.x, rect.position.y), Vector2(rect.end.x, rect.end.y), border_color)

	# Label (1-indexed)
	var label := str(row + 1)
	var text_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var text_x := (size.x - text_width) / 2.0
	var text_y := y + (height + font.get_height(font_size)) / 2.0 - font.get_descent(font_size)

	draw_string(font, Vector2(text_x, text_y), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 4, font_size, text_color)


func _gui_input(event: InputEvent) -> void:
	if not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			var y_ := event.position.y + scroll_offset_y
			var row := _get_row_at_y(y_)
			if row >= 0:
				row_context_menu_requested.emit(row, get_screen_position() + event.position)
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	var y := event.position.y + scroll_offset_y

	if event.pressed:
		# Check if clicking on resize handle
		var resize_row := _get_resize_handle_row(event.position.y)
		if resize_row >= 0:
			resizing_row = resize_row
			resize_start_y = event.position.y
			resize_start_height = data.get_row_height(resize_row)
			row_resize_started.emit(resize_row)
			return

		# Row selection
		var row := _get_row_at_y(y)
		if row >= 0:
			row_clicked.emit(row)
	else:
		# End resize
		if resizing_row >= 0:
			row_resize_ended.emit(resizing_row)
			resizing_row = -1


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var y := event.position.y + scroll_offset_y

	if resizing_row >= 0:
		# Resizing row
		var delta := event.position.y - resize_start_y
		var new_height := maxf(SpreadsheetDataScript.MIN_ROW_HEIGHT, resize_start_height + delta)
		new_height = minf(SpreadsheetDataScript.MAX_ROW_HEIGHT, new_height)
		row_resize.emit(resizing_row, new_height)
		return

	# Check for resize handle hover
	var resize_row := _get_resize_handle_row(event.position.y)
	if resize_row >= 0:
		is_over_resize_handle = true
		hovered_row = resize_row
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
	else:
		is_over_resize_handle = false
		mouse_default_cursor_shape = Control.CURSOR_ARROW

		# Update hover
		var row := _get_row_at_y(y)
		if row != hovered_row:
			hovered_row = row
			queue_redraw()


func _get_resize_handle_row(screen_y: float) -> int:
	var y := screen_y + scroll_offset_y

	var row_y := 0.0
	for row in range(data.row_count):
		row_y += data.get_row_height(row)
		var handle_start := row_y - resize_handle_height / 2.0
		var handle_end := row_y + resize_handle_height / 2.0

		if y >= handle_start and y <= handle_end:
			return row

	return -1


func _get_row_at_y(y: float) -> int:
	var current_y := 0.0

	for row in range(data.row_count):
		var height := data.get_row_height(row)
		if y >= current_y and y < current_y + height:
			return row
		current_y += height

	# Return last row for coordinates beyond data bounds
	return data.row_count - 1 if data.row_count > 0 else -1


func _get_row_y(row: int) -> float:
	var y := 0.0
	for r in range(mini(row, data.row_count)):
		y += data.get_row_height(r)
	return y


func set_scroll_offset(offset: float) -> void:
	scroll_offset_y = offset
	queue_redraw()


func set_selected_rows(rows: Array[int]) -> void:
	selected_rows = rows
	queue_redraw()


func set_data(new_data: SpreadsheetDataScript) -> void:
	data = new_data
	queue_redraw()
