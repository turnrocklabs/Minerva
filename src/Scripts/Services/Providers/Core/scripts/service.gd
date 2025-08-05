class_name Service
extends RefCounted

var name: String
var description: String
var actions: Array[Action]
var client_id: String

func _init(service_data: Dictionary) -> void:
	name = service_data.get("name", "")
	description = service_data.get("description", "")
	client_id = service_data.get("client_id", "")

	var actions_arr: Array = service_data.get("actions", [])

	for ad in actions_arr:
		actions.append(Action.new(ad))