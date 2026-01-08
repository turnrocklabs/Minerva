class_name SpreadsheetHistory
extends RefCounted
## Manages undo/redo history for spreadsheet operations.

signal undo_available_changed(available: bool)
signal redo_available_changed(available: bool)

## Maximum number of actions to keep in history
var max_history: int = 100

## Undo and redo stacks
var _undo_stack: Array = []  # Array of HistoryAction
var _redo_stack: Array = []  # Array of HistoryAction


## History action types
enum ActionType {
	CELL_EDIT,
	CELL_FORMAT,
	RANGE_EDIT,
	RANGE_FORMAT,
	RANGE_CLEAR,
	ROW_INSERT,
	ROW_DELETE,
	COLUMN_INSERT,
	COLUMN_DELETE,
	ROW_RESIZE,
	COLUMN_RESIZE,
}


## A single undoable action
class HistoryAction:
	var type: ActionType
	var data: Dictionary

	func _init(action_type: ActionType, action_data: Dictionary) -> void:
		type = action_type
		data = action_data


## Record a cell edit action
func record_cell_edit(row: int, col: int, old_value: Variant, new_value: Variant, old_formula: String = "", new_formula: String = "") -> void:
	var action := HistoryAction.new(ActionType.CELL_EDIT, {
		"row": row,
		"col": col,
		"old_value": old_value,
		"new_value": new_value,
		"old_formula": old_formula,
		"new_formula": new_formula,
	})
	_push_action(action)


## Record a cell format change
func record_cell_format(row: int, col: int, old_format: Dictionary, new_format: Dictionary) -> void:
	var action := HistoryAction.new(ActionType.CELL_FORMAT, {
		"row": row,
		"col": col,
		"old_format": old_format,
		"new_format": new_format,
	})
	_push_action(action)


## Record a range edit (for paste operations)
func record_range_edit(start_row: int, start_col: int, old_cells: Dictionary, new_cells: Dictionary) -> void:
	var action := HistoryAction.new(ActionType.RANGE_EDIT, {
		"start_row": start_row,
		"start_col": start_col,
		"old_cells": old_cells,
		"new_cells": new_cells,
	})
	_push_action(action)


## Record a range format change
func record_range_format(cells_format: Array) -> void:
	# cells_format is array of {row, col, old_format, new_format}
	var action := HistoryAction.new(ActionType.RANGE_FORMAT, {
		"cells": cells_format,
	})
	_push_action(action)


## Record a range clear
func record_range_clear(start_row: int, start_col: int, end_row: int, end_col: int, old_cells: Dictionary) -> void:
	var action := HistoryAction.new(ActionType.RANGE_CLEAR, {
		"start_row": start_row,
		"start_col": start_col,
		"end_row": end_row,
		"end_col": end_col,
		"old_cells": old_cells,
	})
	_push_action(action)


## Record a row resize
func record_row_resize(row: int, old_height: float, new_height: float) -> void:
	var action := HistoryAction.new(ActionType.ROW_RESIZE, {
		"row": row,
		"old_height": old_height,
		"new_height": new_height,
	})
	_push_action(action)


## Record a column resize
func record_column_resize(col: int, old_width: float, new_width: float) -> void:
	var action := HistoryAction.new(ActionType.COLUMN_RESIZE, {
		"col": col,
		"old_width": old_width,
		"new_width": new_width,
	})
	_push_action(action)


## Push an action onto the undo stack
func _push_action(action: HistoryAction) -> void:
	_undo_stack.append(action)

	# Clear redo stack when new action is performed
	if not _redo_stack.is_empty():
		_redo_stack.clear()
		redo_available_changed.emit(false)

	# Trim history if too large
	while _undo_stack.size() > max_history:
		_undo_stack.pop_front()

	undo_available_changed.emit(true)


## Check if undo is available
func can_undo() -> bool:
	return not _undo_stack.is_empty()


## Check if redo is available
func can_redo() -> bool:
	return not _redo_stack.is_empty()


## Perform undo and return the action to reverse
func undo() -> HistoryAction:
	if _undo_stack.is_empty():
		return null

	var action: HistoryAction = _undo_stack.pop_back()
	_redo_stack.append(action)

	undo_available_changed.emit(not _undo_stack.is_empty())
	redo_available_changed.emit(true)

	return action


## Perform redo and return the action to reapply
func redo() -> HistoryAction:
	if _redo_stack.is_empty():
		return null

	var action: HistoryAction = _redo_stack.pop_back()
	_undo_stack.append(action)

	undo_available_changed.emit(true)
	redo_available_changed.emit(not _redo_stack.is_empty())

	return action


## Clear all history
func clear() -> void:
	_undo_stack.clear()
	_redo_stack.clear()
	undo_available_changed.emit(false)
	redo_available_changed.emit(false)


## Get the number of undoable actions
func get_undo_count() -> int:
	return _undo_stack.size()


## Get the number of redoable actions
func get_redo_count() -> int:
	return _redo_stack.size()
