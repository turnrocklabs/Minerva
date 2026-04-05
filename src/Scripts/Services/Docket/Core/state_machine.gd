extends RefCounted
class_name StateMachine
## Type-specific state machine enforcement.


static func can_transition(schema: Dictionary, type: String, from: String, to: String) -> bool:
	if not schema.types.has(type):
		return false
	var transitions: Dictionary = schema.types[type].transitions
	if not transitions.has(from):
		return false
	var valid: Array = transitions[from]
	return valid.has(to)


static func get_valid_transitions(schema: Dictionary, type: String, from: String) -> Array:
	if not schema.types.has(type):
		return []
	var transitions: Dictionary = schema.types[type].transitions
	if not transitions.has(from):
		return []
	return transitions[from].duplicate()


## BFS shortest path from `from` to `to` through the transition graph.
## Returns an Array of state strings (excluding `from`, including `to`), or [] if unreachable.
static func find_path(schema: Dictionary, type: String, from: String, to: String) -> Array:
	if not schema.types.has(type):
		return []
	var transitions: Dictionary = schema.types[type].transitions
	if not transitions.has(from):
		return []
	if from == to:
		return []

	# BFS
	var queue: Array = [from]
	var visited: Dictionary = {from: ""}  # state -> predecessor
	while queue.size() > 0:
		var current: String = queue.pop_front()
		if not transitions.has(current):
			continue
		for neighbor in transitions[current]:
			if visited.has(neighbor):
				continue
			visited[neighbor] = current
			if neighbor == to:
				# Reconstruct path
				var path: Array = []
				var step: String = to
				while step != from:
					path.push_front(step)
					step = visited[step]
				return path
			queue.append(neighbor)
	return []


## Perform a transition with automatic shortest-path walking.
## If the direct transition is invalid, find the shortest path and walk each step.
## The `note` is applied only to the final transition. `extra` is applied only to the final step.
## Returns {} on success, or {"error": ...} if no path exists or an intermediate step fails.
static func perform_transition_auto(schema: Dictionary, item: Dictionary, to: String, actor: String, note: String = "", extra: Dictionary = {}) -> Dictionary:
	var type: String = item.type
	var from: String = item.status

	# Try direct transition first
	if can_transition(schema, type, from, to):
		return perform_transition(schema, item, to, actor, note, extra)

	# Find shortest path
	var path := find_path(schema, type, from, to)
	if path.is_empty():
		# No path exists — fall back to the original error
		return perform_transition(schema, item, to, actor, note, extra)

	# Walk intermediate steps (all except the last)
	for i in range(path.size() - 1):
		var step: String = path[i]
		var result := perform_transition(schema, item, step, actor)
		if result.has("error"):
			return result

	# Final step — apply note and extra
	return perform_transition(schema, item, to, actor, note, extra)


static func get_all_states(schema: Dictionary, type: String) -> Array:
	if not schema.types.has(type):
		return []
	return schema.types[type].get("states", []).duplicate()


static func perform_transition(schema: Dictionary, item: Dictionary, to: String, actor: String, note: String = "", extra: Dictionary = {}) -> Dictionary:
	var type: String = item.type
	var from: String = item.status

	if not can_transition(schema, type, from, to):
		# Check if target state exists at all
		var all_states := get_all_states(schema, type)
		if not all_states.has(to):
			return {"error": "Cannot transition %s from '%s' to '%s'. State '%s' does not exist for type %s. Valid states: %s" % [type, from, to, to, type, str(all_states)]}
		# State exists but no path to it
		var valid := get_valid_transitions(schema, type, from)
		return {"error": "Cannot transition %s from '%s' to '%s'. No valid path exists. Valid next states: %s" % [type, from, to, str(valid)]}

	# Check transition rules (e.g., bug resolved requires resolution)
	var type_def: Dictionary = schema.types[type]
	if type_def.has("transition_rules") and type_def.transition_rules.has(to):
		var rules: Dictionary = type_def.transition_rules[to]
		if rules.has("required_fields"):
			for field in rules.required_fields:
				if not extra.has(field) and not item.get(field, ""):
					return {"error": "Transition to '%s' requires field '%s'" % [to, field]}

	# Apply extra fields (like resolution)
	for key in extra:
		item[key] = extra[key]

	var old_status: String = item.status
	item.status = to
	DataModel.add_event(item, "transition", actor, "%s → %s%s" % [old_status, to, (". " + note if note else "")])

	return {}
