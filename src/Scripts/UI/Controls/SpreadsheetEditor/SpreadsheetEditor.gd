class_name SpreadsheetEditor
extends PanelContainer
## Main spreadsheet editor control combining grid, headers, and editing functionality.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")
const SpreadsheetCellsCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/CellsCanvas.gd")
const SpreadsheetColumnHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ColumnHeaders.gd")
const SpreadsheetRowHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/RowHeaders.gd")

signal content_changed()
signal selection_changed(start_row: int, start_col: int, end_row: int, end_col: int)

## Spreadsheet data
var spreadsheet_data  # SpreadsheetData

## UI Components
var main_container: VBoxContainer
var toolbar: HBoxContainer
var formula_bar: HBoxContainer
var cell_address_label: Label
var formula_edit: LineEdit
var grid_container: Control
var corner_panel: Panel
var column_headers  # SpreadsheetColumnHeaders
var row_headers  # SpreadsheetRowHeaders
var cells_canvas  # SpreadsheetCellsCanvas
var h_scrollbar: HScrollBar
var v_scrollbar: VScrollBar
var inline_editor: LineEdit

## Current selection
var current_row: int = 0
var current_col: int = 0

## Editing state
var is_editing: bool = false

## Header sizes
var row_header_width: float = 50.0
var column_header_height: float = 24.0


func _ready() -> void:
	# Initialize data
	spreadsheet_data = SpreadsheetDataScript.new()

	# Build UI
	_build_ui()

	# Connect signals
	_connect_signals()

	# Initial selection
	_update_selection_display()


func _build_ui() -> void:
	# Main vertical container
	main_container = VBoxContainer.new()
	main_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_container)

	# Toolbar
	_build_toolbar()

	# Formula bar
	_build_formula_bar()

	# Grid area
	_build_grid_area()

	# Inline editor (hidden initially)
	_build_inline_editor()


func _build_toolbar() -> void:
	toolbar = HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 4)
	main_container.add_child(toolbar)

	# Bold button
	var bold_btn := Button.new()
	bold_btn.text = "B"
	bold_btn.tooltip_text = "Bold (Ctrl+B)"
	bold_btn.custom_minimum_size = Vector2(30, 28)
	bold_btn.pressed.connect(_on_bold_pressed)
	toolbar.add_child(bold_btn)

	# Italic button
	var italic_btn := Button.new()
	italic_btn.text = "I"
	italic_btn.tooltip_text = "Italic (Ctrl+I)"
	italic_btn.custom_minimum_size = Vector2(30, 28)
	italic_btn.pressed.connect(_on_italic_pressed)
	toolbar.add_child(italic_btn)

	# Separator
	var sep1 := VSeparator.new()
	toolbar.add_child(sep1)

	# Alignment buttons
	var align_left := Button.new()
	align_left.text = "L"
	align_left.tooltip_text = "Align Left"
	align_left.custom_minimum_size = Vector2(30, 28)
	align_left.pressed.connect(_on_align_left_pressed)
	toolbar.add_child(align_left)

	var align_center := Button.new()
	align_center.text = "C"
	align_center.tooltip_text = "Align Center"
	align_center.custom_minimum_size = Vector2(30, 28)
	align_center.pressed.connect(_on_align_center_pressed)
	toolbar.add_child(align_center)

	var align_right := Button.new()
	align_right.text = "R"
	align_right.tooltip_text = "Align Right"
	align_right.custom_minimum_size = Vector2(30, 28)
	align_right.pressed.connect(_on_align_right_pressed)
	toolbar.add_child(align_right)

	# Separator
	var sep2 := VSeparator.new()
	toolbar.add_child(sep2)

	# Header row button
	var header_btn := Button.new()
	header_btn.text = "Header"
	header_btn.tooltip_text = "Toggle Header Row"
	header_btn.pressed.connect(_on_header_row_pressed)
	toolbar.add_child(header_btn)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)


func _build_formula_bar() -> void:
	formula_bar = HBoxContainer.new()
	formula_bar.add_theme_constant_override("separation", 8)
	main_container.add_child(formula_bar)

	# Cell address label
	cell_address_label = Label.new()
	cell_address_label.text = "A1"
	cell_address_label.custom_minimum_size = Vector2(60, 0)
	cell_address_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	formula_bar.add_child(cell_address_label)

	# Separator
	var sep := VSeparator.new()
	formula_bar.add_child(sep)

	# Formula/value edit
	formula_edit = LineEdit.new()
	formula_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	formula_edit.placeholder_text = "Enter value or formula (e.g., =SUM(A1:A10))"
	formula_edit.text_submitted.connect(_on_formula_submitted)
	formula_edit.text_changed.connect(_on_formula_text_changed)
	formula_bar.add_child(formula_edit)


func _build_grid_area() -> void:
	# Grid container with headers and cells
	grid_container = Control.new()
	grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_container.clip_contents = true
	main_container.add_child(grid_container)

	# Corner panel (top-left)
	corner_panel = Panel.new()
	corner_panel.position = Vector2.ZERO
	corner_panel.size = Vector2(row_header_width, column_header_height)
	grid_container.add_child(corner_panel)

	# Column headers
	column_headers = SpreadsheetColumnHeadersScript.new()
	column_headers.header_height = column_header_height
	column_headers.set_data(spreadsheet_data)
	grid_container.add_child(column_headers)

	# Row headers
	row_headers = SpreadsheetRowHeadersScript.new()
	row_headers.header_width = row_header_width
	row_headers.set_data(spreadsheet_data)
	grid_container.add_child(row_headers)

	# Cells canvas
	cells_canvas = SpreadsheetCellsCanvasScript.new()
	cells_canvas.set_data(spreadsheet_data)
	grid_container.add_child(cells_canvas)

	# Scrollbars
	h_scrollbar = HScrollBar.new()
	h_scrollbar.visible = true
	grid_container.add_child(h_scrollbar)

	v_scrollbar = VScrollBar.new()
	v_scrollbar.visible = true
	grid_container.add_child(v_scrollbar)

	# Connect to resize
	grid_container.resized.connect(_on_grid_resized)


func _build_inline_editor() -> void:
	inline_editor = LineEdit.new()
	inline_editor.visible = false
	# Prevent container from auto-sizing this control
	inline_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	inline_editor.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	inline_editor.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	inline_editor.text_submitted.connect(_on_inline_edit_submitted)
	inline_editor.focus_exited.connect(_on_inline_edit_focus_lost)
	# Add to grid_container so it overlays the cells
	grid_container.add_child(inline_editor)


func _connect_signals() -> void:
	# Cells canvas signals
	cells_canvas.cell_selected.connect(_on_cell_selected)
	cells_canvas.cell_double_clicked.connect(_on_cell_double_clicked)
	cells_canvas.selection_changed.connect(_on_canvas_selection_changed)
	cells_canvas.scroll_changed.connect(_on_scroll_changed)

	# Column header signals
	column_headers.column_clicked.connect(_on_column_clicked)
	column_headers.column_resize.connect(_on_column_resize)

	# Row header signals
	row_headers.row_clicked.connect(_on_row_clicked)
	row_headers.row_resize.connect(_on_row_resize)

	# Scrollbar signals
	h_scrollbar.value_changed.connect(_on_h_scroll_changed)
	v_scrollbar.value_changed.connect(_on_v_scroll_changed)

	# Data signals
	spreadsheet_data.data_changed.connect(_on_data_changed)


func _on_grid_resized() -> void:
	_update_layout()


func _update_layout() -> void:
	var grid_size := grid_container.size
	var scrollbar_width := 12.0

	# Corner
	corner_panel.position = Vector2.ZERO
	corner_panel.size = Vector2(row_header_width, column_header_height)

	# Column headers
	column_headers.position = Vector2(row_header_width, 0)
	column_headers.size = Vector2(grid_size.x - row_header_width - scrollbar_width, column_header_height)

	# Row headers
	row_headers.position = Vector2(0, column_header_height)
	row_headers.size = Vector2(row_header_width, grid_size.y - column_header_height - scrollbar_width)

	# Cells canvas
	cells_canvas.position = Vector2(row_header_width, column_header_height)
	cells_canvas.size = Vector2(
		grid_size.x - row_header_width - scrollbar_width,
		grid_size.y - column_header_height - scrollbar_width
	)

	# Horizontal scrollbar
	h_scrollbar.position = Vector2(row_header_width, grid_size.y - scrollbar_width)
	h_scrollbar.size = Vector2(grid_size.x - row_header_width - scrollbar_width, scrollbar_width)

	# Vertical scrollbar
	v_scrollbar.position = Vector2(grid_size.x - scrollbar_width, column_header_height)
	v_scrollbar.size = Vector2(scrollbar_width, grid_size.y - column_header_height - scrollbar_width)

	# Update scrollbar ranges
	_update_scrollbar_ranges()


func _update_scrollbar_ranges() -> void:
	var total_width: float = cells_canvas.get_total_width()
	var total_height: float = cells_canvas.get_total_height()

	h_scrollbar.max_value = maxf(0, total_width - cells_canvas.size.x)
	h_scrollbar.page = cells_canvas.size.x

	v_scrollbar.max_value = maxf(0, total_height - cells_canvas.size.y)
	v_scrollbar.page = cells_canvas.size.y


func _on_h_scroll_changed(value: float) -> void:
	cells_canvas.set_scroll(Vector2(value, cells_canvas.scroll_offset.y))
	column_headers.set_scroll_offset(value)


func _on_v_scroll_changed(value: float) -> void:
	cells_canvas.set_scroll(Vector2(cells_canvas.scroll_offset.x, value))
	row_headers.set_scroll_offset(value)


func _on_scroll_changed(offset: Vector2) -> void:
	h_scrollbar.value = offset.x
	v_scrollbar.value = offset.y
	column_headers.set_scroll_offset(offset.x)
	row_headers.set_scroll_offset(offset.y)


func _on_cell_selected(row: int, col: int) -> void:
	current_row = row
	current_col = col
	_update_selection_display()


func _on_cell_double_clicked(row: int, col: int) -> void:
	current_row = row
	current_col = col
	_start_inline_edit()


func _on_canvas_selection_changed(start_row: int, start_col: int, end_row: int, end_col: int) -> void:
	# Update header highlighting
	var selected_cols: Array[int] = []
	for c in range(start_col, end_col + 1):
		selected_cols.append(c)
	column_headers.set_selected_columns(selected_cols)

	var selected_rows: Array[int] = []
	for r in range(start_row, end_row + 1):
		selected_rows.append(r)
	row_headers.set_selected_rows(selected_rows)

	selection_changed.emit(start_row, start_col, end_row, end_col)


func _on_column_clicked(col: int) -> void:
	# Select entire column
	cells_canvas.select_range(0, col, spreadsheet_data.row_count - 1, col)


func _on_row_clicked(row: int) -> void:
	# Select entire row
	cells_canvas.select_range(row, 0, row, spreadsheet_data.column_count - 1)


func _on_column_resize(col: int, new_width: float) -> void:
	spreadsheet_data.set_column_width(col, new_width)
	cells_canvas.queue_redraw()
	column_headers.queue_redraw()
	_update_scrollbar_ranges()


func _on_row_resize(row: int, new_height: float) -> void:
	spreadsheet_data.set_row_height(row, new_height)
	cells_canvas.queue_redraw()
	row_headers.queue_redraw()
	_update_scrollbar_ranges()


func _update_selection_display() -> void:
	# Update cell address label
	var ref := SpreadsheetDataScript.cell_to_reference(current_row, current_col)
	cell_address_label.text = ref

	# Update formula bar
	var cell = spreadsheet_data.get_cell_if_exists(current_row, current_col)
	if cell:
		if cell.has_formula():
			formula_edit.text = cell.formula
		else:
			formula_edit.text = str(cell.value) if not cell.is_empty() else ""
	else:
		formula_edit.text = ""


func _on_formula_submitted(new_text: String) -> void:
	_set_current_cell_value(new_text)
	cells_canvas.grab_focus()


func _on_formula_text_changed(_new_text: String) -> void:
	pass  # Could show live preview


func _start_inline_edit() -> void:
	is_editing = true

	var cell_rect: Rect2 = cells_canvas.get_cell_screen_rect(current_row, current_col)

	# Position inline editor over the cell (relative to grid_container)
	inline_editor.position = cells_canvas.position + cell_rect.position
	inline_editor.custom_minimum_size = cell_rect.size
	inline_editor.size = cell_rect.size

	# Set initial text
	var cell = spreadsheet_data.get_cell_if_exists(current_row, current_col)
	if cell:
		if cell.has_formula():
			inline_editor.text = cell.formula
		else:
			inline_editor.text = str(cell.value) if not cell.is_empty() else ""
	else:
		inline_editor.text = ""

	inline_editor.visible = true
	inline_editor.grab_focus()
	inline_editor.select_all()


func _end_inline_edit(save: bool = true) -> void:
	if not is_editing:
		return

	is_editing = false

	if save:
		_set_current_cell_value(inline_editor.text)

	inline_editor.visible = false
	cells_canvas.grab_focus()


func _on_inline_edit_submitted(new_text: String) -> void:
	_set_current_cell_value(new_text)
	_end_inline_edit(false)

	# Move to next row
	_move_selection(1, 0)


func _on_inline_edit_focus_lost() -> void:
	_end_inline_edit(true)


func _set_current_cell_value(value: String) -> void:
	spreadsheet_data.set_cell_value(current_row, current_col, value)
	_update_selection_display()
	content_changed.emit()


func _on_data_changed() -> void:
	cells_canvas.queue_redraw()
	_update_selection_display()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	if not has_focus() and not cells_canvas.has_focus():
		return

	if event is InputEventKey and event.pressed:
		if _handle_key_input(event):
			get_viewport().set_input_as_handled()


func _handle_key_input(event: InputEventKey) -> bool:
	# Handle keyboard shortcuts
	if event.ctrl_pressed:
		match event.keycode:
			KEY_B:
				_on_bold_pressed()
				return true
			KEY_I:
				_on_italic_pressed()
				return true
			KEY_C:
				_copy_selection()
				return true
			KEY_V:
				_paste_selection()
				return true
			KEY_Z:
				# TODO: Undo
				return true
			KEY_Y:
				# TODO: Redo
				return true

	# Handle navigation
	if is_editing:
		return false

	match event.keycode:
		KEY_UP:
			_move_selection(-1, 0, event.shift_pressed)
			return true
		KEY_DOWN:
			_move_selection(1, 0, event.shift_pressed)
			return true
		KEY_LEFT:
			_move_selection(0, -1, event.shift_pressed)
			return true
		KEY_RIGHT:
			_move_selection(0, 1, event.shift_pressed)
			return true
		KEY_TAB:
			if event.shift_pressed:
				_move_selection(0, -1)
			else:
				_move_selection(0, 1)
			return true
		KEY_ENTER:
			if event.shift_pressed:
				_move_selection(-1, 0)
			else:
				_move_selection(1, 0)
			return true
		KEY_F2:
			_start_inline_edit()
			return true
		KEY_DELETE:
			_delete_selection()
			return true
		KEY_BACKSPACE:
			_delete_selection()
			return true
		KEY_ESCAPE:
			if is_editing:
				_end_inline_edit(false)
				return true
		_:
			# Start editing on any character key
			if event.unicode > 31:
				inline_editor.text = ""
				_start_inline_edit()
				# Let the key through to the editor
				return false

	return false


func _move_selection(row_delta: int, col_delta: int, extend: bool = false) -> void:
	var new_row := clampi(current_row + row_delta, 0, spreadsheet_data.row_count - 1)
	var new_col := clampi(current_col + col_delta, 0, spreadsheet_data.column_count - 1)

	if extend:
		cells_canvas.selection_active = Vector2i(new_col, new_row)
		cells_canvas.queue_redraw()
	else:
		current_row = new_row
		current_col = new_col
		cells_canvas.select_cell(current_row, current_col)

	cells_canvas.scroll_to_cell(new_row, new_col)
	_update_selection_display()


func _delete_selection() -> void:
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size == Vector2i.ZERO:
		spreadsheet_data.clear_cell(current_row, current_col)
	else:
		spreadsheet_data.clear_range(
			sel_rect.position.y, sel_rect.position.x,
			sel_rect.end.y - 1, sel_rect.end.x - 1
		)
	content_changed.emit()


func _copy_selection() -> void:
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size == Vector2i.ZERO:
		sel_rect = Rect2i(current_col, current_row, 1, 1)

	var lines := PackedStringArray()
	for row in range(sel_rect.position.y, sel_rect.end.y):
		var values := PackedStringArray()
		for col in range(sel_rect.position.x, sel_rect.end.x):
			values.append(spreadsheet_data.get_cell_display(row, col))
		lines.append("\t".join(values))

	DisplayServer.clipboard_set("\n".join(lines))


func _paste_selection() -> void:
	var text := DisplayServer.clipboard_get()
	if text.is_empty():
		return

	var lines := text.split("\n")
	var start_row := current_row
	var start_col := current_col

	for row_offset in range(lines.size()):
		var line := lines[row_offset]
		var values := line.split("\t")

		for col_offset in range(values.size()):
			var value := values[col_offset]
			spreadsheet_data.set_cell_value(
				start_row + row_offset,
				start_col + col_offset,
				value
			)

	content_changed.emit()


## Toolbar actions

func _on_bold_pressed() -> void:
	_apply_format_to_selection({"bold": true})


func _on_italic_pressed() -> void:
	_apply_format_to_selection({"italic": true})


func _on_align_left_pressed() -> void:
	_apply_format_to_selection({"alignment": HORIZONTAL_ALIGNMENT_LEFT})


func _on_align_center_pressed() -> void:
	_apply_format_to_selection({"alignment": HORIZONTAL_ALIGNMENT_CENTER})


func _on_align_right_pressed() -> void:
	_apply_format_to_selection({"alignment": HORIZONTAL_ALIGNMENT_RIGHT})


func _on_header_row_pressed() -> void:
	# Toggle header status for selected rows
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size == Vector2i.ZERO:
		sel_rect = Rect2i(0, current_row, spreadsheet_data.column_count, 1)

	for row in range(sel_rect.position.y, sel_rect.end.y):
		if row < spreadsheet_data.row_meta.size():
			var meta = spreadsheet_data.row_meta[row]
			meta.is_header = not meta.is_header

			# Apply header formatting
			for col in range(spreadsheet_data.column_count):
				var cell = spreadsheet_data.get_cell(row, col)
				cell.bold = meta.is_header
				cell.alignment = HORIZONTAL_ALIGNMENT_CENTER if meta.is_header else HORIZONTAL_ALIGNMENT_LEFT

	cells_canvas.queue_redraw()
	content_changed.emit()


func _apply_format_to_selection(format: Dictionary) -> void:
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size == Vector2i.ZERO:
		sel_rect = Rect2i(current_col, current_row, 1, 1)

	for row in range(sel_rect.position.y, sel_rect.end.y):
		for col in range(sel_rect.position.x, sel_rect.end.x):
			var cell = spreadsheet_data.get_cell(row, col)

			if format.has("bold"):
				cell.bold = not cell.bold if format["bold"] == true else format["bold"]
			if format.has("italic"):
				cell.italic = not cell.italic if format["italic"] == true else format["italic"]
			if format.has("alignment"):
				cell.alignment = format["alignment"]
			if format.has("text_color"):
				cell.text_color = format["text_color"]
			if format.has("bg_color"):
				cell.bg_color = format["bg_color"]

	cells_canvas.queue_redraw()
	content_changed.emit()


## Public API

func setup() -> void:
	# Called when editor is first created
	_update_layout()


func get_content() -> String:
	return spreadsheet_data.to_csv()


func set_content(csv_text: String) -> void:
	# Parse CSV and populate data
	var lines := csv_text.split("\n")
	for row in range(lines.size()):
		var values := lines[row].split(",")
		for col in range(values.size()):
			spreadsheet_data.set_cell_value(row, col, values[col])


func serialize() -> Dictionary:
	return spreadsheet_data.to_dict()


func deserialize(data: Dictionary) -> void:
	spreadsheet_data = SpreadsheetDataScript.new()
	spreadsheet_data.load_from_dict(data)
	cells_canvas.set_data(spreadsheet_data)
	column_headers.set_data(spreadsheet_data)
	row_headers.set_data(spreadsheet_data)
	spreadsheet_data.data_changed.connect(_on_data_changed)
	_update_layout()
