class_name ObjectField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/object/ObjectField.tscn")

@onready var _field_name_label: Label = %FieldName
@onready var _field_text_edit_edit: TextEdit = %TextEdit


static func create(field_params: Dictionary, input: = true) -> ObjectField:
	
	var scn: ObjectField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"] + ":"

			scn._field_text_edit_edit.editable = input
			scn._field_text_edit_edit.placeholder_text = field_params["display_name"]
			scn._field_text_edit_edit.tooltip_text = field_params["description"]
	)

	return scn

func get_user_data():
	if _field_text_edit_edit.text.strip_edges().is_empty(): return {}

	var json = JSON.parse_string(_field_text_edit_edit.text)
	return json if json else {}

func clear_data() -> void:
	update_output({})
	_field_text_edit_edit.text = ""

func update_output(object: Dictionary) -> void:
	_field_text_edit_edit.text = JSON.stringify(object)
