class_name Action
extends RefCounted

var name: String
var description: String
var input_parameters: Dictionary
var output_parameters: Dictionary
var topic: String
## Keep presence and original values: absent metadata differs from explicit false or malformed data.
var model_metadata: Dictionary = {}

func _init(action_parameters: Dictionary) -> void:
	name = action_parameters.get("name", "No name")
	description = action_parameters.get("description", "No description")
	topic = action_parameters.get("topic")
	input_parameters = action_parameters.get("input_parameters", {})
	output_parameters = action_parameters.get("output_parameters", {})

	for field in ["chat_model", "generation_options"]:
		if action_parameters.has(field):
			model_metadata[field] = action_parameters[field]
	model_metadata = model_metadata.duplicate(true)
