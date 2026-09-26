class_name SpreadsheetAutoFilterPopup
extends PopupPanel
## The AutoFilter dropdown for one column (Scenes/SpreadsheetAutoFilterPopup.tscn).
##
## open_for() fills the checklist with the column's distinct values and
## reflects its current criterion. The popup never touches the sheet: it
## emits one of the request signals and hides, and SpreadsheetAutoFilterUI
## turns the request into an undoable change.
##
## A non-empty "contains" box wins over the checklist: OK applies a text
## criterion, and while typing the list shows only the matching values. With
## the box empty, OK applies the checked values; all checked means no
## criterion for the column.

signal values_requested(col: int, allowed: PackedStringArray)
signal text_requested(col: int, needle: String)
signal clear_column_requested(col: int)
signal clear_all_requested()

## Checklist label for the blank value ("").
const BLANK_LABEL := "(Blanks)"

@onready var _title: Label = %Title
@onready var _contains_edit: LineEdit = %ContainsEdit
@onready var _select_all: CheckBox = %SelectAll
@onready var _value_tree: Tree = %ValueTree
@onready var _clear_column_button: Button = %ClearColumnButton
@onready var _clear_all_button: Button = %ClearAllButton
@onready var _cancel_button: Button = %CancelButton
@onready var _ok_button: Button = %OkButton

var _col: int = -1


func _ready() -> void:
	_contains_edit.text_changed.connect(_on_contains_changed)
	_contains_edit.text_submitted.connect(func(_t: String) -> void: _on_ok_pressed())
	_select_all.toggled.connect(_on_select_all_toggled)
	_value_tree.item_edited.connect(_sync_controls)
	_clear_column_button.pressed.connect(func() -> void: _finish(clear_column_requested, [_col]))
	_clear_all_button.pressed.connect(func() -> void: _finish(clear_all_requested, []))
	_cancel_button.pressed.connect(hide)
	_ok_button.pressed.connect(_on_ok_pressed)


## Show the popup for `col` below `anchor` (a screen-space rectangle, the
## header glyph). `values` are the column's distinct values ("" = blank);
## `criterion` is SpreadsheetAutoFilter.get_criterion(col).
func open_for(col: int, title: String, values: PackedStringArray, criterion: Dictionary,
		filter_has_criteria: bool, anchor: Rect2) -> void:
	_col = col
	_title.text = title
	var kind := str(criterion.get("type", ""))
	var allowed: Array = criterion.get("values", []) if kind == "values" else []

	_value_tree.clear()
	var root := _value_tree.create_item()
	for value in values:
		var item := _value_tree.create_item(root)
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)
		item.set_text(0, BLANK_LABEL if value.is_empty() else value)
		item.set_metadata(0, value)
		item.set_checked(0, kind != "values" or allowed.has(value))

	_contains_edit.text = str(criterion.get("text", "")) if kind == "text" else ""
	_on_contains_changed(_contains_edit.text)
	_clear_column_button.disabled = criterion.is_empty()
	_clear_all_button.disabled = not filter_has_criteria

	reset_size()
	position = Vector2i(int(anchor.position.x), int(anchor.end.y))
	popup()
	_contains_edit.grab_focus()


func _items() -> Array[TreeItem]:
	var root := _value_tree.get_root()
	return root.get_children() if root else ([] as Array[TreeItem])


## Show only values containing the typed text, then refresh the controls.
func _on_contains_changed(text: String) -> void:
	var needle := text.to_lower()
	for item in _items():
		item.visible = needle.is_empty() or str(item.get_metadata(0)).to_lower().contains(needle)
	_sync_controls()


## Select All checks or unchecks every value currently listed.
func _on_select_all_toggled(on: bool) -> void:
	for item in _items():
		if item.visible:
			item.set_checked(0, on)
	_sync_controls()


## Keep Select All and OK consistent with the checklist and the text box.
func _sync_controls() -> void:
	var all_checked := true
	var any_checked := false
	for item in _items():
		if item.visible:
			all_checked = all_checked and item.is_checked(0)
			any_checked = any_checked or item.is_checked(0)
	_select_all.set_pressed_no_signal(all_checked and any_checked)
	# With text in the box the list is a preview of what the text keeps.
	var text_mode := not _contains_edit.text.is_empty()
	_select_all.disabled = text_mode
	_value_tree.mouse_filter = Control.MOUSE_FILTER_IGNORE if text_mode else Control.MOUSE_FILTER_STOP
	_ok_button.disabled = _contains_edit.text.is_empty() and not any_checked


func _on_ok_pressed() -> void:
	if _ok_button.disabled:
		return
	if not _contains_edit.text.is_empty():
		_finish(text_requested, [_col, _contains_edit.text])
		return
	var allowed := PackedStringArray()
	var all_checked := true
	for item in _items():
		if item.is_checked(0):
			allowed.append(str(item.get_metadata(0)))
		else:
			all_checked = false
	if all_checked:
		_finish(clear_column_requested, [_col])
	else:
		_finish(values_requested, [_col, allowed])


func _finish(request: Signal, args: Array) -> void:
	hide()
	request.emit.callv(args)
