class_name SpreadsheetAutoFilterUI
extends Node
## Connects the AutoFilter pieces of the spreadsheet editor: the header
## dropdown glyph (drawn by SpreadsheetColumnHeaders), the per-column popup
## scene, the Enable/Remove AutoFilter items of the column-header context
## menu and the "N of M rows" count in the formula bar. Every change goes
## through SpreadsheetAutoFilterActions so it lands in the editor's history.
##
## The editor creates one with attach() while building its UI and calls
## bind() whenever it replaces its SpreadsheetData.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetHistoryScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetHistory.gd")
const ColumnHeadersScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ColumnHeaders.gd")
const CellsCanvasScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/CellsCanvas.gd")
const Actions := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetAutoFilterActions.gd")
const PopupScene := preload("res://Scenes/SpreadsheetAutoFilterPopup.tscn")

## Context-menu item ids; clear of the editor's own ids (0, 1).
const MENU_ENABLE := 100
const MENU_REMOVE := 101
const MENU_CLEAR_ALL := 102

var _data: SpreadsheetDataScript = null
var _history: SpreadsheetHistoryScript = null
var _headers: ColumnHeadersScript = null
var _canvas: CellsCanvasScript = null
var _popup: SpreadsheetAutoFilterPopup = null
var _count_label: Label = null
## Called after the set of shown rows may have changed (scrollbar ranges).
var _on_rows_changed: Callable
## Called after a user filter change (marks the document modified).
var _on_user_change: Callable

## Selection as it was when the column-header menu was requested; the editor
## replaces the selection with the whole column before showing the menu.
var _menu_selection: Array[Rect2i] = []
var _menu_col: int = -1


## Create the controller under `parent`. Must run before the editor connects
## its own column_context_menu_requested handler, so the selection is captured
## before the editor selects the whole column.
static func attach(parent: Node, data: SpreadsheetDataScript, history: SpreadsheetHistoryScript,
		headers: ColumnHeadersScript, canvas: CellsCanvasScript, count_parent: Container,
		on_rows_changed: Callable, on_user_change: Callable) -> SpreadsheetAutoFilterUI:
	var ui := SpreadsheetAutoFilterUI.new()
	ui.name = "AutoFilterUI"
	ui._history = history
	ui._headers = headers
	ui._canvas = canvas
	ui._on_rows_changed = on_rows_changed
	ui._on_user_change = on_user_change
	parent.add_child(ui)

	ui._popup = PopupScene.instantiate() as SpreadsheetAutoFilterPopup
	ui.add_child(ui._popup)
	ui._popup.values_requested.connect(ui._on_values_requested)
	ui._popup.text_requested.connect(ui._on_text_requested)
	ui._popup.clear_column_requested.connect(ui._on_clear_column_requested)
	ui._popup.clear_all_requested.connect(ui._on_clear_all_requested)

	ui._count_label = Label.new()
	ui._count_label.visible = false
	count_parent.add_child(ui._count_label)

	headers.autofilter_button_pressed.connect(ui._on_glyph_pressed)
	headers.column_context_menu_requested.connect(ui._on_column_menu_requested)
	ui.bind(data)
	return ui


## Follow `data` (the editor's current sheet); null is ignored.
func bind(data: SpreadsheetDataScript) -> void:
	if _data:
		_data.structure_changed.disconnect(_on_sheet_changed)
		_data.data_changed.disconnect(_on_sheet_changed)
	_data = data
	if _data:
		_data.structure_changed.connect(_on_sheet_changed)
		_data.data_changed.connect(_on_sheet_changed)
	_on_sheet_changed()


## Add the AutoFilter items to the editor's context menu (column source only).
func add_context_items(menu: PopupMenu, source: String) -> void:
	if source != "column" or _data == null:
		return
	if not menu.id_pressed.is_connected(_on_menu_id_pressed):
		menu.id_pressed.connect(_on_menu_id_pressed)
	menu.add_separator()
	if _data.autofilter.is_active():
		menu.add_item("Clear All Filters", MENU_CLEAR_ALL)
		menu.set_item_disabled(menu.get_item_index(MENU_CLEAR_ALL), _data.autofilter.filtered_columns().is_empty())
		menu.add_item("Remove AutoFilter", MENU_REMOVE)
	else:
		menu.add_item("Enable AutoFilter", MENU_ENABLE)
		var target := Actions.range_for_enable(_data, _menu_selection, _menu_col)
		menu.set_item_disabled(menu.get_item_index(MENU_ENABLE), target.size.y < 2)


func _on_column_menu_requested(col: int, _screen_pos: Vector2) -> void:
	_menu_col = col
	_menu_selection = _canvas.get_all_selection_rects()


func _on_menu_id_pressed(id: int) -> void:
	match id:
		MENU_ENABLE:
			_commit(Actions.enable(_data, _history, Actions.range_for_enable(_data, _menu_selection, _menu_col)))
		MENU_REMOVE:
			_popup.hide()
			_commit(Actions.remove(_data, _history))
		MENU_CLEAR_ALL:
			_commit(Actions.clear_all(_data, _history))


func _on_glyph_pressed(col: int, screen_rect: Rect2) -> void:
	var filter := _data.autofilter
	var header_row := filter.filter_range.position.y
	var title := _data.get_cell_display(header_row, col).strip_edges()
	if title.is_empty():
		title = "Column %s" % SpreadsheetDataScript.get_column_label(col)
	_popup.open_for(col, title, Actions.distinct_values(_data, col), filter.get_criterion(col),
		not filter.filtered_columns().is_empty(), screen_rect)


func _on_values_requested(col: int, allowed: PackedStringArray) -> void:
	_commit(Actions.set_values(_data, _history, col, allowed))


func _on_text_requested(col: int, needle: String) -> void:
	_commit(Actions.set_text(_data, _history, col, needle))


func _on_clear_column_requested(col: int) -> void:
	_commit(Actions.clear_column(_data, _history, col))


func _on_clear_all_requested() -> void:
	_commit(Actions.clear_all(_data, _history))


func _commit(changed: bool) -> void:
	if changed:
		_on_user_change.call()


## Refresh the row count and let the editor resize its scroll range. Runs on
## every data or structure change, including undo/redo of filter changes.
func _on_sheet_changed() -> void:
	var active := _data != null and _data.autofilter.is_active()
	_count_label.visible = active
	if active:
		var counts := Actions.row_counts(_data)
		_count_label.text = "%d of %d rows" % [counts.x, counts.y]
	if _data != null:
		_on_rows_changed.call()
