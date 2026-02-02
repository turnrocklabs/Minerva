class_name PCBData
extends RefCounted
## Main data model for PCB layout with sparse storage for components, nets, and traces.

const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBNetScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBNet.gd")
const PCBTraceScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBTrace.gd")
const PCBSuggestionScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSuggestion.gd")

## Signals for reactive UI updates
signal data_changed()
signal component_changed(component_id: String)
signal component_added(component_id: String)
signal component_removed(component_id: String)
signal net_changed(net_name: String)
signal trace_changed(trace_id: String)
signal suggestion_added(suggestion_id: String)
signal suggestion_resolved(suggestion_id: String, accepted: bool)
signal structure_changed()

## Board properties
var board_width: float = 100.0   # mm
var board_height: float = 100.0  # mm
var grid_size: float = 2.54      # mm (0.1 inch default)
var board_name: String = "Untitled"

## Board layers
var layers: Array[String] = ["top", "bottom"]

## Sparse storage (like SpreadsheetData.cells)
var components: Dictionary = {}   # component_id -> PCBComponent
var nets: Dictionary = {}         # net_name -> PCBNet
var traces: Dictionary = {}       # trace_id -> PCBTrace

## AI suggestions (pending proposals)
var suggestions: Dictionary = {}  # suggestion_id -> PCBSuggestion

## Undo/redo history
var history: Array[Dictionary] = []
var history_index: int = -1
const MAX_HISTORY_SIZE := 50

## Next trace ID counter
var _next_trace_id: int = 1


func _init(width: float = 100.0, height: float = 100.0) -> void:
	board_width = width
	board_height = height


#region Component Management

## Add a component to the board
func add_component(component: PCBComponentScript) -> void:
	if component.id.is_empty():
		push_error("[PCBData] Component must have an ID")
		return

	components[component.id] = component
	component_added.emit(component.id)
	data_changed.emit()


## Get a component by ID
func get_component(component_id: String) -> PCBComponentScript:
	return components.get(component_id, null)


## Check if a component exists
func has_component(component_id: String) -> bool:
	return components.has(component_id)


## Remove a component from the board
func remove_component(component_id: String) -> void:
	if not components.has(component_id):
		return

	# Remove from all nets
	for net_name in nets:
		nets[net_name].remove_component_pins(component_id)

	components.erase(component_id)
	component_removed.emit(component_id)
	data_changed.emit()


## Update component position
func move_component(component_id: String, new_position: Vector2) -> void:
	var component := get_component(component_id)
	if component:
		component.position = new_position
		component_changed.emit(component_id)
		data_changed.emit()


## Update component rotation
func rotate_component(component_id: String, degrees: float) -> void:
	var component := get_component(component_id)
	if component:
		component.set_rotation(degrees)
		component_changed.emit(component_id)
		data_changed.emit()


## Get all component IDs
func get_component_ids() -> Array[String]:
	var result: Array[String] = []
	for id in components:
		result.append(id)
	return result


## Get component at a position (for hit testing)
func get_component_at(position: Vector2) -> String:
	for component_id in components:
		var component: PCBComponentScript = components[component_id]
		if component.contains_point(position):
			return component_id
	return ""


## Get all components in a region
func get_components_in_region(region: Rect2) -> Array[String]:
	var result: Array[String] = []
	for component_id in components:
		var component: PCBComponentScript = components[component_id]
		if region.intersects(component.get_bounding_rect()):
			result.append(component_id)
	return result

#endregion


#region Net Management

## Add a net
func add_net(net: PCBNetScript) -> void:
	if net.name.is_empty():
		push_error("[PCBData] Net must have a name")
		return

	nets[net.name] = net
	net_changed.emit(net.name)
	data_changed.emit()


## Get a net by name
func get_net(net_name: String) -> PCBNetScript:
	return nets.get(net_name, null)


## Check if a net exists
func has_net(net_name: String) -> bool:
	return nets.has(net_name)


## Remove a net
func remove_net(net_name: String) -> void:
	if nets.has(net_name):
		# Also remove traces for this net
		var traces_to_remove: Array[String] = []
		for trace_id in traces:
			if traces[trace_id].net_name == net_name:
				traces_to_remove.append(trace_id)

		for trace_id in traces_to_remove:
			traces.erase(trace_id)

		nets.erase(net_name)
		net_changed.emit(net_name)
		data_changed.emit()


## Connect a pin to a net
func connect_pin_to_net(net_name: String, component_id: String, pin_name: String) -> void:
	if not nets.has(net_name):
		# Create the net if it doesn't exist
		var net := PCBNetScript.new()
		net.name = net_name
		net.color = PCBNetScript.generate_color_for_name(net_name)
		nets[net_name] = net

	nets[net_name].add_pin(component_id, pin_name)
	net_changed.emit(net_name)
	data_changed.emit()


## Disconnect a pin from a net
func disconnect_pin_from_net(net_name: String, component_id: String, pin_name: String) -> void:
	if nets.has(net_name):
		nets[net_name].remove_pin(component_id, pin_name)
		net_changed.emit(net_name)
		data_changed.emit()


## Get all net names
func get_net_names() -> Array[String]:
	var result: Array[String] = []
	for name in nets:
		result.append(name)
	return result


## Find which net a pin belongs to
func find_net_for_pin(component_id: String, pin_name: String) -> String:
	for net_name in nets:
		if nets[net_name].has_pin(component_id, pin_name):
			return net_name
	return ""

#endregion


#region Trace Management

## Add a trace
func add_trace(trace: PCBTraceScript) -> void:
	if trace.id.is_empty():
		trace.id = "trace_%d" % _next_trace_id
		_next_trace_id += 1

	traces[trace.id] = trace
	trace_changed.emit(trace.id)
	data_changed.emit()


## Get a trace by ID
func get_trace(trace_id: String) -> PCBTraceScript:
	return traces.get(trace_id, null)


## Remove a trace
func remove_trace(trace_id: String) -> void:
	if traces.has(trace_id):
		traces.erase(trace_id)
		trace_changed.emit(trace_id)
		data_changed.emit()


## Get all traces for a net
func get_traces_for_net(net_name: String) -> Array[PCBTraceScript]:
	var result: Array[PCBTraceScript] = []
	for trace_id in traces:
		if traces[trace_id].net_name == net_name:
			result.append(traces[trace_id])
	return result


## Get all trace IDs
func get_trace_ids() -> Array[String]:
	var result: Array[String] = []
	for id in traces:
		result.append(id)
	return result

#endregion


#region Suggestion Management

## Add an AI suggestion
func add_suggestion(suggestion: PCBSuggestionScript) -> void:
	if suggestion.id.is_empty():
		push_error("[PCBData] Suggestion must have an ID")
		return

	suggestions[suggestion.id] = suggestion
	suggestion_added.emit(suggestion.id)
	data_changed.emit()


## Get a suggestion by ID
func get_suggestion(suggestion_id: String) -> PCBSuggestionScript:
	return suggestions.get(suggestion_id, null)


## Get all pending suggestions
func get_pending_suggestions() -> Array[PCBSuggestionScript]:
	var result: Array[PCBSuggestionScript] = []
	for sug_id in suggestions:
		if suggestions[sug_id].is_pending():
			result.append(suggestions[sug_id])
	return result


## Accept a suggestion
func accept_suggestion(suggestion_id: String) -> bool:
	var suggestion := get_suggestion(suggestion_id)
	if not suggestion or not suggestion.is_pending():
		return false

	# Apply the suggestion based on type
	match suggestion.type:
		PCBSuggestionScript.SuggestionType.MOVE:
			var proposed_pos := suggestion.get_proposed_position()
			move_component(suggestion.target_component, proposed_pos)

		PCBSuggestionScript.SuggestionType.ROTATE:
			var proposed_rot := suggestion.get_proposed_rotation()
			rotate_component(suggestion.target_component, proposed_rot)

		PCBSuggestionScript.SuggestionType.ADD:
			var component := PCBComponentScript.new()
			component.load_from_dict(suggestion.proposed_state)
			add_component(component)

		PCBSuggestionScript.SuggestionType.DELETE:
			remove_component(suggestion.target_component)

	suggestion.accept()
	suggestion_resolved.emit(suggestion_id, true)
	data_changed.emit()
	return true


## Reject a suggestion
func reject_suggestion(suggestion_id: String) -> void:
	var suggestion := get_suggestion(suggestion_id)
	if suggestion:
		suggestion.reject()
		suggestion_resolved.emit(suggestion_id, false)
		data_changed.emit()


## Remove a suggestion
func remove_suggestion(suggestion_id: String) -> void:
	if suggestions.has(suggestion_id):
		suggestions.erase(suggestion_id)
		data_changed.emit()


## Clear all resolved suggestions
func clear_resolved_suggestions() -> void:
	var to_remove: Array[String] = []
	for sug_id in suggestions:
		if not suggestions[sug_id].is_pending():
			to_remove.append(sug_id)

	for sug_id in to_remove:
		suggestions.erase(sug_id)

	if to_remove.size() > 0:
		data_changed.emit()

#endregion


#region Undo/Redo Support

## Save current state to history
func save_to_history(action_name: String = "Change") -> void:
	# Remove any redo states
	if history_index < history.size() - 1:
		history.resize(history_index + 1)

	# Save current state
	var state := {
		"action": action_name,
		"components": _serialize_components(),
		"nets": _serialize_nets(),
		"traces": _serialize_traces()
	}

	history.append(state)
	history_index = history.size() - 1

	# Limit history size
	if history.size() > MAX_HISTORY_SIZE:
		history.remove_at(0)
		history_index -= 1


## Undo last action
func undo() -> bool:
	if history_index <= 0:
		return false

	history_index -= 1
	_restore_state(history[history_index])
	data_changed.emit()
	structure_changed.emit()
	return true


## Redo last undone action
func redo() -> bool:
	if history_index >= history.size() - 1:
		return false

	history_index += 1
	_restore_state(history[history_index])
	data_changed.emit()
	structure_changed.emit()
	return true


## Check if undo is available
func can_undo() -> bool:
	return history_index > 0


## Check if redo is available
func can_redo() -> bool:
	return history_index < history.size() - 1


## Serialize components for undo
func _serialize_components() -> Dictionary:
	var result := {}
	for id in components:
		result[id] = components[id].to_dict()
	return result


## Serialize nets for undo
func _serialize_nets() -> Dictionary:
	var result := {}
	for name in nets:
		result[name] = nets[name].to_dict()
	return result


## Serialize traces for undo
func _serialize_traces() -> Dictionary:
	var result := {}
	for id in traces:
		result[id] = traces[id].to_dict()
	return result


## Restore state from history
func _restore_state(state: Dictionary) -> void:
	# Restore components
	components.clear()
	var comp_data: Dictionary = state.get("components", {})
	for id in comp_data:
		var component = PCBComponentScript.from_dict(comp_data[id])
		components[id] = component

	# Restore nets
	nets.clear()
	var net_data: Dictionary = state.get("nets", {})
	for name in net_data:
		var net = PCBNetScript.from_dict(net_data[name])
		nets[name] = net

	# Restore traces
	traces.clear()
	var trace_data: Dictionary = state.get("traces", {})
	for id in trace_data:
		var trace = PCBTraceScript.from_dict(trace_data[id])
		traces[id] = trace

#endregion


#region Serialization

## Serialize the entire PCB data
func to_dict() -> Dictionary:
	var comp_dict := {}
	for id in components:
		comp_dict[id] = components[id].to_dict()

	var net_dict := {}
	for name in nets:
		net_dict[name] = nets[name].to_dict()

	var trace_dict := {}
	for id in traces:
		trace_dict[id] = traces[id].to_dict()

	var sug_dict := {}
	for id in suggestions:
		sug_dict[id] = suggestions[id].to_dict()

	return {
		"version": 1,
		"board_name": board_name,
		"board_width": board_width,
		"board_height": board_height,
		"grid_size": grid_size,
		"layers": layers.duplicate(),
		"components": comp_dict,
		"nets": net_dict,
		"traces": trace_dict,
		"suggestions": sug_dict
	}


## Deserialize PCB data
func load_from_dict(data: Dictionary) -> void:
	board_name = data.get("board_name", "Untitled")
	board_width = data.get("board_width", 100.0)
	board_height = data.get("board_height", 100.0)
	grid_size = data.get("grid_size", 2.54)

	layers.clear()
	var layers_arr: Array = data.get("layers", ["top", "bottom"])
	for layer in layers_arr:
		layers.append(str(layer))

	# Load components
	components.clear()
	var comp_data: Dictionary = data.get("components", {})
	for id in comp_data:
		var component = PCBComponentScript.from_dict(comp_data[id])
		components[id] = component

	# Load nets
	nets.clear()
	var net_data: Dictionary = data.get("nets", {})
	for name in net_data:
		var net = PCBNetScript.from_dict(net_data[name])
		nets[name] = net

	# Load traces
	traces.clear()
	var trace_data: Dictionary = data.get("traces", {})
	for id in trace_data:
		var trace = PCBTraceScript.from_dict(trace_data[id])
		traces[id] = trace

	# Load suggestions
	suggestions.clear()
	var sug_data: Dictionary = data.get("suggestions", {})
	for id in sug_data:
		var suggestion = PCBSuggestionScript.from_dict(sug_data[id])
		suggestions[id] = suggestion

	structure_changed.emit()
	data_changed.emit()


## Export to CSV format (component placement list)
func to_csv() -> String:
	var lines: PackedStringArray = ["id,footprint,x,y,rotation,layer,value"]

	for id in components:
		var comp: PCBComponentScript = components[id]
		var value: String = comp.properties.get("value", "")
		lines.append("%s,%s,%.2f,%.2f,%.0f,%s,%s" % [
			comp.id,
			PCBComponentScript.FootprintType.keys()[comp.footprint],
			comp.position.x,
			comp.position.y,
			comp.rotation,
			comp.layer,
			value
		])

	return "\n".join(lines)


## Import from CSV format
func from_csv(csv_text: String) -> void:
	var lines := csv_text.split("\n")
	if lines.size() < 2:
		return

	# Parse header
	var header := lines[0].split(",")
	var id_idx := header.find("id")
	var footprint_idx := header.find("footprint")
	var x_idx := header.find("x")
	var y_idx := header.find("y")
	var rot_idx := header.find("rotation")
	var layer_idx := header.find("layer")
	var value_idx := header.find("value")

	if id_idx < 0 or x_idx < 0 or y_idx < 0:
		push_error("[PCBData] Invalid CSV format: missing required columns")
		return

	# Parse data rows
	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue

		var fields := line.split(",")
		if fields.size() <= id_idx:
			continue

		var component := PCBComponentScript.new()
		component.id = fields[id_idx]

		if footprint_idx >= 0 and fields.size() > footprint_idx:
			var fp_str := fields[footprint_idx]
			var fp_idx := PCBComponentScript.FootprintType.keys().find(fp_str)
			if fp_idx >= 0:
				component.footprint = fp_idx

		if x_idx >= 0 and fields.size() > x_idx:
			component.position.x = fields[x_idx].to_float()
		if y_idx >= 0 and fields.size() > y_idx:
			component.position.y = fields[y_idx].to_float()
		if rot_idx >= 0 and fields.size() > rot_idx:
			component.rotation = fields[rot_idx].to_float()
		if layer_idx >= 0 and fields.size() > layer_idx:
			component.layer = fields[layer_idx]
		if value_idx >= 0 and fields.size() > value_idx:
			component.properties["value"] = fields[value_idx]

		component.setup_standard_pins()
		components[component.id] = component

	structure_changed.emit()
	data_changed.emit()


## Export to YAML format (for pcb-architect compatibility)
func to_yaml() -> String:
	var yaml_lines: PackedStringArray = []
	yaml_lines.append("board:")
	yaml_lines.append("  name: %s" % board_name)
	yaml_lines.append("  width: %.2f" % board_width)
	yaml_lines.append("  height: %.2f" % board_height)
	yaml_lines.append("  grid_size: %.2f" % grid_size)
	yaml_lines.append("")
	yaml_lines.append("components:")

	for id in components:
		var comp: PCBComponentScript = components[id]
		yaml_lines.append("  - id: %s" % comp.id)
		yaml_lines.append("    footprint: %s" % PCBComponentScript.FootprintType.keys()[comp.footprint])
		yaml_lines.append("    position: [%.2f, %.2f]" % [comp.position.x, comp.position.y])
		yaml_lines.append("    rotation: %.0f" % comp.rotation)
		yaml_lines.append("    layer: %s" % comp.layer)
		if comp.properties.has("value"):
			yaml_lines.append("    value: %s" % comp.properties["value"])
		yaml_lines.append("")

	yaml_lines.append("nets:")
	for name in nets:
		var net: PCBNetScript = nets[name]
		yaml_lines.append("  - name: %s" % net.name)
		yaml_lines.append("    pins:")
		for pin in net.pins:
			yaml_lines.append("      - [%s, %s]" % [pin.get("component_id", ""), pin.get("pin_name", "")])
		yaml_lines.append("")

	return "\n".join(yaml_lines)


## Clear all data
func clear() -> void:
	components.clear()
	nets.clear()
	traces.clear()
	suggestions.clear()
	history.clear()
	history_index = -1
	structure_changed.emit()
	data_changed.emit()

#endregion


#region Utility Methods

## Get the total component count
func get_component_count() -> int:
	return components.size()


## Get the total net count
func get_net_count() -> int:
	return nets.size()


## Get the total trace count
func get_trace_count() -> int:
	return traces.size()


## Snap a position to the grid
func snap_to_grid(position: Vector2) -> Vector2:
	return Vector2(
		roundf(position.x / grid_size) * grid_size,
		roundf(position.y / grid_size) * grid_size
	)


## Check if a position is within the board bounds
func is_within_bounds(position: Vector2) -> bool:
	return position.x >= 0 and position.x <= board_width and \
		   position.y >= 0 and position.y <= board_height


## Get the board bounding rectangle
func get_board_rect() -> Rect2:
	return Rect2(0, 0, board_width, board_height)


## Generate a unique component ID
func generate_component_id(prefix: String = "U") -> String:
	var counter := 1
	var new_id := "%s%d" % [prefix, counter]
	while components.has(new_id):
		counter += 1
		new_id = "%s%d" % [prefix, counter]
	return new_id

#endregion
