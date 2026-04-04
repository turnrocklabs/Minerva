class_name SpreadsheetEditor
extends PanelContainer
## Main spreadsheet editor control combining grid, headers, and editing functionality.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")
const SpreadsheetCellsCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/CellsCanvas.gd")
const SpreadsheetColumnHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ColumnHeaders.gd")
const SpreadsheetRowHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/RowHeaders.gd")
const SpreadsheetHistoryScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetHistory.gd")
const SpreadsheetFileHandlerScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")
const ChartRendererScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ChartRenderer.gd")
const ChartCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ChartCanvas.gd")
const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")

signal content_changed()
signal selection_changed(start_row: int, start_col: int, end_row: int, end_col: int)

## Spreadsheet data
var spreadsheet_data  # SpreadsheetData

## Undo/redo history
var history  # SpreadsheetHistory

## UI Components
var main_container: VBoxContainer
var toolbar: HFlowContainer
var formula_bar: HBoxContainer
var cell_address_label: Label
var formula_edit: LineEdit
var split_container: VSplitContainer
var grid_container: Control
var corner_panel: Panel
var column_headers  # SpreadsheetColumnHeaders
var row_headers  # SpreadsheetRowHeaders
var cells_canvas  # SpreadsheetCellsCanvas
var h_scrollbar: HScrollBar
var v_scrollbar: VScrollBar
var inline_editor: LineEdit
var import_dialog: FileDialog
var export_dialog: FileDialog

## Chart components
var chart_panel: PanelContainer
var chart_header: HBoxContainer
var chart_toggle_btn: Button
var chart_container: VBoxContainer
var chart_canvases: Array = []  # Array of ChartCanvas
var charts: Array = []  # Array of SpreadsheetChart
var chart_config_dialog: Window

## Context menu
var context_menu: PopupMenu
var _context_source: String = ""  # "cell", "row", "column"
var _context_row: int = -1
var _context_col: int = -1

## Current selection
var current_row: int = 0
var current_col: int = 0

## Editing state
var is_editing: bool = false

## Resize tracking for history
var _resize_col_start_width: float = 0.0
var _resize_row_start_height: float = 0.0
var _resize_col: int = -1
var _resize_row: int = -1

## Header sizes
var row_header_width: float = 50.0
var column_header_height: float = 24.0

# Toolbar format buttons (for state reflection)
var _bold_btn: Button
var _italic_btn: Button


func _ready() -> void:
	print("[SpreadsheetEditor] _ready() called, spreadsheet_data=%s" % spreadsheet_data)
	# Only initialize data if not already loaded by deserialize()
	if spreadsheet_data == null:
		spreadsheet_data = SpreadsheetDataScript.new()

	# Set up cross-sheet reference resolver
	_setup_sheet_resolver()

	# Only initialize history if not already done by deserialize()
	if history == null:
		history = SpreadsheetHistoryScript.new()

	# Only build UI if not already done by deserialize()
	if cells_canvas == null:
		_build_ui()
		_connect_signals()
	else:
		# UI was built in deserialize, just need to update layout now that we have size
		_update_layout()
		cells_canvas.queue_redraw()
		column_headers.queue_redraw()
		row_headers.queue_redraw()

	# Initial selection
	_update_selection_display()


## Set up the sheet resolver for cross-sheet formula references
func _setup_sheet_resolver() -> void:
	if spreadsheet_data and spreadsheet_data._formula_engine:
		spreadsheet_data._formula_engine.set_sheet_resolver(_resolve_sheet)


## Schedule a deferred recalculation to allow other sheets to load first
## This is needed for cross-sheet references to work after project load
func _schedule_deferred_recalculation() -> void:
	# If not in tree yet, wait until we are
	if not is_inside_tree():
		# Connect to tree_entered to schedule once we're in the tree
		if not tree_entered.is_connected(_schedule_deferred_recalculation):
			tree_entered.connect(_schedule_deferred_recalculation, CONNECT_ONE_SHOT)
		return

	# Use a short timer to allow all editors to finish loading
	var timer := get_tree().create_timer(0.5)  # 500ms delay
	timer.timeout.connect(_on_deferred_recalculation)


func _on_deferred_recalculation() -> void:
	if spreadsheet_data:
		print("[SpreadsheetEditor] Running deferred recalculation")
		spreadsheet_data.recalculate_all()
		cells_canvas.queue_redraw()


## Manually recalculate all formulas (called by Recalc button or F9)
func _recalculate_all() -> void:
	if spreadsheet_data:
		spreadsheet_data.recalculate_all()
		cells_canvas.queue_redraw()
		_update_selection_display()


## Resolve a sheet name to its SpreadsheetData for cross-sheet references
func _resolve_sheet(sheet_name: String) -> RefCounted:
	if not SingletonObject.editor_container:
		return null

	var editor_pane = SingletonObject.editor_container.editor_pane
	if not editor_pane:
		return null

	# Load the Editor script to check type
	#var EditorScript = load("res://Scripts/UI/Controls/Editor.gd")

	# Search through open editors for a matching spreadsheet
	for editor in editor_pane.get_open_editors():
		if editor.tab_title == sheet_name and editor.type == Editor.Type.SPREADSHEET:
			if editor.spreadsheet_editor and editor.spreadsheet_editor.spreadsheet_data:
				return editor.spreadsheet_editor.spreadsheet_data

	return null


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

	# Split container for grid and chart panel
	split_container = VSplitContainer.new()
	split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_container.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
	main_container.add_child(split_container)

	# Grid area (in split container)
	_build_grid_area()

	# Inline editor (hidden initially)
	_build_inline_editor()

	# Chart panel (in split container, resizable)
	_build_chart_panel()


func _build_toolbar() -> void:
	toolbar = HFlowContainer.new()
	toolbar.add_theme_constant_override("separation", 4)
	main_container.add_child(toolbar)

	# Bold button
	_bold_btn = Button.new()
	_bold_btn.icon = preload("uid://cfu0tc5nslwku")
	_bold_btn.tooltip_text = "Bold (Ctrl+B)"
	_bold_btn.custom_minimum_size = Vector2(30, 28)
	_bold_btn.toggle_mode = true
	_bold_btn.pressed.connect(_on_bold_pressed)
	toolbar.add_child(_bold_btn)

	# Italic button
	_italic_btn = Button.new()
	_italic_btn.icon = preload("uid://c2x042or4icqh")
	_italic_btn.tooltip_text = "Italic (Ctrl+I)"
	_italic_btn.custom_minimum_size = Vector2(30, 28)
	_italic_btn.toggle_mode = true
	_italic_btn.pressed.connect(_on_italic_pressed)
	toolbar.add_child(_italic_btn)

	# Separator
	var sep1 := VSeparator.new()
	toolbar.add_child(sep1)

	# Alignment buttons
	var align_left := Button.new()
	align_left.icon = preload("uid://8pfda6vkqgcu")
	align_left.tooltip_text = "Align Left"
	align_left.custom_minimum_size = Vector2(30, 28)
	align_left.pressed.connect(_on_align_left_pressed)
	toolbar.add_child(align_left)

	var align_center := Button.new()
	align_center.icon = preload("uid://by4euhg5vcb2u")
	align_center.tooltip_text = "Align Center"
	align_center.custom_minimum_size = Vector2(30, 28)
	align_center.pressed.connect(_on_align_center_pressed)
	toolbar.add_child(align_center)

	var align_right := Button.new()
	align_right.icon = preload("uid://cn3cyqlwp73k3")
	align_right.tooltip_text = "Align Right"
	align_right.custom_minimum_size = Vector2(30, 28)
	align_right.pressed.connect(_on_align_right_pressed)
	toolbar.add_child(align_right)

	# Separator
	var sep2 := VSeparator.new()
	toolbar.add_child(sep2)

	# Header row button
	var header_btn := Button.new()
	header_btn.icon = preload("uid://cgsv4ad8o0ond")
	header_btn.tooltip_text = "Toggle Header Row"
	header_btn.pressed.connect(_on_header_row_pressed)
	toolbar.add_child(header_btn)

	# Separator
	var sep3 := VSeparator.new()
	toolbar.add_child(sep3)

	# Freeze pane button with dropdown
	var freeze_btn := MenuButton.new()
	freeze_btn.icon = preload("uid://bq6kasw1po25h")
	freeze_btn.tooltip_text = "Freeze Rows/Columns"
	var freeze_popup := freeze_btn.get_popup()
	freeze_popup.add_item("No Freeze", 0)
	freeze_popup.add_item("Freeze Top Row", 1)
	freeze_popup.add_item("Freeze First Column", 2)
	freeze_popup.add_item("Freeze Top Row & First Column", 3)
	freeze_popup.add_separator()
	freeze_popup.add_item("Freeze Above Current Row", 4)
	freeze_popup.add_item("Freeze Left of Current Column", 5)
	freeze_popup.id_pressed.connect(_on_freeze_option_selected)
	toolbar.add_child(freeze_btn)

	# Separator
	var sep4 := VSeparator.new()
	toolbar.add_child(sep4)

	# Import button
	var import_btn := Button.new()
	import_btn.icon = preload("uid://ccei0hhyfti1b")
	import_btn.tooltip_text = "Import from CSV/TSV/Excel"
	import_btn.pressed.connect(_on_import_pressed)
	toolbar.add_child(import_btn)

	# Export button
	var export_btn := Button.new()
	export_btn.icon = preload("uid://c4xecwxribs4s")
	export_btn.tooltip_text = "Export to CSV/TSV/Excel"
	export_btn.pressed.connect(_on_export_pressed)
	toolbar.add_child(export_btn)

	# Separator
	var sep5 := VSeparator.new()
	toolbar.add_child(sep5)

	# Fill Down button
	var fill_down_btn := Button.new()
	fill_down_btn.icon = preload("uid://gy2ltu20y33")
	fill_down_btn.tooltip_text = "Fill Down (Ctrl+D) - Copy top row formulas to selected rows"
	fill_down_btn.pressed.connect(_fill_down)
	toolbar.add_child(fill_down_btn)

	# Recalculate button
	var recalc_btn := Button.new()
	recalc_btn.icon = preload("uid://bdmixrtkjm1dv")
	recalc_btn.tooltip_text = "Recalculate all formulas (F9)"
	recalc_btn.pressed.connect(_recalculate_all)
	toolbar.add_child(recalc_btn)

	# Separator
	var sep6 := VSeparator.new()
	toolbar.add_child(sep6)

	# Chart button
	var chart_btn := Button.new()
	chart_btn.icon = preload("uid://b62g6uuuv3ad1")
	chart_btn.tooltip_text = "Create Chart from Selection"
	chart_btn.pressed.connect(_on_chart_pressed)
	toolbar.add_child(chart_btn)

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
	split_container.add_child(grid_container)

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
	inline_editor.gui_input.connect(_on_inline_editor_gui_input)
	# Add to grid_container so it overlays the cells
	grid_container.add_child(inline_editor)


func _build_chart_panel() -> void:
	# Chart panel (resizable via split container)
	chart_panel = PanelContainer.new()
	chart_panel.visible = false
	chart_panel.custom_minimum_size.y = 100
	chart_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_container.add_child(chart_panel)

	var panel_vbox := VBoxContainer.new()
	chart_panel.add_child(panel_vbox)

	# Header with collapse button
	chart_header = HBoxContainer.new()
	panel_vbox.add_child(chart_header)

	chart_toggle_btn = Button.new()
	chart_toggle_btn.text = "Charts"
	chart_toggle_btn.toggle_mode = true
	chart_toggle_btn.button_pressed = true
	chart_toggle_btn.toggled.connect(_on_chart_toggle)
	chart_header.add_child(chart_toggle_btn)

	var add_chart_btn := Button.new()
	add_chart_btn.text = "+"
	add_chart_btn.tooltip_text = "Add Chart"
	add_chart_btn.pressed.connect(_on_add_chart_pressed)
	chart_header.add_child(add_chart_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart_header.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.tooltip_text = "Close Charts Panel"
	close_btn.pressed.connect(_on_close_chart_panel)
	chart_header.add_child(close_btn)

	# Chart container (scrollable)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel_vbox.add_child(scroll)

	chart_container = VBoxContainer.new()
	chart_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(chart_container)


func _connect_signals() -> void:
	# Cells canvas signals
	cells_canvas.cell_selected.connect(_on_cell_selected)
	cells_canvas.cell_double_clicked.connect(_on_cell_double_clicked)
	cells_canvas.selection_changed.connect(_on_canvas_selection_changed)
	cells_canvas.scroll_changed.connect(_on_scroll_changed)
	cells_canvas.navigation_requested.connect(_on_canvas_navigation)
	cells_canvas.edit_requested.connect(_on_canvas_edit_requested)
	cells_canvas.context_menu_requested.connect(_on_cell_context_menu)

	# Column header signals
	column_headers.column_clicked.connect(_on_column_clicked)
	column_headers.column_resize_started.connect(_on_column_resize_started)
	column_headers.column_resize.connect(_on_column_resize)
	column_headers.column_resize_ended.connect(_on_column_resize_ended)
	column_headers.column_autofit_requested.connect(_on_column_autofit)
	column_headers.column_context_menu_requested.connect(_on_column_context_menu)

	# Row header signals
	row_headers.row_clicked.connect(_on_row_clicked)
	row_headers.row_resize_started.connect(_on_row_resize_started)
	row_headers.row_resize.connect(_on_row_resize)
	row_headers.row_resize_ended.connect(_on_row_resize_ended)
	row_headers.row_context_menu_requested.connect(_on_row_context_menu)

	# Scrollbar signals
	h_scrollbar.value_changed.connect(_on_h_scroll_changed)
	v_scrollbar.value_changed.connect(_on_v_scroll_changed)

	# Data signals (only if spreadsheet_data exists - may be connected later in deserialize)
	if spreadsheet_data:
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
	_update_format_buttons()


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


func _on_canvas_navigation(direction: String) -> void:
	# Handle navigation commands from CellsCanvas
	if is_editing:
		return

	match direction:
		"up":
			_move_selection(-1, 0)
		"down":
			_move_selection(1, 0)
		"left":
			_move_selection(0, -1)
		"right":
			_move_selection(0, 1)
		"delete":
			_delete_selection()
		"escape":
			cells_canvas.clear_selection()
		"home_row":
			_move_to_cell(current_row, 0)
		"home_doc":
			_move_to_cell(0, 0)
		"end_row":
			_move_to_cell(current_row, spreadsheet_data.column_count - 1)
		"end_doc":
			_move_to_cell(spreadsheet_data.row_count - 1, spreadsheet_data.column_count - 1)


func _on_canvas_edit_requested() -> void:
	if not is_editing:
		_start_inline_edit()


func _move_to_cell(row: int, col: int) -> void:
	current_row = clampi(row, 0, spreadsheet_data.row_count - 1)
	current_col = clampi(col, 0, spreadsheet_data.column_count - 1)
	cells_canvas.select_cell(current_row, current_col)
	cells_canvas.scroll_to_cell(current_row, current_col)
	_update_selection_display()


func _on_column_clicked(col: int) -> void:
	# Select entire column
	cells_canvas.select_range(0, col, spreadsheet_data.row_count - 1, col)


func _on_row_clicked(row: int) -> void:
	# Select entire row
	cells_canvas.select_range(row, 0, row, spreadsheet_data.column_count - 1)


func _on_column_resize_started(col: int) -> void:
	_resize_col = col
	_resize_col_start_width = spreadsheet_data.get_column_width(col)


func _on_column_resize(col: int, new_width: float) -> void:
	spreadsheet_data.set_column_width(col, new_width)
	cells_canvas.queue_redraw()
	column_headers.queue_redraw()
	_update_scrollbar_ranges()


func _on_column_resize_ended(col: int) -> void:
	if _resize_col >= 0:
		var new_width: float = spreadsheet_data.get_column_width(col)
		if new_width != _resize_col_start_width:
			history.record_column_resize(_resize_col, _resize_col_start_width, new_width)
	_resize_col = -1


func _on_column_autofit(col: int) -> void:
	var old_width: float = spreadsheet_data.get_column_width(col)
	var new_width := _calculate_column_fit_width(col)

	if new_width != old_width:
		spreadsheet_data.set_column_width(col, new_width)
		history.record_column_resize(col, old_width, new_width)
		cells_canvas.queue_redraw()
		column_headers.queue_redraw()
		_update_scrollbar_ranges()
		content_changed.emit()


func _calculate_column_fit_width(col: int) -> float:
	var cell_font: Font = cells_canvas.font
	var cell_font_size: int = cells_canvas.font_size
	var padding: float = cells_canvas.cell_padding * 2.0
	var min_width: float = 40.0  # Minimum column width
	var max_width: float = SpreadsheetDataScript.MAX_COLUMN_WIDTH

	# Start with header label width
	var header_label: String = SpreadsheetDataScript.get_column_label(col)
	if col < spreadsheet_data.column_meta.size() and not spreadsheet_data.column_meta[col].header_name.is_empty():
		header_label = spreadsheet_data.column_meta[col].header_name
	var widest: float = cell_font.get_string_size(header_label, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_font_size).x + padding

	# Check all rows for the widest content
	for row in range(spreadsheet_data.row_count):
		var cell = spreadsheet_data.get_cell_if_exists(row, col)
		if cell and not cell.is_empty():
			var display_text: String = cell.get_display_text()
			var text_width: float = cell_font.get_string_size(display_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_font_size).x + padding
			widest = maxf(widest, text_width)

	return clampf(widest, min_width, max_width)


func _on_row_resize_started(row: int) -> void:
	_resize_row = row
	_resize_row_start_height = spreadsheet_data.get_row_height(row)


func _on_row_resize(row: int, new_height: float) -> void:
	spreadsheet_data.set_row_height(row, new_height)
	cells_canvas.queue_redraw()
	row_headers.queue_redraw()
	_update_scrollbar_ranges()


func _on_row_resize_ended(row: int) -> void:
	if _resize_row >= 0:
		var new_height: float = spreadsheet_data.get_row_height(row)
		if new_height != _resize_row_start_height:
			history.record_row_resize(_resize_row, _resize_row_start_height, new_height)
	_resize_row = -1


## Context menu handlers

func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(context_menu)


func _show_context_menu(screen_pos: Vector2) -> void:
	if not context_menu:
		_create_context_menu()

	context_menu.clear()

	# Check if any cell in the selection has wrap_text enabled
	var has_wrap := false
	var all_rects: Array[Rect2i] = cells_canvas.get_all_selection_rects()
	if all_rects.is_empty():
		all_rects = [Rect2i(current_col, current_row, 1, 1)]
	for sel_rect in all_rects:
		for row in range(sel_rect.position.y, sel_rect.end.y):
			for col in range(sel_rect.position.x, sel_rect.end.x):
				var cell = spreadsheet_data.get_cell_if_exists(row, col)
				if cell and cell.wrap_text:
					has_wrap = true
					break
			if has_wrap:
				break
		if has_wrap:
			break

	context_menu.add_check_item("Wrap Text", 0)
	context_menu.set_item_checked(0, has_wrap)

	if _context_source == "cell" or _context_source == "row":
		context_menu.add_separator()
		context_menu.add_item("Auto-Fit Row Height", 1)

	context_menu.position = Vector2i(int(screen_pos.x), int(screen_pos.y))
	context_menu.popup()


func _on_cell_context_menu(row: int, col: int, screen_pos: Vector2) -> void:
	_context_source = "cell"
	_context_row = row
	_context_col = col
	current_row = row
	current_col = col
	_update_selection_display()
	_show_context_menu(screen_pos)


func _on_row_context_menu(row: int, screen_pos: Vector2) -> void:
	_context_source = "row"
	_context_row = row
	_context_col = -1
	# Select entire row
	cells_canvas.select_range(row, 0, row, spreadsheet_data.column_count - 1)
	_show_context_menu(screen_pos)


func _on_column_context_menu(col: int, screen_pos: Vector2) -> void:
	_context_source = "column"
	_context_row = -1
	_context_col = col
	# Select entire column
	cells_canvas.select_range(0, col, spreadsheet_data.row_count - 1, col)
	_show_context_menu(screen_pos)


func _on_context_menu_id_pressed(id: int) -> void:
	match id:
		0:  # Wrap Text toggle
			_apply_format_to_selection({"wrap_text": "toggle"})
		1:  # Auto-Fit Row Height
			_auto_fit_selected_row_heights()


func _auto_fit_selected_row_heights() -> void:
	var all_rects: Array[Rect2i] = cells_canvas.get_all_selection_rects()
	if all_rects.is_empty():
		all_rects = [Rect2i(current_col, current_row, 1, 1)]

	var rows_done: Dictionary = {}
	for sel_rect in all_rects:
		for row in range(sel_rect.position.y, sel_rect.end.y):
			if rows_done.has(row):
				continue
			rows_done[row] = true
			_auto_fit_row_height(row)


func _auto_fit_row_height(row: int) -> void:
	var cell_font: Font = cells_canvas.font
	var cell_font_size: int = cells_canvas.font_size
	var padding: float = cells_canvas.cell_padding * 2.0
	var line_height: float = cell_font.get_height(cell_font_size)
	var old_height: float = spreadsheet_data.get_row_height(row)
	var needed_height: float = SpreadsheetDataScript.DEFAULT_ROW_HEIGHT

	for col in range(spreadsheet_data.column_count):
		var cell = spreadsheet_data.get_cell_if_exists(row, col)
		if not cell or cell.is_empty():
			continue
		if cell.wrap_text:
			var col_width: float = spreadsheet_data.get_column_width(col) - padding
			var text_size: Vector2 = cell_font.get_multiline_string_size(
				cell.get_display_text(), HORIZONTAL_ALIGNMENT_LEFT, col_width, cell_font_size
			)
			needed_height = maxf(needed_height, text_size.y + padding)
		else:
			needed_height = maxf(needed_height, line_height + padding)

	needed_height = clampf(needed_height, SpreadsheetDataScript.MIN_ROW_HEIGHT, SpreadsheetDataScript.MAX_ROW_HEIGHT)

	if needed_height != old_height:
		spreadsheet_data.set_row_height(row, needed_height)
		history.record_row_resize(row, old_height, needed_height)
		cells_canvas.queue_redraw()
		row_headers.queue_redraw()
		_update_scrollbar_ranges()
		content_changed.emit()


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


func _on_inline_editor_gui_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed:
		return

	var key := key_event.keycode

	# Handle Tab in inline editor - commit and move to next cell
	if key == KEY_TAB:
		get_viewport().set_input_as_handled()
		_set_current_cell_value(inline_editor.text)
		_end_inline_edit(false)
		if key_event.shift_pressed:
			_move_selection(0, -1)
		else:
			_move_selection(0, 1)

	# Handle Escape - cancel edit
	elif key == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_end_inline_edit(false)


func _set_current_cell_value(value: String, record_history: bool = true) -> void:
	# Get old value for history
	var old_value: Variant = ""
	var old_formula: String = ""
	var cell = spreadsheet_data.get_cell_if_exists(current_row, current_col)
	if cell:
		old_value = cell.value
		old_formula = cell.formula

	# Set new value
	spreadsheet_data.set_cell_value(current_row, current_col, value)

	# Record in history
	if record_history:
		var new_cell = spreadsheet_data.get_cell_if_exists(current_row, current_col)
		var new_formula: String = new_cell.formula if new_cell else ""
		history.record_cell_edit(current_row, current_col, old_value, value, old_formula, new_formula)

	_update_selection_display()
	content_changed.emit()


func _on_data_changed() -> void:
	cells_canvas.queue_redraw()
	_update_selection_display()
	_update_all_charts()


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
				_perform_undo()
				return true
			KEY_Y:
				_perform_redo()
				return true
			KEY_D:
				_fill_down()
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
		KEY_F9:
			_recalculate_all()
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
	var all_rects: Array[Rect2i] = cells_canvas.get_all_selection_rects()
	if all_rects.is_empty():
		all_rects = [Rect2i(current_col, current_row, 1, 1)]

	# Process each selection rect
	for sel_rect in all_rects:
		# Capture old cells for history
		var old_cells: Dictionary = {}
		for row in range(sel_rect.position.y, sel_rect.end.y):
			for col in range(sel_rect.position.x, sel_rect.end.x):
				var cell = spreadsheet_data.get_cell_if_exists(row, col)
				if cell and not cell.is_empty():
					var key := SpreadsheetDataScript.cell_key(row, col)
					old_cells[key] = cell.to_dict()

		# Clear the range
		spreadsheet_data.clear_range(
			sel_rect.position.y, sel_rect.position.x,
			sel_rect.end.y - 1, sel_rect.end.x - 1
		)

		# Record in history
		if not old_cells.is_empty():
			history.record_range_clear(
				sel_rect.position.y, sel_rect.position.x,
				sel_rect.end.y - 1, sel_rect.end.x - 1,
				old_cells
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


## Fill Down - copy formulas/values from top row of selection to rows below
## Adjusts relative cell references (row numbers) automatically
func _fill_down() -> void:
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size == Vector2i.ZERO:
		return  # Nothing selected

	# Need at least 2 rows to fill down
	if sel_rect.size.y < 2:
		return

	var source_row: int = sel_rect.position.y
	var start_col: int = sel_rect.position.x
	var end_col: int = sel_rect.end.x

	# Capture old cells for history
	var old_cells: Dictionary = {}
	var new_cells: Dictionary = {}

	# For each column in the selection
	for col in range(start_col, end_col):
		# Get the source cell (top row of selection)
		var source_cell = spreadsheet_data.get_cell_if_exists(source_row, col)
		var source_formula: String = ""
		var source_value: Variant = ""

		if source_cell:
			source_formula = source_cell.formula
			source_value = source_cell.value

		# Fill down to each row below the source
		for target_row in range(source_row + 1, sel_rect.end.y):
			var row_offset: int = target_row - source_row
			var key := SpreadsheetDataScript.cell_key(target_row, col)

			# Capture old value
			var old_cell = spreadsheet_data.get_cell_if_exists(target_row, col)
			if old_cell:
				old_cells[key] = old_cell.to_dict()
			else:
				old_cells[key] = {}

			# Determine what to set
			if not source_formula.is_empty():
				# Adjust the formula's row references
				var adjusted_formula: String = _adjust_formula_row_refs(source_formula, row_offset)
				spreadsheet_data.set_cell_value(target_row, col, adjusted_formula)
			else:
				# Just copy the value (no adjustment needed)
				spreadsheet_data.set_cell_value(target_row, col, source_value)

			# Capture new value
			var new_cell = spreadsheet_data.get_cell_if_exists(target_row, col)
			if new_cell:
				new_cells[key] = new_cell.to_dict()

	# Record in history
	if not new_cells.is_empty():
		history.record_range_edit(source_row + 1, start_col, old_cells, new_cells)

	content_changed.emit()


## Adjust row references in a formula by a given offset
## Respects absolute references ($) - those are not adjusted
func _adjust_formula_row_refs(formula: String, row_offset: int) -> String:
	# Regex to match cell references including optional sheet prefix and $ markers
	# Pattern: (optional 'SheetName'! or SheetName!) followed by ($?)([A-Z]+)($?)([0-9]+)
	var regex := RegEx.new()
	# Match: optional sheet prefix, then column (with optional $), then row number (with optional $)
	regex.compile("((?:'[^']+?'!|[A-Za-z_][A-Za-z0-9_]*!)?)(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")

	var result := formula
	var matches := regex.search_all(formula)

	# Process matches in reverse order to preserve positions
	for i in range(matches.size() - 1, -1, -1):
		var m := matches[i]
		var sheet_prefix: String = m.get_string(1)  # 'Sheet1'! or Sheet1! or empty
		var col_abs: String = m.get_string(2)       # $ or empty
		var col_letters: String = m.get_string(3)   # A, B, AA, etc.
		var row_abs: String = m.get_string(4)       # $ or empty
		var row_num_str: String = m.get_string(5)   # 1, 2, 100, etc.

		# If row is absolute ($), don't adjust
		if row_abs == "$":
			continue

		# Adjust the row number
		var row_num: int = row_num_str.to_int()
		var new_row_num: int = row_num + row_offset

		# Don't allow negative or zero row numbers
		if new_row_num < 1:
			new_row_num = 1

		# Rebuild the reference
		var new_ref := sheet_prefix + col_abs + col_letters + row_abs + str(new_row_num)

		# Replace in result
		result = result.substr(0, m.get_start()) + new_ref + result.substr(m.get_end())

	return result


func _paste_selection() -> void:
	var text := DisplayServer.clipboard_get()
	if text.is_empty():
		return

	var lines := text.split("\n")
	var start_row := current_row
	var start_col := current_col

	# Capture old cells for history
	var old_cells: Dictionary = {}
	var new_cells: Dictionary = {}

	for row_offset in range(lines.size()):
		var line := lines[row_offset]
		var values := line.split("\t")

		for col_offset in range(values.size()):
			var row := start_row + row_offset
			var col := start_col + col_offset
			var value := values[col_offset]

			# Capture old value
			var key := SpreadsheetDataScript.cell_key(row, col)
			var old_cell = spreadsheet_data.get_cell_if_exists(row, col)
			if old_cell:
				old_cells[key] = old_cell.to_dict()
			else:
				old_cells[key] = {}  # Empty cell

			# Set new value
			spreadsheet_data.set_cell_value(row, col, value)

			# Capture new value
			var new_cell = spreadsheet_data.get_cell_if_exists(row, col)
			if new_cell:
				new_cells[key] = new_cell.to_dict()

	# Record in history
	if not new_cells.is_empty():
		history.record_range_edit(start_row, start_col, old_cells, new_cells)

	content_changed.emit()


## Toolbar actions

func _on_bold_pressed() -> void:
	_apply_format_to_selection({"bold": true})
	_update_format_buttons()


func _on_italic_pressed() -> void:
	_apply_format_to_selection({"italic": true})
	_update_format_buttons()


func _update_format_buttons() -> void:
	var cell = spreadsheet_data.get_cell_if_exists(current_row, current_col)
	var is_bold: bool = cell.bold if cell else false
	var is_italic: bool = cell.italic if cell else false
	_bold_btn.set_pressed_no_signal(is_bold)
	_italic_btn.set_pressed_no_signal(is_italic)


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


func _on_freeze_option_selected(id: int) -> void:
	match id:
		0:  # No Freeze
			spreadsheet_data.frozen_rows = 0
			spreadsheet_data.frozen_cols = 0
		1:  # Freeze Top Row
			spreadsheet_data.frozen_rows = 1
			spreadsheet_data.frozen_cols = 0
		2:  # Freeze First Column
			spreadsheet_data.frozen_rows = 0
			spreadsheet_data.frozen_cols = 1
		3:  # Freeze Top Row & First Column
			spreadsheet_data.frozen_rows = 1
			spreadsheet_data.frozen_cols = 1
		4:  # Freeze Above Current Row
			spreadsheet_data.frozen_rows = current_row
			# Don't change frozen_cols
		5:  # Freeze Left of Current Column
			spreadsheet_data.frozen_cols = current_col
			# Don't change frozen_rows

	cells_canvas.queue_redraw()
	column_headers.queue_redraw()
	row_headers.queue_redraw()
	content_changed.emit()


func _apply_format_to_selection(format: Dictionary) -> void:
	var all_rects: Array[Rect2i] = cells_canvas.get_all_selection_rects()
	if all_rects.is_empty():
		all_rects = [Rect2i(current_col, current_row, 1, 1)]

	# Collect format changes for history
	var format_changes: Array = []

	for sel_rect in all_rects:
		for row in range(sel_rect.position.y, sel_rect.end.y):
			for col in range(sel_rect.position.x, sel_rect.end.x):
				var cell = spreadsheet_data.get_cell(row, col)

				# Capture old format
				var old_format: Dictionary = {
					"bold": cell.bold,
					"italic": cell.italic,
					"alignment": cell.alignment,
					"text_color": cell.text_color,
					"bg_color": cell.bg_color,
					"wrap_text": cell.wrap_text,
				}

				# Apply format changes
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
				if format.has("wrap_text"):
					if format["wrap_text"] == "toggle":
						cell.wrap_text = not cell.wrap_text
					else:
						cell.wrap_text = format["wrap_text"]

				# Capture new format
				var new_format: Dictionary = {
					"bold": cell.bold,
					"italic": cell.italic,
					"alignment": cell.alignment,
					"text_color": cell.text_color,
					"bg_color": cell.bg_color,
					"wrap_text": cell.wrap_text,
				}

				# Only record if format actually changed
				if old_format != new_format:
					format_changes.append({
						"row": row,
						"col": col,
						"old_format": old_format,
						"new_format": new_format,
					})

	# Record in history
	if not format_changes.is_empty():
		history.record_range_format(format_changes)

	cells_canvas.queue_redraw()
	content_changed.emit()


## Undo/Redo

func _perform_undo() -> void:
	if not history.can_undo():
		return

	var action = history.undo()
	if not action:
		return

	_apply_history_action(action, true)


func _perform_redo() -> void:
	if not history.can_redo():
		return

	var action = history.redo()
	if not action:
		return

	_apply_history_action(action, false)


func _apply_history_action(action, is_undo: bool) -> void:
	match action.type:
		SpreadsheetHistoryScript.ActionType.CELL_EDIT:
			var row: int = action.data["row"]
			var col: int = action.data["col"]
			var value = action.data["old_value"] if is_undo else action.data["new_value"]

			# Temporarily store current position
			var prev_row := current_row
			var prev_col := current_col

			# Move to the cell and set value without recording history
			current_row = row
			current_col = col
			_set_current_cell_value(str(value), false)

			# Restore position
			current_row = prev_row
			current_col = prev_col

		SpreadsheetHistoryScript.ActionType.CELL_FORMAT:
			var row: int = action.data["row"]
			var col: int = action.data["col"]
			var format_data: Dictionary = action.data["old_format"] if is_undo else action.data["new_format"]

			var cell = spreadsheet_data.get_cell(row, col)
			if format_data.has("bold"):
				cell.bold = format_data["bold"]
			if format_data.has("italic"):
				cell.italic = format_data["italic"]
			if format_data.has("alignment"):
				cell.alignment = format_data["alignment"]
			if format_data.has("text_color"):
				cell.text_color = format_data["text_color"]
			if format_data.has("bg_color"):
				cell.bg_color = format_data["bg_color"]
			if format_data.has("wrap_text"):
				cell.wrap_text = format_data["wrap_text"]

		SpreadsheetHistoryScript.ActionType.RANGE_CLEAR:
			if is_undo:
				# Restore old cells
				var old_cells: Dictionary = action.data["old_cells"]
				for key in old_cells:
					var cell = SpreadsheetCellScript.new()
					cell.load_from_dict(old_cells[key])
					var pos = SpreadsheetDataScript.parse_cell_key(key)
					spreadsheet_data.set_cell(pos.y, pos.x, cell)

		SpreadsheetHistoryScript.ActionType.RANGE_EDIT:
			var cells_data: Dictionary = action.data["old_cells"] if is_undo else action.data["new_cells"]
			var _start_row: int = action.data["start_row"]
			var _start_col: int = action.data["start_col"]

			for key in cells_data:
				var cell = SpreadsheetCellScript.new()
				cell.load_from_dict(cells_data[key])
				var pos = SpreadsheetDataScript.parse_cell_key(key)
				spreadsheet_data.set_cell(pos.y, pos.x, cell)

		SpreadsheetHistoryScript.ActionType.RANGE_FORMAT:
			var cells: Array = action.data["cells"]
			for cell_data in cells:
				var row: int = cell_data["row"]
				var col: int = cell_data["col"]
				var format_data: Dictionary = cell_data["old_format"] if is_undo else cell_data["new_format"]

				var cell = spreadsheet_data.get_cell(row, col)
				if format_data.has("bold"):
					cell.bold = format_data["bold"]
				if format_data.has("italic"):
					cell.italic = format_data["italic"]
				if format_data.has("alignment"):
					cell.alignment = format_data["alignment"]
				if format_data.has("text_color"):
					cell.text_color = format_data["text_color"]
				if format_data.has("bg_color"):
					cell.bg_color = format_data["bg_color"]
				if format_data.has("wrap_text"):
					cell.wrap_text = format_data["wrap_text"]

		SpreadsheetHistoryScript.ActionType.ROW_RESIZE:
			var row: int = action.data["row"]
			var height: float = action.data["old_height"] if is_undo else action.data["new_height"]
			spreadsheet_data.set_row_height(row, height)
			row_headers.queue_redraw()

		SpreadsheetHistoryScript.ActionType.COLUMN_RESIZE:
			var col: int = action.data["col"]
			var width: float = action.data["old_width"] if is_undo else action.data["new_width"]
			spreadsheet_data.set_column_width(col, width)
			column_headers.queue_redraw()

		SpreadsheetHistoryScript.ActionType.ROW_DELETE:
			var row: int = action.data["row"]
			if is_undo:
				# Re-insert the row and restore its data
				spreadsheet_data.insert_row(row)
				var row_data: Dictionary = action.data["row_data"]
				var row_height: float = action.data["row_height"]
				spreadsheet_data.set_row_height(row, row_height)
				for col_idx in row_data:
					var cell_data: Dictionary = row_data[col_idx]
					var cell = spreadsheet_data.get_cell(row, int(col_idx))
					cell.value = cell_data.get("value", "")
					cell.formula = cell_data.get("formula", "")
					cell.bold = cell_data.get("bold", false)
					cell.italic = cell_data.get("italic", false)
					cell.alignment = cell_data.get("alignment", 0)
					cell.text_color = cell_data.get("text_color", Color.WHITE)
					cell.bg_color = cell_data.get("bg_color", Color.TRANSPARENT)
					cell.number_format = cell_data.get("number_format", "")
					cell.refresh_display()
				row_headers.queue_redraw()
			else:
				# Re-delete the row (redo)
				spreadsheet_data.delete_row(row)
				row_headers.queue_redraw()
			_update_scrollbar_ranges()

		SpreadsheetHistoryScript.ActionType.COLUMN_DELETE:
			var col: int = action.data["col"]
			if is_undo:
				# Re-insert the column and restore its data
				spreadsheet_data.insert_column(col)
				var col_data: Dictionary = action.data["col_data"]
				var col_width: float = action.data["col_width"]
				spreadsheet_data.set_column_width(col, col_width)
				for row_idx in col_data:
					var cell_data: Dictionary = col_data[row_idx]
					var cell = spreadsheet_data.get_cell(int(row_idx), col)
					cell.value = cell_data.get("value", "")
					cell.formula = cell_data.get("formula", "")
					cell.bold = cell_data.get("bold", false)
					cell.italic = cell_data.get("italic", false)
					cell.alignment = cell_data.get("alignment", 0)
					cell.text_color = cell_data.get("text_color", Color.WHITE)
					cell.bg_color = cell_data.get("bg_color", Color.TRANSPARENT)
					cell.number_format = cell_data.get("number_format", "")
					cell.refresh_display()
				column_headers.queue_redraw()
			else:
				# Re-delete the column (redo)
				spreadsheet_data.delete_column(col)
				column_headers.queue_redraw()
			_update_scrollbar_ranges()

	cells_canvas.queue_redraw()
	_update_selection_display()
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


## Undo/Redo Public API

## Perform undo operation
func undo() -> bool:
	if not history.can_undo():
		return false
	_perform_undo()
	return true


## Perform redo operation
func redo() -> bool:
	if not history.can_redo():
		return false
	_perform_redo()
	return true


## Check if undo is available
func can_undo() -> bool:
	return history.can_undo()


## Check if redo is available
func can_redo() -> bool:
	return history.can_redo()


## Get the number of undoable actions
func get_undo_count() -> int:
	return history.get_undo_count()


## Get the number of redoable actions
func get_redo_count() -> int:
	return history.get_redo_count()


## Set a cell value with history recording (for external callers like MCP)
func set_cell_value_with_history(row: int, col: int, value: Variant) -> void:
	# Get old value for history
	var cell = spreadsheet_data.get_cell_if_exists(row, col)
	var old_value: Variant = ""
	var old_formula: String = ""
	if cell:
		old_value = cell.value
		old_formula = cell.formula

	# Set the new value
	spreadsheet_data.set_cell_value(row, col, value)

	# Get new formula if applicable
	var new_cell = spreadsheet_data.get_cell(row, col)
	var new_formula: String = new_cell.formula if new_cell else ""

	# Record in history
	history.record_cell_edit(row, col, old_value, value, old_formula, new_formula)

	# Trigger UI updates
	cells_canvas.queue_redraw()
	_update_selection_display()
	content_changed.emit()


## Apply formatting to a cell with history recording (for external callers like MCP)
func format_cell_with_history(row: int, col: int, format_options: Dictionary) -> void:
	var cell = spreadsheet_data.get_cell(row, col)

	# Capture old format
	var old_format := {
		"bold": cell.bold,
		"italic": cell.italic,
		"alignment": cell.alignment,
		"text_color": cell.text_color,
		"bg_color": cell.bg_color,
		"number_format": cell.number_format,
		"wrap_text": cell.wrap_text,
	}

	# Apply new format (coerce types — MCP JSON may pass bools as strings)
	if format_options.has("bold"):
		var v = format_options["bold"]
		cell.bold = (v is bool and v) or (v is String and v == "true")
	if format_options.has("italic"):
		var v = format_options["italic"]
		cell.italic = (v is bool and v) or (v is String and v == "true")
	if format_options.has("alignment"):
		cell.alignment = str(format_options["alignment"])
	if format_options.has("text_color"):
		cell.text_color = format_options["text_color"]
	if format_options.has("bg_color"):
		cell.bg_color = format_options["bg_color"]
	if format_options.has("number_format"):
		cell.number_format = str(format_options["number_format"])
		cell.refresh_display()
	if format_options.has("wrap_text"):
		var v = format_options["wrap_text"]
		cell.wrap_text = (v is bool and v) or (v is String and v == "true")

	# Capture new format
	var new_format := {
		"bold": cell.bold,
		"italic": cell.italic,
		"alignment": cell.alignment,
		"text_color": cell.text_color,
		"bg_color": cell.bg_color,
		"number_format": cell.number_format,
		"wrap_text": cell.wrap_text,
	}

	# Record in history
	history.record_cell_format(row, col, old_format, new_format)

	# Trigger UI updates
	cells_canvas.queue_redraw()
	content_changed.emit()


## Delete a row with history recording (for external callers like MCP)
func delete_row_with_history(row: int) -> bool:
	if row < 0 or row >= spreadsheet_data.row_count:
		return false

	# Capture the row data before deletion
	var row_data: Dictionary = {}
	for col in range(spreadsheet_data.column_count):
		var cell = spreadsheet_data.get_cell_if_exists(row, col)
		if cell and not cell.is_empty():
			row_data[col] = {
				"value": cell.value,
				"formula": cell.formula,
				"bold": cell.bold,
				"italic": cell.italic,
				"alignment": cell.alignment,
				"text_color": cell.text_color,
				"bg_color": cell.bg_color,
				"number_format": cell.number_format,
			}

	# Get row height
	var row_height: float = spreadsheet_data.get_row_height(row)

	# Delete the row
	spreadsheet_data.delete_row(row)

	# Record in history
	history.record_row_delete(row, row_data, row_height)

	# Trigger UI updates
	row_headers.queue_redraw()
	cells_canvas.queue_redraw()
	_update_scrollbar_ranges()
	content_changed.emit()

	return true


## Delete a column with history recording (for external callers like MCP)
func delete_column_with_history(col: int) -> bool:
	if col < 0 or col >= spreadsheet_data.column_count:
		return false

	# Capture the column data before deletion
	var col_data: Dictionary = {}
	for row in range(spreadsheet_data.row_count):
		var cell = spreadsheet_data.get_cell_if_exists(row, col)
		if cell and not cell.is_empty():
			col_data[row] = {
				"value": cell.value,
				"formula": cell.formula,
				"bold": cell.bold,
				"italic": cell.italic,
				"alignment": cell.alignment,
				"text_color": cell.text_color,
				"bg_color": cell.bg_color,
				"number_format": cell.number_format,
			}

	# Get column width
	var col_width: float = spreadsheet_data.get_column_width(col)

	# Delete the column
	spreadsheet_data.delete_column(col)

	# Record in history
	history.record_column_delete(col, col_data, col_width)

	# Trigger UI updates
	column_headers.queue_redraw()
	cells_canvas.queue_redraw()
	_update_scrollbar_ranges()
	content_changed.emit()

	return true


## Begin a batch operation (groups multiple edits into one undo action)
## Returns a batch_id to pass to end_batch()
func begin_batch(_description: String = "") -> int:
	# For now, just return a marker - batch support can be enhanced later
	return history.get_undo_count()


## End a batch operation - all changes since begin_batch become one undo step
func end_batch(_batch_id: int) -> void:
	# Future enhancement: merge actions since batch_id into one compound action
	pass


## File Import/Export

func _on_import_pressed() -> void:
	if not import_dialog:
		_create_import_dialog()
	import_dialog.popup_centered(Vector2(800, 600))


func _on_export_pressed() -> void:
	if not export_dialog:
		_create_export_dialog()
	export_dialog.popup_centered(Vector2(800, 600))


func _create_import_dialog() -> void:
	import_dialog = FileDialog.new()
	import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	import_dialog.title = "Import Spreadsheet"
	import_dialog.filters = SpreadsheetFileHandlerScript.get_import_filters()
	import_dialog.file_selected.connect(_on_import_file_selected)
	add_child(import_dialog)


func _create_export_dialog() -> void:
	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "Export Spreadsheet"
	export_dialog.filters = SpreadsheetFileHandlerScript.get_export_filters()
	export_dialog.file_selected.connect(_on_export_file_selected)
	add_child(export_dialog)


func _on_import_file_selected(path: String) -> void:
	var err := SpreadsheetFileHandlerScript.import_file(path, spreadsheet_data)
	if err != OK:
		push_error("Failed to import file: " + path + " (error: " + str(err) + ")")
		return

	# Update UI
	cells_canvas.set_data(spreadsheet_data)
	column_headers.set_data(spreadsheet_data)
	row_headers.set_data(spreadsheet_data)
	cells_canvas.queue_redraw()
	column_headers.queue_redraw()
	row_headers.queue_redraw()
	_update_scrollbar_ranges()
	_update_selection_display()
	content_changed.emit()


func _on_export_file_selected(path: String) -> void:
	var err := SpreadsheetFileHandlerScript.export_file(path, spreadsheet_data)
	if err != OK:
		push_error("Failed to export file: " + path + " (error: " + str(err) + ")")


## Chart Methods

func _on_chart_pressed() -> void:
	# Create a chart from current selection
	_show_chart_config_dialog()


func _on_chart_toggle(toggled: bool) -> void:
	chart_container.visible = toggled


func _on_add_chart_pressed() -> void:
	_show_chart_config_dialog()


func _on_close_chart_panel() -> void:
	chart_panel.visible = false


func _show_chart_config_dialog() -> void:
	if not chart_config_dialog:
		_create_chart_config_dialog()

	# Pre-populate with selection
	var sel_rect: Rect2i = cells_canvas.get_selection_rect()
	if sel_rect.size != Vector2i.ZERO:
		# Use first column as X, rest as series
		var x_start := SpreadsheetDataScript.cell_to_reference(sel_rect.position.y, sel_rect.position.x)
		var x_end := SpreadsheetDataScript.cell_to_reference(sel_rect.end.y - 1, sel_rect.position.x)
		_chart_x_range_edit.text = x_start + ":" + x_end

		# Add other columns as series
		_chart_series_edit.text = ""
		for col in range(sel_rect.position.x + 1, sel_rect.end.x):
			var s_start := SpreadsheetDataScript.cell_to_reference(sel_rect.position.y, col)
			var s_end := SpreadsheetDataScript.cell_to_reference(sel_rect.end.y - 1, col)
			if not _chart_series_edit.text.is_empty():
				_chart_series_edit.text += ","
			_chart_series_edit.text += s_start + ":" + s_end

	chart_config_dialog.popup_centered(Vector2(400, 350))


var _chart_title_edit: LineEdit
var _chart_type_option: OptionButton
var _chart_x_range_edit: LineEdit
var _chart_series_edit: LineEdit
var _chart_x_is_date_check: CheckBox
var _chart_header_row_check: CheckBox


func _create_chart_config_dialog() -> void:
	chart_config_dialog = Window.new()
	chart_config_dialog.title = "Create Chart"
	chart_config_dialog.size = Vector2(500, 420)
	chart_config_dialog.min_size = Vector2(450, 390)
	chart_config_dialog.transient = true
	chart_config_dialog.exclusive = true
	chart_config_dialog.close_requested.connect(func(): chart_config_dialog.hide())
	add_child(chart_config_dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 10)
	chart_config_dialog.add_child(vbox)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(margin)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 8)
	margin.add_child(form)

	# Title
	var title_row := HBoxContainer.new()
	form.add_child(title_row)
	var title_label := Label.new()
	title_label.text = "Title:"
	title_label.custom_minimum_size.x = 80
	title_row.add_child(title_label)
	_chart_title_edit = LineEdit.new()
	_chart_title_edit.text = "Chart"
	_chart_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_chart_title_edit)

	# Type
	var type_row := HBoxContainer.new()
	form.add_child(type_row)
	var type_label := Label.new()
	type_label.text = "Type:"
	type_label.custom_minimum_size.x = 80
	type_row.add_child(type_label)
	_chart_type_option = OptionButton.new()
	_chart_type_option.add_item("Line Chart", SpreadsheetChartScript.ChartType.LINE)
	_chart_type_option.add_item("Bar Chart", SpreadsheetChartScript.ChartType.BAR)
	_chart_type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_row.add_child(_chart_type_option)

	# X Range
	var x_row := HBoxContainer.new()
	form.add_child(x_row)
	var x_label := Label.new()
	x_label.text = "X Range:"
	x_label.custom_minimum_size.x = 80
	x_row.add_child(x_label)
	_chart_x_range_edit = LineEdit.new()
	_chart_x_range_edit.placeholder_text = "e.g., A1:A10"
	_chart_x_range_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_row.add_child(_chart_x_range_edit)

	# X is Date
	var date_row := HBoxContainer.new()
	form.add_child(date_row)
	var date_spacer := Control.new()
	date_spacer.custom_minimum_size.x = 80
	date_row.add_child(date_spacer)
	_chart_x_is_date_check = CheckBox.new()
	_chart_x_is_date_check.text = "X-axis contains dates"
	date_row.add_child(_chart_x_is_date_check)

	# First row is header
	var header_row := HBoxContainer.new()
	form.add_child(header_row)
	var header_spacer := Control.new()
	header_spacer.custom_minimum_size.x = 80
	header_row.add_child(header_spacer)
	_chart_header_row_check = CheckBox.new()
	_chart_header_row_check.text = "First row contains headers"
	_chart_header_row_check.button_pressed = true  # Default to checked
	header_row.add_child(_chart_header_row_check)

	# Series
	var series_row := HBoxContainer.new()
	form.add_child(series_row)
	var series_label := Label.new()
	series_label.text = "Series:"
	series_label.custom_minimum_size.x = 80
	series_row.add_child(series_label)
	_chart_series_edit = LineEdit.new()
	_chart_series_edit.placeholder_text = "e.g., B1:B10,C1:C10"
	_chart_series_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	series_row.add_child(_chart_series_edit)

	# Help text
	var help := Label.new()
	help.text = "Enter ranges separated by commas for multiple series."
	help.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	form.add_child(help)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	form.add_child(spacer)

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 10)
	form.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): chart_config_dialog.hide())
	btn_row.add_child(cancel_btn)

	var create_btn := Button.new()
	create_btn.text = "Create"
	create_btn.pressed.connect(_on_create_chart_confirmed)
	btn_row.add_child(create_btn)


func _on_create_chart_confirmed() -> void:
	var chart := SpreadsheetChartScript.new()
	chart.title = _chart_title_edit.text
	chart.type = _chart_type_option.get_selected_id() as SpreadsheetChartScript.ChartType
	chart.x_range = _chart_x_range_edit.text
	chart.x_is_date = _chart_x_is_date_check.button_pressed
	chart.first_row_is_header = _chart_header_row_check.button_pressed

	# Parse series
	var series_text := _chart_series_edit.text.strip_edges()
	if not series_text.is_empty():
		var series_ranges := series_text.split(",")
		for range_str in series_ranges:
			var trimmed := range_str.strip_edges()
			if not trimmed.is_empty():
				chart.add_series(trimmed)

	# Add the chart
	add_chart(chart)

	chart_config_dialog.hide()


func add_chart(chart: SpreadsheetChartScript) -> void:
	charts.append(chart)

	# Also add to data model if not already there
	if not spreadsheet_data.charts.has(chart):
		spreadsheet_data.charts.append(chart)

	# Create chart canvas
	var canvas := ChartCanvasScript.new()
	canvas.custom_minimum_size = Vector2(0, chart.height)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.set_chart(chart)
	chart_canvases.append(canvas)
	chart_container.add_child(canvas)

	# Create chart wrapper with controls
	#var wrapper := HBoxContainer.new()
	chart_container.move_child(canvas, chart_container.get_child_count() - 1)

	# Update chart with data
	_update_chart(charts.size() - 1)

	# Show chart panel and set initial split
	if not chart_panel.visible:
		chart_panel.visible = true
		# Set split to show chart at ~40% of available height
		await get_tree().process_frame
		var total_height := split_container.size.y
		split_container.split_offset = int(total_height * 0.6)

	content_changed.emit()


func remove_chart(index: int) -> void:
	if index < 0 or index >= charts.size():
		return

	var chart = charts[index]
	charts.remove_at(index)

	# Also remove from data model
	var data_idx: int = spreadsheet_data.charts.find(chart)
	if data_idx >= 0:
		spreadsheet_data.charts.remove_at(data_idx)

	var canvas: Control = chart_canvases[index]
	chart_canvases.remove_at(index)
	canvas.queue_free()

	content_changed.emit()


## Get chart by ID or index
func get_chart(id_or_index) -> SpreadsheetChartScript:
	if id_or_index is int:
		if id_or_index >= 0 and id_or_index < charts.size():
			return charts[id_or_index]
	elif id_or_index is String:
		for chart in charts:
			if chart.id == id_or_index:
				return chart
	return null


## Get chart index by ID
func get_chart_index(chart_id: String) -> int:
	for i in range(charts.size()):
		if charts[i].id == chart_id:
			return i
	return -1


## Update a chart and refresh its display
func update_chart_properties(index: int, properties: Dictionary) -> bool:
	if index < 0 or index >= charts.size():
		return false

	var chart: SpreadsheetChartScript = charts[index]

	# Update properties
	if properties.has("title"):
		chart.title = properties["title"]
	if properties.has("type"):
		var type_str: String = properties["type"]
		chart.type = SpreadsheetChartScript.ChartType.LINE if type_str == "line" else SpreadsheetChartScript.ChartType.BAR
	if properties.has("x_range"):
		chart.x_range = properties["x_range"]
	if properties.has("x_is_date"):
		chart.x_is_date = properties["x_is_date"]
	if properties.has("first_row_is_header"):
		chart.first_row_is_header = properties["first_row_is_header"]
	if properties.has("x_axis_label"):
		chart.x_axis_label = properties["x_axis_label"]
	if properties.has("y_axis_label"):
		chart.y_axis_label = properties["y_axis_label"]
	if properties.has("show_legend"):
		chart.show_legend = properties["show_legend"]
	if properties.has("show_grid"):
		chart.show_grid = properties["show_grid"]
	if properties.has("y_auto_scale"):
		chart.y_auto_scale = properties["y_auto_scale"]
	if properties.has("y_min"):
		chart.y_min = properties["y_min"]
	if properties.has("y_max"):
		chart.y_max = properties["y_max"]

	# Update series if provided
	if properties.has("series"):
		chart.clear_series()
		for series_range in properties["series"]:
			if series_range is String:
				chart.add_series(series_range)
			elif series_range is Dictionary:
				var range_str: String = series_range.get("range", "")
				var _name: String = series_range.get("name", "")
				var color = series_range.get("color", Color.TRANSPARENT)
				if color is String:
					color = Color.from_string(color, Color.TRANSPARENT)
				chart.add_series(range_str, _name, color)

	# Refresh the chart display
	_update_chart(index)
	content_changed.emit()
	return true


func _update_chart(index: int) -> void:
	if index < 0 or index >= charts.size():
		return

	var chart: SpreadsheetChartScript = charts[index]
	var canvas: Control = chart_canvases[index]

	var chart_data: ChartRendererScript.ChartData = ChartRendererScript.process(chart, spreadsheet_data)
	canvas.set_chart_data(chart_data)


func _update_all_charts() -> void:
	for i in range(charts.size()):
		_update_chart(i)


## Sync charts from spreadsheet_data.charts to the visual chart canvases
## Call this after loading data from markdown or external sources
func sync_charts_from_data() -> void:
	# Clear existing chart canvases (but not spreadsheet_data.charts - that's the source)
	charts.clear()
	for canvas in chart_canvases:
		canvas.queue_free()
	chart_canvases.clear()

	# Create canvases for charts in spreadsheet_data
	for chart in spreadsheet_data.charts:
		# Add to local charts array (not to spreadsheet_data.charts since it's already there)
		charts.append(chart)

		# Create chart canvas
		var canvas := ChartCanvasScript.new()
		canvas.custom_minimum_size = Vector2(0, chart.height)
		canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		canvas.set_chart(chart)
		chart_canvases.append(canvas)
		chart_container.add_child(canvas)

		# Update chart with data
		_update_chart(charts.size() - 1)

	if charts.size() > 0:
		chart_panel.visible = true


## Override serialize to include charts
func serialize() -> Dictionary:
	var data: Dictionary = spreadsheet_data.to_dict()

	# Add charts
	var charts_data: Array[Dictionary] = []
	for chart in charts:
		charts_data.append(chart.to_dict())
	data["charts"] = charts_data

	return data


## Override deserialize to restore charts
func deserialize(data: Dictionary) -> void:
	print("[SpreadsheetEditor] deserialize() called, cells_canvas=%s" % cells_canvas)
	# Ensure UI is built before deserializing (in case _ready hasn't run yet)
	if cells_canvas == null:
		history = SpreadsheetHistoryScript.new()
		_build_ui()
		_connect_signals()

	spreadsheet_data = SpreadsheetDataScript.new()
	spreadsheet_data.load_from_dict(data)
	print("[SpreadsheetEditor] Deserialized %d cells" % spreadsheet_data.cells.size())
	_setup_sheet_resolver()  # Set up cross-sheet reference resolver
	# Defer recalculation to allow other sheets to load first (for cross-sheet refs)
	_schedule_deferred_recalculation()
	print("[SpreadsheetEditor] Setting data on canvases, cells_canvas=%s" % cells_canvas)
	cells_canvas.set_data(spreadsheet_data)
	column_headers.set_data(spreadsheet_data)
	row_headers.set_data(spreadsheet_data)
	spreadsheet_data.data_changed.connect(_on_data_changed)
	print("[SpreadsheetEditor] Canvas size: %s, data.row_count=%d, data.column_count=%d" % [cells_canvas.size, spreadsheet_data.row_count, spreadsheet_data.column_count])

	# Force redraw after loading data
	cells_canvas.queue_redraw()
	column_headers.queue_redraw()
	row_headers.queue_redraw()

	# Restore charts
	charts.clear()
	for canvas in chart_canvases:
		canvas.queue_free()
	chart_canvases.clear()

	var charts_data: Array = data.get("charts", [])
	for chart_data in charts_data:
		var chart := SpreadsheetChartScript.new()
		chart.load_from_dict(chart_data)
		add_chart(chart)

	if charts.size() > 0:
		chart_panel.visible = true

	_update_layout()


## Sync linked notes with current spreadsheet data
## Call this when the spreadsheet is saved or closed
func sync_linked_notes(editor_name: String) -> void:
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return

	var markdown_content: String = spreadsheet_data.to_markdown()

	# Iterate through all note threads
	for tab_idx in range(notes_container.Tabs.get_tab_count()):
		var thread = notes_container.Tabs.get_tab_control(tab_idx)
		if not thread:
			continue

		# Get notes in this thread
		for child in thread.get_children():
			if child is NoteScript and child.linked_spreadsheet == editor_name:
				# Update the note's content
				var controls = child.get_controls_container()
				if controls and controls.has_method("set_content"):
					controls.set_content(markdown_content)
				elif controls and "content" in controls:
					controls.content = markdown_content
