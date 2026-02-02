class_name PCBTrace
extends RefCounted
## Represents a copper trace (routed connection) on the PCB.

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBTrace.gd")

## Unique identifier for this trace
var id: String = ""

## Net name this trace belongs to
var net_name: String = ""

## Waypoints defining the trace path (polyline in mm)
var waypoints: Array[Vector2] = []

## Trace width in mm (common values: 0.15, 0.2, 0.25, 0.3, 0.5, 1.0)
var width: float = 0.25

## Layer: "top", "bottom", or inner layer names
var layer: String = "top"

## Whether this trace is locked from editing
var locked: bool = false


## Add a waypoint to the trace
func add_waypoint(point: Vector2) -> void:
	waypoints.append(point)


## Insert a waypoint at a specific index
func insert_waypoint(index: int, point: Vector2) -> void:
	if index >= 0 and index <= waypoints.size():
		waypoints.insert(index, point)


## Remove a waypoint by index
func remove_waypoint(index: int) -> void:
	if index >= 0 and index < waypoints.size():
		waypoints.remove_at(index)


## Clear all waypoints
func clear_waypoints() -> void:
	waypoints.clear()


## Get the starting point of the trace
func get_start() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO
	return waypoints[0]


## Get the ending point of the trace
func get_end() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO
	return waypoints[waypoints.size() - 1]


## Calculate the total length of the trace
func get_length() -> float:
	if waypoints.size() < 2:
		return 0.0

	var total := 0.0
	for i in range(waypoints.size() - 1):
		total += waypoints[i].distance_to(waypoints[i + 1])
	return total


## Get the bounding rectangle of the trace
func get_bounding_rect() -> Rect2:
	if waypoints.is_empty():
		return Rect2()

	var min_pos := waypoints[0]
	var max_pos := waypoints[0]

	for point in waypoints:
		min_pos.x = minf(min_pos.x, point.x)
		min_pos.y = minf(min_pos.y, point.y)
		max_pos.x = maxf(max_pos.x, point.x)
		max_pos.y = maxf(max_pos.y, point.y)

	# Account for trace width
	var half_width := width / 2.0
	min_pos -= Vector2(half_width, half_width)
	max_pos += Vector2(half_width, half_width)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is near this trace (within threshold distance)
func is_point_near(point: Vector2, threshold: float = 0.5) -> bool:
	var effective_threshold := threshold + width / 2.0

	for i in range(waypoints.size() - 1):
		var dist := _point_to_segment_distance(point, waypoints[i], waypoints[i + 1])
		if dist <= effective_threshold:
			return true

	return false


## Get the closest point on the trace to a given point
func get_closest_point(point: Vector2) -> Vector2:
	if waypoints.is_empty():
		return point

	if waypoints.size() == 1:
		return waypoints[0]

	var closest := waypoints[0]
	var min_dist := INF

	for i in range(waypoints.size() - 1):
		var segment_closest := _closest_point_on_segment(point, waypoints[i], waypoints[i + 1])
		var dist := point.distance_to(segment_closest)
		if dist < min_dist:
			min_dist = dist
			closest = segment_closest

	return closest


## Calculate distance from point to line segment
func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	return point.distance_to(_closest_point_on_segment(point, seg_start, seg_end))


## Find the closest point on a line segment to a given point
func _closest_point_on_segment(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> Vector2:
	var seg := seg_end - seg_start
	var seg_len_sq := seg.length_squared()

	if seg_len_sq < 0.0001:
		return seg_start

	var t := clampf((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)
	return seg_start + t * seg


## Find the segment index closest to a point
func get_closest_segment_index(point: Vector2) -> int:
	if waypoints.size() < 2:
		return -1

	var best_idx := 0
	var min_dist := INF

	for i in range(waypoints.size() - 1):
		var dist := _point_to_segment_distance(point, waypoints[i], waypoints[i + 1])
		if dist < min_dist:
			min_dist = dist
			best_idx = i

	return best_idx


## Create a deep copy of this trace
func duplicate_trace():
	var copy := _Self.new()
	copy.id = id
	copy.net_name = net_name
	copy.width = width
	copy.layer = layer
	copy.locked = locked

	for wp in waypoints:
		copy.waypoints.append(wp)

	return copy


## Serialize to dictionary
func to_dict() -> Dictionary:
	var waypoints_arr: Array = []
	for wp in waypoints:
		waypoints_arr.append({"x": wp.x, "y": wp.y})

	return {
		"id": id,
		"net_name": net_name,
		"waypoints": waypoints_arr,
		"width": width,
		"layer": layer,
		"locked": locked
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")
	net_name = data.get("net_name", "")
	width = data.get("width", 0.25)
	layer = data.get("layer", "top")
	locked = data.get("locked", false)

	waypoints.clear()
	var waypoints_data: Array = data.get("waypoints", [])
	for wp_data in waypoints_data:
		if wp_data is Dictionary:
			waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary):
	var trace := _Self.new()
	trace.load_from_dict(data)
	return trace


## Get a human-readable description
func get_description() -> String:
	return "%s: %s on %s layer, %d segments, %.2fmm wide, %.2fmm long" % [
		id, net_name, layer, maxi(0, waypoints.size() - 1), width, get_length()
	]
