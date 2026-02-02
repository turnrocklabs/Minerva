class_name PCBSuggestion
extends RefCounted
## Represents an AI-proposed change to the PCB layout.

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBSuggestion.gd")

## Types of suggestions
enum SuggestionType {
	MOVE,       # Move component to new position
	ROTATE,     # Rotate component
	ADD,        # Add new component
	DELETE,     # Delete component
	ROUTE,      # Route a trace
	SWAP,       # Swap two components
	ALIGN,      # Align multiple components
	GROUP_MOVE, # Move multiple components together
	PIN_REMAP   # Remap a net connection from one pin to another
}

## Unique identifier for this suggestion
var id: String = ""

## Type of suggestion
var type: SuggestionType = SuggestionType.MOVE

## Human-readable description of the suggestion
var description: String = ""

## Target component ID (for single-component operations)
var target_component: String = ""

## Target components (for multi-component operations like ALIGN, GROUP_MOVE)
var target_components: Array[String] = []

## Original state before the change (for preview/undo)
var original_state: Dictionary = {}

## Proposed state after the change
var proposed_state: Dictionary = {}

## Confidence level (0.0 - 1.0)
var confidence: float = 1.0

## Reason for the suggestion
var reason: String = ""

## Timestamp when suggestion was created
var created_at: float = 0.0

## Whether this suggestion is currently being previewed
var is_previewing: bool = false

## Whether this suggestion has been accepted
var is_accepted: bool = false

## Whether this suggestion has been rejected
var is_rejected: bool = false


## Create a move suggestion
static func create_move_suggestion(
	component_id: String,
	original_pos: Vector2,
	proposed_pos: Vector2,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.MOVE
	suggestion.target_component = component_id
	suggestion.description = "Move %s from (%.1f, %.1f) to (%.1f, %.1f)" % [
		component_id, original_pos.x, original_pos.y, proposed_pos.x, proposed_pos.y
	]
	suggestion.original_state = {
		"position": {"x": original_pos.x, "y": original_pos.y}
	}
	suggestion.proposed_state = {
		"position": {"x": proposed_pos.x, "y": proposed_pos.y}
	}
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Create a rotate suggestion
static func create_rotate_suggestion(
	component_id: String,
	original_rot: float,
	proposed_rot: float,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.ROTATE
	suggestion.target_component = component_id
	suggestion.description = "Rotate %s from %.0f to %.0f degrees" % [
		component_id, original_rot, proposed_rot
	]
	suggestion.original_state = {"rotation": original_rot}
	suggestion.proposed_state = {"rotation": proposed_rot}
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Create an add component suggestion
static func create_add_suggestion(
	component_id: String,
	footprint: String,
	position: Vector2,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.ADD
	suggestion.target_component = component_id
	suggestion.description = "Add %s (%s) at (%.1f, %.1f)" % [
		component_id, footprint, position.x, position.y
	]
	suggestion.original_state = {}  # Nothing existed before
	suggestion.proposed_state = {
		"id": component_id,
		"footprint": footprint,
		"position": {"x": position.x, "y": position.y}
	}
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Create a delete component suggestion
static func create_delete_suggestion(
	component_id: String,
	component_data: Dictionary,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.DELETE
	suggestion.target_component = component_id
	suggestion.description = "Delete %s" % component_id
	suggestion.original_state = component_data
	suggestion.proposed_state = {}  # Nothing will exist after
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Create a route suggestion
static func create_route_suggestion(
	net_name: String,
	waypoints: Array,
	layer: String = "top",
	width: float = 0.25,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.ROUTE
	suggestion.description = "Route net %s with %d waypoints on %s layer (%.2fmm)" % [net_name, waypoints.size(), layer, width]
	suggestion.original_state = {}
	suggestion.proposed_state = {
		"net_name": net_name,
		"waypoints": waypoints,
		"layer": layer,
		"width": width
	}
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Create a pin remap suggestion (move a net connection from one pin to another)
static func create_pin_remap_suggestion(
	net_name: String,
	old_component: String,
	old_pin: String,
	new_component: String,
	new_pin: String,
	reason_text: String = ""
):
	var suggestion := _Self.new()
	suggestion.id = _generate_id()
	suggestion.type = SuggestionType.PIN_REMAP
	suggestion.target_component = old_component  # Primary component involved
	suggestion.description = "Remap %s from %s.%s to %s.%s" % [net_name, old_component, old_pin, new_component, new_pin]
	suggestion.original_state = {
		"net_name": net_name,
		"component": old_component,
		"pin": old_pin
	}
	suggestion.proposed_state = {
		"net_name": net_name,
		"component": new_component,
		"pin": new_pin
	}
	suggestion.reason = reason_text
	suggestion.created_at = Time.get_unix_time_from_system()
	return suggestion


## Generate a unique ID
static func _generate_id() -> String:
	return "sug_%s" % str(randi() % 1000000).pad_zeros(6)


## Get the proposed position (for MOVE suggestions)
func get_proposed_position() -> Vector2:
	if type != SuggestionType.MOVE:
		return Vector2.ZERO
	var pos_data: Dictionary = proposed_state.get("position", {})
	return Vector2(pos_data.get("x", 0), pos_data.get("y", 0))


## Get the original position (for MOVE suggestions)
func get_original_position() -> Vector2:
	if type != SuggestionType.MOVE:
		return Vector2.ZERO
	var pos_data: Dictionary = original_state.get("position", {})
	return Vector2(pos_data.get("x", 0), pos_data.get("y", 0))


## Get the proposed rotation (for ROTATE suggestions)
func get_proposed_rotation() -> float:
	if type != SuggestionType.ROTATE:
		return 0.0
	return proposed_state.get("rotation", 0.0)


## Get route waypoints as Vector2 array (for ROUTE suggestions)
func get_route_waypoints() -> Array[Vector2]:
	var result: Array[Vector2] = []
	if type != SuggestionType.ROUTE:
		return result

	var waypoints: Array = proposed_state.get("waypoints", [])
	for wp in waypoints:
		if wp is Dictionary:
			result.append(Vector2(wp.get("x", 0), wp.get("y", 0)))
		elif wp is Vector2:
			result.append(wp)
	return result


## Get route layer (for ROUTE suggestions)
func get_route_layer() -> String:
	if type != SuggestionType.ROUTE:
		return "top"
	return proposed_state.get("layer", "top")


## Get route width (for ROUTE suggestions)
func get_route_width() -> float:
	if type != SuggestionType.ROUTE:
		return 0.25
	return proposed_state.get("width", 0.25)


## Get the net name (for ROUTE and PIN_REMAP suggestions)
func get_net_name() -> String:
	if type == SuggestionType.ROUTE or type == SuggestionType.PIN_REMAP:
		return proposed_state.get("net_name", "")
	return ""


## Get old pin info (for PIN_REMAP suggestions)
func get_old_pin() -> Dictionary:
	if type != SuggestionType.PIN_REMAP:
		return {}
	return {
		"component": original_state.get("component", ""),
		"pin": original_state.get("pin", "")
	}


## Get new pin info (for PIN_REMAP suggestions)
func get_new_pin() -> Dictionary:
	if type != SuggestionType.PIN_REMAP:
		return {}
	return {
		"component": proposed_state.get("component", ""),
		"pin": proposed_state.get("pin", "")
	}


## Mark as accepted
func accept() -> void:
	is_accepted = true
	is_rejected = false
	is_previewing = false


## Mark as rejected
func reject() -> void:
	is_rejected = true
	is_accepted = false
	is_previewing = false


## Check if suggestion is still pending
func is_pending() -> bool:
	return not is_accepted and not is_rejected


## Serialize to dictionary
func to_dict() -> Dictionary:
	return {
		"id": id,
		"type": SuggestionType.keys()[type],
		"description": description,
		"target_component": target_component,
		"target_components": target_components.duplicate(),
		"original_state": original_state.duplicate(true),
		"proposed_state": proposed_state.duplicate(true),
		"confidence": confidence,
		"reason": reason,
		"created_at": created_at,
		"is_accepted": is_accepted,
		"is_rejected": is_rejected
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")

	var type_str: String = data.get("type", "MOVE")
	var type_idx := SuggestionType.keys().find(type_str)
	type = type_idx if type_idx >= 0 else SuggestionType.MOVE

	description = data.get("description", "")
	target_component = data.get("target_component", "")

	target_components.clear()
	var targets: Array = data.get("target_components", [])
	for t in targets:
		target_components.append(str(t))

	original_state = data.get("original_state", {}).duplicate(true)
	proposed_state = data.get("proposed_state", {}).duplicate(true)
	confidence = data.get("confidence", 1.0)
	reason = data.get("reason", "")
	created_at = data.get("created_at", 0.0)
	is_accepted = data.get("is_accepted", false)
	is_rejected = data.get("is_rejected", false)


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary):
	var suggestion := _Self.new()
	suggestion.load_from_dict(data)
	return suggestion


## Get a status string
func get_status() -> String:
	if is_accepted:
		return "Accepted"
	elif is_rejected:
		return "Rejected"
	elif is_previewing:
		return "Previewing"
	else:
		return "Pending"
