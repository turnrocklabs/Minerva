class_name NoteField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/note/note_scene.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_rich_text_label: RichTextLabel = %RichTextLabel
@onready var _drop_panel_container: PanelContainer = %DropPanelContainer

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
