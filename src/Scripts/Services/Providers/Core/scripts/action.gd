class_name Action
extends RefCounted

var name: String
var description: String
var input_parameters: Dictionary	
var output_parameters: Dictionary	
var topic: String

func _init(action_parameters: Dictionary) -> void:
	name = action_parameters.get("name", "No name")
	description = action_parameters.get("description", "No description")
	topic = action_parameters.get("topic")
	input_parameters = action_parameters.get("input_parameters", {})
	output_parameters = action_parameters.get("output_parameters", {})