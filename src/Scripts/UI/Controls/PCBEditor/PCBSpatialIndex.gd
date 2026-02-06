class_name PCBSpatialIndex
extends RefCounted
## Spatial query system for natural language spatial reasoning about PCB components.

const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")

## Reference to the PCB data
var data: PCBDataScript = null

## Cardinal directions for describing positions
## Note: normalized diagonal values are approximately 0.7071 (1/sqrt(2))
const DIRECTIONS := {
	"N": Vector2(0, -1),
	"NE": Vector2(0.7071, -0.7071),
	"E": Vector2(1, 0),
	"SE": Vector2(0.7071, 0.7071),
	"S": Vector2(0, 1),
	"SW": Vector2(-0.7071, 0.7071),
	"W": Vector2(-1, 0),
	"NW": Vector2(-0.7071, -0.7071)
}

## Full direction names
const DIRECTION_NAMES := {
	"N": "north",
	"NE": "north-east",
	"E": "east",
	"SE": "south-east",
	"S": "south",
	"SW": "south-west",
	"W": "west",
	"NW": "north-west"
}

## Natural language direction keywords
const DIRECTION_KEYWORDS := {
	"up": Vector2(0, -1),
	"down": Vector2(0, 1),
	"left": Vector2(-1, 0),
	"right": Vector2(1, 0),
	"north": Vector2(0, -1),
	"south": Vector2(0, 1),
	"east": Vector2(1, 0),
	"west": Vector2(-1, 0),
	"above": Vector2(0, -1),
	"below": Vector2(0, 1)
}

## Magnitude keywords (as proportion of board size)
const MAGNITUDE_KEYWORDS := {
	"a bit": 0.05,
	"slightly": 0.03,
	"a little": 0.05,
	"some": 0.1,
	"much": 0.2,
	"a lot": 0.25,
	"significantly": 0.3
}


func _init(pcb_data: PCBDataScript = null) -> void:
	data = pcb_data


## Set the data reference
func set_data(pcb_data: PCBDataScript) -> void:
	data = pcb_data


#region Spatial Queries

## Get all components within a radius of another component
func get_components_near(component_id: String, radius_mm: float) -> Array[String]:
	if not data:
		return []

	var source := data.get_component(component_id)
	if not source:
		return []

	var result: Array[String] = []
	for other_id in data.components:
		if other_id == component_id:
			continue
		var other: PCBComponentScript = data.components[other_id]
		var distance := source.position.distance_to(other.position)
		if distance <= radius_mm:
			result.append(other_id)

	return result


## Get all components in a rectangular region
func get_components_in_region(region: Rect2) -> Array[String]:
	if not data:
		return []

	var result: Array[String] = []
	for comp_id in data.components:
		var comp: PCBComponentScript = data.components[comp_id]
		if region.has_point(comp.position):
			result.append(comp_id)

	return result


## Get the nearest component to a position
func get_nearest_component(position: Vector2, exclude_ids: Array = []) -> String:
	if not data:
		return ""

	var nearest_id := ""
	var nearest_dist := INF

	for comp_id in data.components:
		if comp_id in exclude_ids:
			continue
		var comp: PCBComponentScript = data.components[comp_id]
		var dist := position.distance_to(comp.position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = comp_id

	return nearest_id


## Get the nearest component to another component
func get_nearest_to_component(component_id: String) -> String:
	var source := data.get_component(component_id)
	if not source:
		return ""
	return get_nearest_component(source.position, [component_id])


## Get components between two components (along the line)
func get_components_between(comp_a_id: String, comp_b_id: String, corridor_width: float = 5.0) -> Array[String]:
	if not data:
		return []

	var comp_a := data.get_component(comp_a_id)
	var comp_b := data.get_component(comp_b_id)
	if not comp_a or not comp_b:
		return []

	var result: Array[String] = []
	var line_start := comp_a.position
	var line_end := comp_b.position
	var line_dir := (line_end - line_start).normalized()
	var line_length := line_start.distance_to(line_end)

	for comp_id in data.components:
		if comp_id == comp_a_id or comp_id == comp_b_id:
			continue

		var comp: PCBComponentScript = data.components[comp_id]
		var to_comp := comp.position - line_start

		# Project onto line
		var proj := to_comp.dot(line_dir)
		if proj < 0 or proj > line_length:
			continue  # Beyond line endpoints

		# Calculate distance to line
		var closest_on_line := line_start + line_dir * proj
		var dist := comp.position.distance_to(closest_on_line)

		if dist <= corridor_width:
			result.append(comp_id)

	return result


## Get components connected to a component through nets
func get_connected_components(component_id: String) -> Array[String]:
	if not data:
		return []

	var result: Array[String] = []

	for net_name in data.nets:
		var net = data.nets[net_name]
		var components_in_net: Array[String] = net.get_connected_components()
		if component_id in components_in_net:
			for other_id in components_in_net:
				if other_id != component_id and other_id not in result:
					result.append(other_id)

	return result

#endregion


#region Relative Position Descriptions

## Describe the relative position between two components
func describe_relative_position(from_id: String, to_id: String) -> String:
	if not data:
		return ""

	var from_comp := data.get_component(from_id)
	var to_comp := data.get_component(to_id)
	if not from_comp or not to_comp:
		return ""

	var delta := to_comp.position - from_comp.position
	var distance := delta.length()
	var direction := _get_direction_name(delta)

	return "%s is %.1fmm %s of %s" % [to_id, distance, direction, from_id]


## Get a comprehensive context description for a component
func describe_component_context(component_id: String) -> Dictionary:
	if not data:
		return {}

	var comp := data.get_component(component_id)
	if not comp:
		return {}

	# Get nearby components with descriptions
	var nearby: Array[String] = []
	var nearby_details: Array[Dictionary] = []
	for other_id in data.components:
		if other_id == component_id:
			continue
		var other: PCBComponentScript = data.components[other_id]
		var dist := comp.position.distance_to(other.position)
		if dist <= 30.0:  # 30mm radius
			var direction := _get_direction_name(other.position - comp.position)
			nearby.append("%s (%.1fmm %s)" % [other_id, dist, direction])
			nearby_details.append({
				"id": other_id,
				"distance": dist,
				"direction": direction
			})

	# Sort by distance
	nearby_details.sort_custom(func(a, b): return a.distance < b.distance)
	nearby.clear()
	for detail in nearby_details:
		nearby.append("%s (%.1fmm %s)" % [detail.id, detail.distance, detail.direction])

	# Get connected components via nets
	var connected: Array[String] = []
	for net_name in data.nets:
		var net = data.nets[net_name]
		var pins: Array[String] = net.get_pins_for_component(component_id)
		for pin in pins:
			for other_conn in net.pins:
				var other_id: String = other_conn.get("component_id", "")
				var other_pin: String = other_conn.get("pin_name", "")
				if other_id != component_id:
					connected.append("%s.%s via %s" % [other_id, other_pin, net_name])

	# Determine region
	var region := _get_board_region(comp.position)

	var result := {
		"id": component_id,
		"position": {"x": comp.position.x, "y": comp.position.y},
		"rotation": comp.rotation,
		"footprint": PCBComponentScript.FootprintType.keys()[comp.footprint],
		"layer": comp.layer,
		"nearby": nearby,
		"connected_to": connected,
		"region": region,
		"pins": comp.pins.keys()
	}
	if comp.properties.has("value"):
		result["value"] = comp.properties["value"]
	if not comp.properties.is_empty():
		result["properties"] = comp.properties
	return result


## Determine which region of the board a position is in
func _get_board_region(position: Vector2) -> String:
	if not data:
		return "unknown"

	var center := Vector2(data.board_width / 2.0, data.board_height / 2.0)
	var rel := position - center

	# Determine quadrant
	var h_pos := "center"
	var v_pos := "center"

	if rel.x < -data.board_width * 0.25:
		h_pos = "left"
	elif rel.x > data.board_width * 0.25:
		h_pos = "right"

	if rel.y < -data.board_height * 0.25:
		v_pos = "top"
	elif rel.y > data.board_height * 0.25:
		v_pos = "bottom"

	if h_pos == "center" and v_pos == "center":
		return "center"
	elif h_pos == "center":
		return v_pos
	elif v_pos == "center":
		return h_pos
	else:
		return "%s-%s" % [v_pos, h_pos]


## Get cardinal direction name from vector
func _get_direction_name(delta: Vector2) -> String:
	if delta.length_squared() < 0.01:
		return "at"

	var normalized := delta.normalized()

	# Find closest cardinal direction
	var best_dir := "N"
	var best_dot := -2.0

	for dir_key in DIRECTIONS:
		var dot := normalized.dot(DIRECTIONS[dir_key])
		if dot > best_dot:
			best_dot = dot
			best_dir = dir_key

	return DIRECTION_NAMES[best_dir]

#endregion


#region Natural Language Interpretation

## Interpret a relative movement description and return a target position
func interpret_relative_move(component_id: String, description: String) -> Vector2:
	if not data:
		return Vector2.ZERO

	var comp := data.get_component(component_id)
	if not comp:
		return Vector2.ZERO

	var desc_lower := description.to_lower()

	# Check for "closer to X" pattern
	var closer_match := _parse_closer_to(desc_lower)
	if not closer_match.is_empty():
		return _interpret_closer_to(comp, closer_match)

	# Check for "away from X" pattern
	var away_match := _parse_away_from(desc_lower)
	if not away_match.is_empty():
		return _interpret_away_from(comp, away_match)

	# Check for "near X" pattern
	var near_match := _parse_near(desc_lower)
	if not near_match.is_empty():
		return _interpret_near(comp, near_match)

	# Check for directional movement
	var direction := _parse_direction(desc_lower)
	var magnitude := _parse_magnitude(desc_lower)

	if direction != Vector2.ZERO:
		var move_amount := magnitude * maxf(data.board_width, data.board_height)
		return comp.position + direction * move_amount

	# Check for "away from edge" / "toward center"
	if "center" in desc_lower or "middle" in desc_lower:
		return _interpret_toward_center(comp)

	if "edge" in desc_lower and "away" in desc_lower:
		return _interpret_away_from_edge(comp)

	# Default: small movement based on any magnitude found
	if magnitude > 0:
		# Random direction with magnitude
		return comp.position + Vector2(magnitude * data.board_width * 0.5, 0)

	return comp.position


## Parse "closer to X" pattern
func _parse_closer_to(desc: String) -> String:
	var patterns := ["closer to ", "toward ", "towards ", "near "]
	for pattern in patterns:
		var idx := desc.find(pattern)
		if idx >= 0:
			var rest := desc.substr(idx + pattern.length())
			# Extract component ID (uppercase words)
			var words := rest.split(" ")
			if words.size() > 0:
				return words[0].to_upper()
	return ""


## Parse "away from X" pattern
func _parse_away_from(desc: String) -> String:
	var patterns := ["away from ", "farther from ", "further from "]
	for pattern in patterns:
		var idx := desc.find(pattern)
		if idx >= 0:
			var rest := desc.substr(idx + pattern.length())
			var words := rest.split(" ")
			if words.size() > 0:
				return words[0].to_upper()
	return ""


## Parse "near X" pattern
func _parse_near(desc: String) -> String:
	var patterns := ["near ", "next to ", "beside ", "by "]
	for pattern in patterns:
		var idx := desc.find(pattern)
		if idx >= 0:
			var rest := desc.substr(idx + pattern.length())
			var words := rest.split(" ")
			if words.size() > 0:
				return words[0].to_upper()
	return ""


## Interpret "closer to X"
func _interpret_closer_to(comp: PCBComponentScript, target_id: String) -> Vector2:
	var target := data.get_component(target_id)
	if not target:
		return comp.position

	var direction := (target.position - comp.position).normalized()
	var distance := comp.position.distance_to(target.position)
	var move_amount := minf(distance * 0.5, 10.0)  # Move halfway or 10mm max

	return comp.position + direction * move_amount


## Interpret "away from X"
func _interpret_away_from(comp: PCBComponentScript, target_id: String) -> Vector2:
	var target := data.get_component(target_id)
	if not target:
		return comp.position

	var direction := (comp.position - target.position).normalized()
	return comp.position + direction * 5.0  # Move 5mm away


## Interpret "near X"
func _interpret_near(comp: PCBComponentScript, target_id: String) -> Vector2:
	var target := data.get_component(target_id)
	if not target:
		return comp.position

	var direction := (target.position - comp.position).normalized()
	var distance := comp.position.distance_to(target.position)

	# Move to be about 5mm from target
	var target_distance := 5.0
	var move_amount := distance - target_distance

	return comp.position + direction * move_amount


## Interpret "toward center"
func _interpret_toward_center(comp: PCBComponentScript) -> Vector2:
	var center := Vector2(data.board_width / 2.0, data.board_height / 2.0)
	var direction := (center - comp.position).normalized()
	return comp.position + direction * 5.0


## Interpret "away from edge"
func _interpret_away_from_edge(comp: PCBComponentScript) -> Vector2:
	var center := Vector2(data.board_width / 2.0, data.board_height / 2.0)
	var direction := (center - comp.position).normalized()
	return comp.position + direction * 5.0


## Parse direction from description
func _parse_direction(desc: String) -> Vector2:
	for keyword in DIRECTION_KEYWORDS:
		if keyword in desc:
			return DIRECTION_KEYWORDS[keyword]
	return Vector2.ZERO


## Parse magnitude from description
func _parse_magnitude(desc: String) -> float:
	for keyword in MAGNITUDE_KEYWORDS:
		if keyword in desc:
			return MAGNITUDE_KEYWORDS[keyword]
	# Default magnitude if direction found but no explicit magnitude
	return 0.1

#endregion


#region Spatial Analysis

## Find the centroid of a group of components
func get_group_centroid(component_ids: Array) -> Vector2:
	if not data or component_ids.is_empty():
		return Vector2.ZERO

	var sum := Vector2.ZERO
	var count := 0

	for comp_id in component_ids:
		var comp := data.get_component(str(comp_id))
		if comp:
			sum += comp.position
			count += 1

	if count == 0:
		return Vector2.ZERO

	return sum / count


## Get the bounding box of a group of components
func get_group_bounds(component_ids: Array) -> Rect2:
	if not data or component_ids.is_empty():
		return Rect2()

	var first := true
	var min_pos := Vector2.ZERO
	var max_pos := Vector2.ZERO

	for comp_id in component_ids:
		var comp := data.get_component(str(comp_id))
		if comp:
			var bounds := comp.get_bounding_rect()
			if first:
				min_pos = bounds.position
				max_pos = bounds.end
				first = false
			else:
				min_pos.x = minf(min_pos.x, bounds.position.x)
				min_pos.y = minf(min_pos.y, bounds.position.y)
				max_pos.x = maxf(max_pos.x, bounds.end.x)
				max_pos.y = maxf(max_pos.y, bounds.end.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a position would cause component overlap
func would_overlap(component_id: String, new_position: Vector2, margin: float = 1.0) -> bool:
	if not data:
		return false

	var comp := data.get_component(component_id)
	if not comp:
		return false

	# Create hypothetical bounds at new position
	var new_bounds := Rect2(
		new_position - Vector2(comp.width / 2.0, comp.height / 2.0),
		Vector2(comp.width, comp.height)
	).grow(margin)

	for other_id in data.components:
		if other_id == component_id:
			continue
		var other: PCBComponentScript = data.components[other_id]
		if new_bounds.intersects(other.get_bounding_rect()):
			return true

	return false


## Suggest positions that avoid overlap
func suggest_non_overlapping_position(component_id: String, preferred_position: Vector2) -> Vector2:
	if not would_overlap(component_id, preferred_position):
		return preferred_position

	# Try offsetting in a spiral pattern
	var offsets := [
		Vector2(5, 0), Vector2(-5, 0), Vector2(0, 5), Vector2(0, -5),
		Vector2(5, 5), Vector2(-5, 5), Vector2(5, -5), Vector2(-5, -5),
		Vector2(10, 0), Vector2(-10, 0), Vector2(0, 10), Vector2(0, -10)
	]

	for offset in offsets:
		var test_pos: Vector2 = preferred_position + offset
		if data.is_within_bounds(test_pos) and not would_overlap(component_id, test_pos):
			return test_pos

	# If all fail, return snapped to grid at least
	return data.snap_to_grid(preferred_position)

#endregion
