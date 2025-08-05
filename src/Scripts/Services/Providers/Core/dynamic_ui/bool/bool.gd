class_name BoolField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/bool/bool.tscn")


@onready var _field_name_label: Label = %FieldName
@onready var _field_check_box: CheckBox = %CheckBox


static func create(field_params: Dictionary, input: = true) -> BoolField:
	
	var scn: BoolField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"]

			scn._field_check_box.tooltip_text = field_params["description"]
			
			scn._field_check_box.disabled = not input
	)

	return scn

func get_user_data():
	return _field_check_box.button_pressed

func update_output(on: bool) -> void:
	_field_check_box.button_pressed = on
