class_name BaseServiceAdapter
extends RefCounted


var service: Service


func _init(service_: Service) -> void:
	service = service_

func get_action(topic: String) -> Action:
	if not service: return null
	if not service.actions: return null

	for action in service.actions:
		if action and action.topic == topic:
			return action

	return null


func safe_extract(data: Dictionary, fields: Array[String], types: Array[int], default: Variant = null) -> Variant:
	var current = data if data else {}
	for i in fields.size():
		var field: = fields[i]
		var type: int = types[i] if i < types.size() else -1
		
		if field not in current:
			print("Field '%s' doesn't exist in current data" % field)
			return default
		
		current = current[field]
		
		if type != -1 and typeof(current) != type:
			print("Field '%s' has type '%s' but '%s' expected" % [field, type_string(typeof(current)), type_string(type)])
			return default
	
	return current
