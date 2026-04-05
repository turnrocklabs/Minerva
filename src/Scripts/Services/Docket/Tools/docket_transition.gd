extends RefCounted
class_name DocketTransition

var _schema: Dictionary = {}
var _cached_description: String = ""


func init(schema: Dictionary) -> void:
	_schema = schema
	_cached_description = ""  # Reset cache


func get_definition() -> Dictionary:
	return {
		"name": "docket_transition",
		"description": _build_description(),
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"to": {"type": "string"},
				"resolution": {"type": "string"},
				"note": {"type": "string"},
				"blocked_by": {"type": "string"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "to"],
		},
	}


func _build_description() -> String:
	if not _cached_description.is_empty():
		return _cached_description

	var desc := "Transition an item to a new state. Enforces type-specific state machine. When transitioning to 'blocked', supply 'blocked_by' (an item ID, optionally cross-project qualified like 'project:DKT-0042')."

	if _schema.is_empty():
		_cached_description = desc
		return _cached_description

	var state_chains := _build_state_chains(_schema)
	_cached_description = desc + "\n\nState chains — " + state_chains
	return _cached_description


func _build_state_chains(schema: Dictionary) -> String:
	var chains: Array = []
	var types: Dictionary = schema.get("types", {})

	for type_name in types.keys():
		var type_def: Dictionary = types[type_name]
		var states: Array = type_def.get("states", [])
		var transitions: Dictionary = type_def.get("transitions", {})

		if states.is_empty():
			continue

		# Build a readable chain showing transitions from each state
		var chain_parts: PackedStringArray = []
		for state in states:
			if transitions.has(state):
				var valid_next: Array = transitions[state]
				if valid_next.is_empty():
					chain_parts.append("%s (terminal)" % state)
				else:
					chain_parts.append(state)
			else:
				chain_parts.append(state)

		var chain_str := " → ".join(chain_parts)
		chains.append("%s: %s" % [type_name, chain_str])

	return ". ".join(PackedStringArray(chains))


func execute(args: Dictionary, schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	var item: Dictionary = db.get_item(id)
	var to: String = args.get("to", "")
	var note: String = args.get("note", "")
	var item_type: String = str(item.get("type", ""))
	var from_state: String = str(item.get("status", ""))
	var extra := {}
	if args.has("resolution"):
		extra["resolution"] = args.resolution
	if args.has("blocked_by"):
		extra["blocked_by"] = args.blocked_by

	var result = StateMachine.perform_transition(schema, item, to, "agent", note, extra)
	if result.has("error"):
		var valid := StateMachine.get_valid_transitions(schema, item_type, from_state)
		db.log_transition(item_type, from_state, to, false, valid)
		return result

	# Log successful transition
	db.log_transition(item_type, from_state, to, true)

	# Write back status + any extra fields + event
	var write_back := {"status": item.status, "updated_at": item.updated_at}
	if extra.has("resolution"):
		write_back["resolution"] = item.get("resolution", "")
	if extra.has("blocked_by"):
		write_back["blocked_by"] = item.get("blocked_by", "")

	db.update_item_fields(id, write_back)
	# Persist the new event(s) — get the last event added by perform_transition
	var events: Array = item.get("events", [])
	if events.size() > 0:
		var ev: Dictionary = events[events.size() - 1]
		db.add_event(id, str(ev.get("event_type", "")), str(ev.get("actor", "")), str(ev.get("note", "")))

	# Auto-create 'blocks' link when transitioning to blocked
	if to == "blocked" and extra.has("blocked_by"):
		var blocked_by_id: String = str(extra.blocked_by)
		# For cross-project refs (project:id format), extract the local ID part
		var local_blocker_id := blocked_by_id
		if ":" in blocked_by_id:
			local_blocker_id = blocked_by_id.split(":")[1]
		# Only create link if the blocking item exists locally
		if db.has_item(local_blocker_id):
			db.add_link(local_blocker_id, id, "blocks")

	return {"id": id, "status": item.status}
