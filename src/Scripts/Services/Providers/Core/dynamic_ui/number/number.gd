class_name NumberField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/number/Number.tscn")


@onready var _field_name_label: Label = %FieldName
@onready var _field_spin_box: SpinBox = %SpinBox

static func create(field_params: Dictionary, input: = true) -> NumberField:
	
	var scn: NumberField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"]

			scn._field_spin_box.tooltip_text = field_params["description"]
			
			scn._field_spin_box.editable = input
			if field_params.has("step"):
				scn._field_spin_box.step = field_params["step"]
			
			if field_params.has("max"):
				scn._field_spin_box.max = field_params["max"]
			
			if field_params.has("min"):
				scn._field_spin_box.min = field_params["min"]
			
			if field_params.has("value"):
				scn._field_spin_box.value = field_params["value"]
	)

	return scn

func get_user_data():
	return _field_spin_box.value

func update_output(value: float) -> void:
	_field_spin_box.value = value
