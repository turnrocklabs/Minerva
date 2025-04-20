class_name Service
extends RefCounted

var name: String
var description: String
var actions: Array[Action]

func _init(service_data: Dictionary) -> void:
	name = service_data.get("name", "")
	description = service_data.get("description", "")

	var actions_arr: Array = service_data.get("actions", [])

	for ad in actions_arr:
		actions.append(Action.new(ad))