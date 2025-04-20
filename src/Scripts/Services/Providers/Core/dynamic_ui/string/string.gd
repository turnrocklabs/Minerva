class_name String_Field
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/string/string_scene.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_line_edit: LineEdit = %LineEdit
@onready var _field_rich_text_label: RichTextLabel = %RichTextLabel


static func create(field_params: Dictionary, input: = true) -> String_Field:
	
	var scn: String_Field = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"]

			# if input use the line edit
			if input:
				scn._field_line_edit.placeholder_text = field_params["display_name"]
				scn._field_line_edit.tooltip_text = field_params["description"]
				scn._field_line_edit.editable = input
				scn._field_line_edit.visible = true

			# else use rich text label
			else:
				scn._field_rich_text_label.tooltip_text = field_params["description"]
				scn._field_rich_text_label.visible = true	
	)

	return scn

func get_user_data():
	return _field_line_edit.text

func update_output(text: String) -> void:
	_field_rich_text_label.text = text
