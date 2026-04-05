extends RefCounted
class_name DocketGetStateMachine


func get_definition() -> Dictionary:
	return {
		"name": "docket_get_state_machine",
		"description": "Return the full state machine definition for a given item type, including all states, the initial state, and valid transitions from each state. If 'type' is omitted, returns state machines for all types.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"type": {"type": "string", "description": "Item type (e.g. 'bug', 'work_item'). Omit to get all types."},
			},
			"required": [],
		},
	}


func execute(args: Dictionary, schema: Dictionary, _db: DocketDB) -> Dictionary:
	var types: Dictionary = schema.get("types", {})

	if args.has("type") and not str(args.get("type", "")).is_empty():
		var type_name: String = str(args["type"])
		if not types.has(type_name):
			return {"error": "Unknown type: %s. Valid types: %s" % [type_name, ", ".join(PackedStringArray(types.keys()))]}
		return _build_state_machine(type_name, types[type_name])

	# Return all types
	var result: Array = []
	for type_name in types.keys():
		result.append(_build_state_machine(type_name, types[type_name]))
	return {"state_machines": result}


func _build_state_machine(type_name: String, type_def: Dictionary) -> Dictionary:
	return {
		"type": type_name,
		"states": type_def.get("states", []),
		"initial_state": type_def.get("initial_state", ""),
		"transitions": type_def.get("transitions", {}),
	}
