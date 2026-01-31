class_name SpreadsheetCellsCanvas
extends Control
## Renders the spreadsheet grid with cells, selection, and handles input.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")

signal cell_selected(row: int, col: int)
signal cell_double_clicked(row: int, col: int)
signal selection_changed(start_row: int, start_col: int, end_row: int, end_col: int)
signal scroll_changed(offset: Vector2)
signal navigation_requested(direction: String)
signal edit_requested()

## Reference to spreadsheet data
var data: SpreadsheetDataScript = null

## Scroll offset
var scroll_offset: Vector2 = Vector2.ZERO

## Selection state
var selection_anchor: Vector2i = Vector2i(-1, -1)  # Start of selection
var selection_active: Vector2i = Vector2i(-1, -1)  # Current end of selection
var is_selecting: bool = false

## Multi-selection state (for Ctrl+Click)
## Each item is a Rect2i representing a selection range
var additional_selections: Array[Rect2i] = []

## Hover state
var hovered_cell: Vector2i = Vector2i(-1, -1)

## Colors (will be updated from theme)
var grid_line_color: Color = Color(0.3, 0.3, 0.3, 1.0)
var cell_bg_color: Color = Color(0.15, 0.15, 0.15, 1.0)
var header_bg_color: Color = Color(0.2, 0.2, 0.25, 1.0)
var selection_color: Color = Color(0.3, 0.5, 0.8, 0.3)
var selection_border_color: Color = Color(0.4, 0.6, 0.9, 1.0)
var hover_color: Color = Color(0.25, 0.25, 0.3, 0.5)
var text_color: Color = Color.WHITE
var frozen_separator_color: Color = Color(0.5, 0.5, 0.6, 1.0)

## Font
var font: Font
var font_size: int = 14
var cell_padding: float = 4.0

## Resize handle state
var resize_handle_width: float = 6.0
var resizing_column: int = -1
var resizing_row: int = -1
var resize_start_pos: float = 0.0
var resize_start_size: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true

	# Prevent Tab from leaving the spreadsheet by setting focus neighbors to self
	focus_neighbor_top = get_path()
	focus_neighbor_bottom = get_path()
	focus_neighbor_left = get_path()
	focus_neighbor_right = get_path()
	focus_next = get_path()
	focus_previous = get_path()

	# Get default font
	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size


func _draw() -> void:
	if not data:
		return

	var frozen_rows := data.frozen_rows
	var frozen_cols := data.frozen_cols
	var frozen_row_height := _get_row_y(frozen_rows)
	var frozen_col_width := _get_col_x(frozen_cols)

	# Calculate visible cell range for scrollable area
	# The scrollable area starts at (frozen_col_width, frozen_row_height) in screen space
	# We need to find which data rows/cols map to this visible region
	var scrollable_start_x := frozen_col_width + scroll_offset.x
	var scrollable_start_y := frozen_row_height + scroll_offset.y
	var scrollable_end_x := scroll_offset.x + size.x
	var scrollable_end_y := scroll_offset.y + size.y

	var start_col := _get_col_at_x(scrollable_start_x)
	var end_col := _get_col_at_x(scrollable_end_x) + 1
	var start_row := _get_row_at_y(scrollable_start_y)
	var end_row := _get_row_at_y(scrollable_end_y) + 1

	start_col = maxi(frozen_cols, start_col)
	end_col = mini(data.column_count, end_col)
	start_row = maxi(frozen_rows, start_row)
	end_row = mini(data.row_count, end_row)

	# 1. Draw scrollable area (non-frozen cells)
	# The scrollable area uses scroll_offset directly - when scroll_offset = 0,
	# the first scrollable row/col appears right after the frozen area
	_draw_region(start_row, start_col, end_row, end_col, scroll_offset)

	# 2. Draw frozen rows (top strip, scrolls horizontally only)
	if frozen_rows > 0:
		var frozen_row_start_col := _get_col_at_x(frozen_col_width + scroll_offset.x)
		frozen_row_start_col = maxi(frozen_cols, frozen_row_start_col)
		var frozen_row_end_col := _get_col_at_x(scroll_offset.x + size.x) + 1
		frozen_row_end_col = mini(data.column_count, frozen_row_end_col)
		var frozen_row_offset := Vector2(scroll_offset.x, 0)
		_draw_region(0, frozen_row_start_col, frozen_rows, frozen_row_end_col, frozen_row_offset)

	# 3. Draw frozen columns (left strip, scrolls vertically only)
	if frozen_cols > 0:
		var frozen_col_start_row := _get_row_at_y(frozen_row_height + scroll_offset.y)
		frozen_col_start_row = maxi(frozen_rows, frozen_col_start_row)
		var frozen_col_end_row := _get_row_at_y(scroll_offset.y + size.y) + 1
		frozen_col_end_row = mini(data.row_count, frozen_col_end_row)
		var frozen_col_offset := Vector2(0, scroll_offset.y)
		_draw_region(frozen_col_start_row, 0, frozen_col_end_row, frozen_cols, frozen_col_offset)

	# 4. Draw frozen corner (top-left intersection, doesn't scroll at all)
	if frozen_rows > 0 and frozen_cols > 0:
		_draw_region(0, 0, frozen_rows, frozen_cols, Vector2.ZERO)

	# Draw selection across all regions
	_draw_selection()

	# Draw hover highlight
	if hovered_cell.x >= 0 and hovered_cell.y >= 0:
		_draw_cell_highlight(hovered_cell.y, hovered_cell.x, hover_color)

	# Draw frozen pane separators on top
	_draw_frozen_separators()


## Draw a region of cells with the given offset
func _draw_region(start_row: int, start_col: int, end_row: int, end_col: int, offset: Vector2) -> void:
	_draw_cell_backgrounds_region(start_row, start_col, end_row, end_col, offset)
	_draw_grid_lines_region(start_row, start_col, end_row, end_col, offset)
	_draw_cell_content_region(start_row, start_col, end_row, end_col, offset)


func _draw_cell_backgrounds_region(start_row: int, start_col: int, end_row: int, end_col: int, offset: Vector2) -> void:
	for row in range(start_row, end_row):
		for col in range(start_col, end_col):
			var rect := _get_cell_rect(row, col)
			rect.position -= offset

			var cell := data.get_cell_if_exists(row, col)
			var bg := cell_bg_color

			# Header row styling
			if row < data.header_row_count:
				bg = header_bg_color

			# Frozen row/col gets slightly different background
			if row < data.frozen_rows or col < data.frozen_cols:
				bg = bg.lightened(0.05)

			# Custom cell background
			if cell and cell.bg_color != Color.TRANSPARENT:
				bg = cell.bg_color

			draw_rect(rect, bg)


func _draw_grid_lines_region(start_row: int, start_col: int, end_row: int, end_col: int, offset: Vector2) -> void:
	# Calculate region bounds for clipping lines
	var region_left := _get_col_x(start_col) - offset.x
	var region_top := _get_row_y(start_row) - offset.y
	var region_right := _get_col_x(end_col) - offset.x
	var region_bottom := _get_row_y(end_row) - offset.y

	# Vertical lines
	var x := _get_col_x(start_col) - offset.x
	for col in range(start_col, end_col + 1):
		var col_width := data.get_column_width(col) if col < data.column_count else SpreadsheetDataScript.DEFAULT_COLUMN_WIDTH
		draw_line(
			Vector2(x, region_top),
			Vector2(x, region_bottom),
			grid_line_color,
			1.0
		)
		x += col_width

	# Horizontal lines
	var y := _get_row_y(start_row) - offset.y
	for row in range(start_row, end_row + 1):
		var row_height := data.get_row_height(row) if row < data.row_count else SpreadsheetDataScript.DEFAULT_ROW_HEIGHT
		draw_line(
			Vector2(region_left, y),
			Vector2(region_right, y),
			grid_line_color,
			1.0
		)
		y += row_height


func _draw_cell_content_region(start_row: int, start_col: int, end_row: int, end_col: int, offset: Vector2) -> void:
	for row in range(start_row, end_row):
		for col in range(start_col, end_col):
			var cell := data.get_cell_if_exists(row, col)
			if not cell or cell.is_empty():
				continue

			var rect := _get_cell_rect(row, col)
			rect.position -= offset

			var display_text: String = cell.get_display_text()
			if display_text.is_empty():
				continue

			# Calculate text position
			var text_rect := rect.grow(-cell_padding)
			var text_pos := text_rect.position

			# Get font variant
			var draw_font := font
			var draw_size := font_size

			# Vertical centering
			var line_height := font.get_height(draw_size)
			text_pos.y += (text_rect.size.y + line_height) / 2.0 - font.get_descent(draw_size)

			# Horizontal alignment
			var text_width := font.get_string_size(display_text, HORIZONTAL_ALIGNMENT_LEFT, -1, draw_size).x

			match cell.alignment:
				HORIZONTAL_ALIGNMENT_CENTER:
					text_pos.x += (text_rect.size.x - text_width) / 2.0
				HORIZONTAL_ALIGNMENT_RIGHT:
					text_pos.x += text_rect.size.x - text_width

			# Text color
			var color: Color = cell.text_color if cell.text_color != Color.TRANSPARENT else text_color

			# Draw text (clipped to cell)
			draw_string(
				draw_font,
				text_pos,
				display_text,
				HORIZONTAL_ALIGNMENT_LEFT,
				text_rect.size.x,
				draw_size,
				color
			)


func _draw_selection() -> void:
	# Draw additional selections first (from Ctrl+Click)
	for sel_rect in additional_selections:
		_draw_selection_rect(sel_rect)

	# Draw current selection
	if selection_anchor.x < 0 or selection_active.x < 0:
		return

	var sel_rect := get_selection_rect()
	_draw_selection_rect(sel_rect)


func _draw_selection_rect(sel_rect: Rect2i) -> void:
	if sel_rect.size.x <= 0 or sel_rect.size.y <= 0:
		return

	# For selections spanning frozen and non-frozen areas, we need to draw multiple rects
	# For simplicity, we'll use the offset for the top-left cell
	var offset := _get_cell_offset(sel_rect.position.y, sel_rect.position.x)

	var start_rect := _get_cell_rect(sel_rect.position.y, sel_rect.position.x)
	var end_rect := _get_cell_rect(sel_rect.end.y - 1, sel_rect.end.x - 1)

	var visual_rect := Rect2(
		start_rect.position - offset,
		Vector2(end_rect.end.x - start_rect.position.x, end_rect.end.y - start_rect.position.y)
	)

	draw_rect(visual_rect, selection_color)
	draw_rect(visual_rect, selection_border_color, false, 2.0)


func _draw_cell_highlight(row: int, col: int, color: Color) -> void:
	var rect := _get_cell_rect(row, col)
	rect.position -= _get_cell_offset(row, col)
	draw_rect(rect, color)


## Get the scroll offset to use for a cell based on frozen panes
func _get_cell_offset(row: int, col: int) -> Vector2:
	var offset := Vector2.ZERO

	if col >= data.frozen_cols:
		offset.x = scroll_offset.x
	if row >= data.frozen_rows:
		offset.y = scroll_offset.y
	return offset


func _draw_frozen_separators() -> void:
	if not data:
		return

	# Frozen rows separator
	if data.frozen_rows > 0:
		var y := _get_row_y(data.frozen_rows) - scroll_offset.y
		# But frozen rows don't scroll, so adjust
		y = _get_row_y(data.frozen_rows)
		draw_line(
			Vector2(0, y),
			Vector2(size.x, y),
			frozen_separator_color,
			2.0
		)

	# Frozen columns separator
	if data.frozen_cols > 0:
		var x := _get_col_x(data.frozen_cols)
		draw_line(
			Vector2(x, 0),
			Vector2(x, size.y),
			frozen_separator_color,
			2.0
		)


func _gui_input(event: InputEvent) -> void:
	if not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		_handle_key_input(event)


func _handle_key_input(event: InputEventKey) -> void:
	if not event.pressed:
		return

	var key := event.keycode

	# Handle Tab - move to next/previous cell
	if key == KEY_TAB:
		accept_event()  # Prevent Godot's focus navigation
		if event.shift_pressed:
			navigation_requested.emit("left")
		else:
			navigation_requested.emit("right")
		return

	# Handle Enter - move down or edit
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		accept_event()
		if event.shift_pressed:
			navigation_requested.emit("up")
		else:
			navigation_requested.emit("down")
		return

	# Handle arrow keys
	if key == KEY_UP:
		accept_event()
		navigation_requested.emit("up")
		return

	if key == KEY_DOWN:
		accept_event()
		navigation_requested.emit("down")
		return

	if key == KEY_LEFT:
		accept_event()
		navigation_requested.emit("left")
		return

	if key == KEY_RIGHT:
		accept_event()
		navigation_requested.emit("right")
		return

	# Handle F2 or starting to type - begin editing
	if key == KEY_F2:
		accept_event()
		edit_requested.emit()
		return

	# Handle Delete/Backspace - clear selection
	if key == KEY_DELETE or key == KEY_BACKSPACE:
		accept_event()
		navigation_requested.emit("delete")
		return

	# Handle Escape - clear selection mode
	if key == KEY_ESCAPE:
		accept_event()
		navigation_requested.emit("escape")
		return

	# Handle Home/End
	if key == KEY_HOME:
		accept_event()
		if event.ctrl_pressed:
			navigation_requested.emit("home_doc")
		else:
			navigation_requested.emit("home_row")
		return

	if key == KEY_END:
		accept_event()
		if event.ctrl_pressed:
			navigation_requested.emit("end_doc")
		else:
			navigation_requested.emit("end_row")
		return

	# Start editing on printable characters
	if _is_printable_key(event):
		accept_event()
		edit_requested.emit()


func _is_printable_key(event: InputEventKey) -> bool:
	# Check if the key press would produce a printable character
	var unicode := event.unicode
	if unicode > 31 and unicode != 127:  # Printable ASCII range
		return true
	return false


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var pos := event.position + scroll_offset
	var cell := _get_cell_at_pos(pos)

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()
			if event.double_click:
				if cell.x >= 0 and cell.y >= 0:
					cell_double_clicked.emit(cell.y, cell.x)
			else:
				# Start selection
				is_selecting = true
				if event.shift_pressed and selection_anchor.x >= 0:
					# Extend selection
					selection_active = cell
				elif event.ctrl_pressed and selection_anchor.x >= 0:
					# Ctrl+Click: Add current selection to additional selections and start new one
					var current_rect := get_selection_rect()
					if current_rect.size.x > 0 and current_rect.size.y > 0:
						additional_selections.append(current_rect)
					selection_anchor = cell
					selection_active = cell
				else:
					# New selection (clear additional selections)
					additional_selections.clear()
					selection_anchor = cell
					selection_active = cell

				if cell.x >= 0 and cell.y >= 0:
					cell_selected.emit(cell.y, cell.x)

				queue_redraw()
		else:
			# End selection
			if is_selecting:
				is_selecting = false
				_emit_selection_changed()

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_offset.y = maxf(0, scroll_offset.y - 30)
		scroll_changed.emit(scroll_offset)
		queue_redraw()

	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		scroll_offset.y = minf(_get_max_scroll_y(), scroll_offset.y + 30)
		scroll_changed.emit(scroll_offset)
		queue_redraw()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var pos := event.position + scroll_offset
	var cell := _get_cell_at_pos(pos)

	# Update hover
	if cell != hovered_cell:
		hovered_cell = cell
		queue_redraw()

	# Update selection if dragging
	if is_selecting and cell.x >= 0 and cell.y >= 0:
		if cell != selection_active:
			selection_active = cell
			queue_redraw()


func _get_cell_at_pos(pos: Vector2) -> Vector2i:
	var col := _get_col_at_x(pos.x)
	var row := _get_row_at_y(pos.y)

	if col >= 0 and col < data.column_count and row >= 0 and row < data.row_count:
		return Vector2i(col, row)

	return Vector2i(-1, -1)


func _get_col_at_x(x: float) -> int:
	var current_x := 0.0

	for col in range(data.column_count):
		var width := data.get_column_width(col)
		if x >= current_x and x < current_x + width:
			return col
		current_x += width

	return -1


func _get_row_at_y(y: float) -> int:
	var current_y := 0.0

	for row in range(data.row_count):
		var height := data.get_row_height(row)
		if y >= current_y and y < current_y + height:
			return row
		current_y += height

	return -1


func _get_col_x(col: int) -> float:
	var x := 0.0
	for c in range(mini(col, data.column_count)):
		x += data.get_column_width(c)
	return x


func _get_row_y(row: int) -> float:
	var y := 0.0
	for r in range(mini(row, data.row_count)):
		y += data.get_row_height(r)
	return y


func _get_cell_rect(row: int, col: int) -> Rect2:
	return Rect2(
		_get_col_x(col),
		_get_row_y(row),
		data.get_column_width(col),
		data.get_row_height(row)
	)


func get_cell_screen_rect(row: int, col: int) -> Rect2:
	var rect := _get_cell_rect(row, col)
	rect.position -= _get_cell_offset(row, col)
	return rect


func _get_max_scroll_x() -> float:
	var total_width := 0.0
	for col in range(data.column_count):
		total_width += data.get_column_width(col)
	return maxf(0, total_width - size.x)


func _get_max_scroll_y() -> float:
	var total_height := 0.0
	for row in range(data.row_count):
		total_height += data.get_row_height(row)
	return maxf(0, total_height - size.y)


func get_selection_rect() -> Rect2i:
	if selection_anchor.x < 0 or selection_active.x < 0:
		return Rect2i(0, 0, 0, 0)

	var min_col := mini(selection_anchor.x, selection_active.x)
	var max_col := maxi(selection_anchor.x, selection_active.x)
	var min_row := mini(selection_anchor.y, selection_active.y)
	var max_row := maxi(selection_anchor.y, selection_active.y)

	return Rect2i(min_col, min_row, max_col - min_col + 1, max_row - min_row + 1)


func select_cell(row: int, col: int) -> void:
	additional_selections.clear()
	selection_anchor = Vector2i(col, row)
	selection_active = Vector2i(col, row)
	_emit_selection_changed()
	queue_redraw()


func select_range(start_row: int, start_col: int, end_row: int, end_col: int) -> void:
	additional_selections.clear()
	selection_anchor = Vector2i(start_col, start_row)
	selection_active = Vector2i(end_col, end_row)
	_emit_selection_changed()
	queue_redraw()


func clear_selection() -> void:
	additional_selections.clear()
	selection_anchor = Vector2i(-1, -1)
	selection_active = Vector2i(-1, -1)
	queue_redraw()


## Returns all selection rectangles (additional + current)
func get_all_selection_rects() -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	result.append_array(additional_selections)

	var current := get_selection_rect()
	if current.size.x > 0 and current.size.y > 0:
		result.append(current)

	return result


## Check if a cell is in any selection
func is_cell_selected(row: int, col: int) -> bool:
	for sel_rect in get_all_selection_rects():
		if col >= sel_rect.position.x and col < sel_rect.end.x and \
		   row >= sel_rect.position.y and row < sel_rect.end.y:
			return true
	return false


func _emit_selection_changed() -> void:
	var rect := get_selection_rect()
	selection_changed.emit(rect.position.y, rect.position.x, rect.end.y - 1, rect.end.x - 1)


func scroll_to_cell(row: int, col: int) -> void:
	var cell_rect := _get_cell_rect(row, col)

	# Scroll horizontally if needed
	if cell_rect.position.x < scroll_offset.x:
		scroll_offset.x = cell_rect.position.x
	elif cell_rect.end.x > scroll_offset.x + size.x:
		scroll_offset.x = cell_rect.end.x - size.x

	# Scroll vertically if needed
	if cell_rect.position.y < scroll_offset.y:
		scroll_offset.y = cell_rect.position.y
	elif cell_rect.end.y > scroll_offset.y + size.y:
		scroll_offset.y = cell_rect.end.y - size.y

	scroll_offset.x = clampf(scroll_offset.x, 0, _get_max_scroll_x())
	scroll_offset.y = clampf(scroll_offset.y, 0, _get_max_scroll_y())

	scroll_changed.emit(scroll_offset)
	queue_redraw()


func set_scroll(offset: Vector2) -> void:
	scroll_offset = offset
	scroll_offset.x = clampf(scroll_offset.x, 0, _get_max_scroll_x())
	scroll_offset.y = clampf(scroll_offset.y, 0, _get_max_scroll_y())
	queue_redraw()


func get_total_width() -> float:
	var total := 0.0
	for col in range(data.column_count):
		total += data.get_column_width(col)
	return total


func get_total_height() -> float:
	var total := 0.0
	for row in range(data.row_count):
		total += data.get_row_height(row)
	return total


func update_theme_colors() -> void:
	# Could be extended to read from theme
	queue_redraw()


func set_data(new_data: SpreadsheetDataScript) -> void:
	if data:
		if data.data_changed.is_connected(_on_data_changed):
			data.data_changed.disconnect(_on_data_changed)
		if data.structure_changed.is_connected(_on_structure_changed):
			data.structure_changed.disconnect(_on_structure_changed)

	data = new_data

	if data:
		data.data_changed.connect(_on_data_changed)
		data.structure_changed.connect(_on_structure_changed)

	queue_redraw()


func _on_data_changed() -> void:
	queue_redraw()


func _on_structure_changed() -> void:
	queue_redraw()
