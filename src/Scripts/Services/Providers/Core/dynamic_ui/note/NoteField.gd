class_name NoteField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/note/note_scene.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_rich_text_label: RichTextLabel = %RichTextLabel
@onready var _drop_panel_container: PanelContainer = %DropPanelContainer

@onready var _select_items_window: PersistentWindow = %SelectItemsPersistentWindow
@onready var _notes_tree: Tree = %NoteTree

var _requested_fields: Array

var _selected_notes: Array[Note]


static func create(field_params: Dictionary, input: = true) -> NoteField:
	
	var scn: NoteField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"] + ":"
			scn._requested_fields = field_params.get("fields", [])
	
			scn._drop_panel_container.mouse_filter = Control.MOUSE_FILTER_PASS if input else Control.MOUSE_FILTER_IGNORE
	)

	return scn

func get_user_data():
	return _selected_notes

func update_output(notes: Array) -> void:
	_selected_notes.clear()
	_selected_notes.assign(notes)
	_update_count_label()


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Note and not _selected_notes.has(data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_selected_notes.append(data)
	_update_count_label()

func _update_count_label():
	var lines: = PackedStringArray(["Selected %s notes:" % _selected_notes.size()])
	
	for note in _selected_notes:
		lines.append(note.title)

	_field_rich_text_label.text = "\n".join(lines)


func _on_select_items_button_pressed() -> void:
	_notes_tree.clear()

	var root: = _notes_tree.create_item()
	root.set_text(0, "Notes")

	for i in SingletonObject.notes_container.get_tab_count():
		var tab_item: = _notes_tree.create_item(root)

		var tab_name = SingletonObject.notes_container.get_tab_name(i)
	
		tab_item.set_text(0, tab_name)

		for note in SingletonObject.notes_container.get_notes(i):
			var note_item: = _notes_tree.create_item(tab_item)
			note_item.set_text(0, note.title)
			note_item.set_metadata(0, note)
			
			if note in _selected_notes:
				note_item.select(0)
				_set_color_recursive(note_item, 0, true)

	_select_items_window.popup_centered()


func _on_note_tree_multi_selected(item: TreeItem, column: int, selected: bool) -> void:
	if _notes_tree.get_next_selected(null) == null: return
	_set_color_recursive.call_deferred(item, column, selected)
	
	
func _set_color_recursive(item: TreeItem, column: int, selected: = true):
	for child in item.get_children():
		_set_color_recursive(child, column, selected)
	
	if selected:
		item.set_custom_bg_color(column, Color.DARK_GREEN)
		item.select(column)
	else:
		item.clear_custom_bg_color(column)
		item.deselect(column)

	


func _on_finish_selection_button_pressed() -> void:
	_selected_notes.clear()

	var current_item: = _notes_tree.get_root()

	while true:
		var selected_item: = _notes_tree.get_next_selected(current_item)
		if selected_item == null:
			break

		if not selected_item.get_metadata(0) is Note:
			for note_item in selected_item.get_children():
				var note: Note = note_item.get_metadata(0)
				if note and note_item.is_selected(0) and not _selected_notes.has(note):
					_selected_notes.append(note)
		else:
				var note: Note = selected_item.get_metadata(0)
				if note and selected_item.is_selected(0) and not _selected_notes.has(note):
					_selected_notes.append(note)

		current_item = selected_item
	

	_update_count_label()

	_select_items_window.hide()


func _on_clear_selection_button_pressed() -> void:
	
	_selected_notes.clear()

	_update_count_label()
