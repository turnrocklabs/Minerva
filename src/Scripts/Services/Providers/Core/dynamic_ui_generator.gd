class_name DynamicUIGenerator
extends Node

signal parameter_changed(param_name, value)

# if we have file fields in input data, this will be true
var binary_data: = false

var _field_scenes: = {
	"string": String_Field,
	"image": ImageField,
	"file": FileField,
	"list": ListField,
	"array": ListField,
	"bool": BoolField,
	"number": NumberField,
	"object": ObjectField,
	
	# complex data types
	"notes": NoteField,
}


func process_parameters(parameters: Dictionary, input: = true) -> Array[Control]:
	var controls: Array[Control]

	for key in parameters.keys():
		var fields_params: Dictionary = parameters[key]

		var field_type: String = fields_params.get("type", "")

		var field_scene: GDScript = _field_scenes.get(field_type)

		binary_data = binary_data or (input and [ImageField, FileField].has(field_scene))

		if not field_scene:
			push_error("No field scene for given type: %s" % field_type)
		
		var ctrl = field_scene.create(fields_params, input)
		ctrl.set_meta("field_name", key)

		controls.append(ctrl)

	return controls

func get_user_input(input_container: Control) -> Dictionary:
	var data: Dictionary

	for child in input_container.get_children():
		if child.has_method("get_user_data"):
			var child_data = child.get_user_data()

			var field_name = child.get_meta("field_name")

			data[field_name] = child_data

	return data

func clear_output(input_container: Control) -> void:
	for child in input_container.get_children():
		if child.has_method("clear_data"):
			child.clear_data()


func set_output(input_container: Control, data: Dictionary) -> Dictionary:
	for child in input_container.get_children():
		if child.has_method("update_output"):

			var field_name = child.get_meta("field_name")

			if not field_name in data:

				continue

			child.update_output(data[field_name])

	return data
