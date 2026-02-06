class_name PCBRouteHint
extends RefCounted
## Represents a routing hint/suggestion for PCB traces.
## Can express everything from sparse waypoint hints to detailed bus routes.

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBRouteHint.gd")

## Type of routing hint
enum HintType {
	WAYPOINT,      # Just bend points, no specific pin mapping
	SINGLE_TRACE,  # One net, source to destination
	BUS            # Multiple parallel traces
}

## Level of detail provided
enum DetailLevel {
	SPARSE,        # Just key waypoints, AI figures out the rest
	GUIDED,        # General path corridor with waypoints
	DETAILED       # Complete trace path, just execute it
}

## Unique identifier
var id: String = ""

## Type of hint
var hint_type: HintType = HintType.SINGLE_TRACE

## How detailed is this hint
var detail_level: DetailLevel = DetailLevel.GUIDED

## Target layer (empty = unspecified, let router decide)
var layer: String = ""

## Trace width in mm (0 = unspecified, use default)
var width: float = 0.0

## Bus spacing in mm (0 = unspecified, use default)
var bus_spacing: float = 0.0

## Source pins - format: ["U1.15"] or ["U1.15", "U1.16", "U1.17"]
var source_pins: Array[String] = []

## Destination pins - format: ["U2.1"] or ["U2.1", "U2.2", "U2.3"]
var dest_pins: Array[String] = []

## Net names if known (optional)
var net_names: Array[String] = []

## Waypoints - meaning depends on detail_level
## SPARSE: key bend points only
## GUIDED: general corridor path
## DETAILED: complete trace path
var waypoints: Array[Vector2] = []

## Author of the hint
var author: String = "human"

## Additional freeform notes
var text: String = ""

## Timestamp when hint was created
var created_at: float = 0.0

## Display color
var color: Color = Color(0.2, 0.8, 0.6, 0.8)  # Teal for route hints

## Client-provided idempotency key (empty = no dedup)
var client_id: String = ""


## Create a waypoint-only hint (just bend points)
static func create_waypoint_hint(points: Array[Vector2], note: String = "", author_name: String = "human") -> PCBRouteHint:
	var hint := _Self.new()
	hint.id = _generate_id()
	hint.hint_type = HintType.WAYPOINT
	hint.detail_level = DetailLevel.SPARSE
	hint.waypoints = points.duplicate()
	hint.text = note
	hint.author = author_name
	hint.color = _get_author_color(author_name)
	hint.created_at = Time.get_unix_time_from_system()
	return hint


## Create a single trace hint
static func create_single_trace_hint(
	source_pin: String,
	dest_pin: String,
	points: Array[Vector2] = [],
	layer_name: String = "",
	trace_width: float = 0.0,
	note: String = "",
	author_name: String = "human"
) -> PCBRouteHint:
	var hint := _Self.new()
	hint.id = _generate_id()
	hint.hint_type = HintType.SINGLE_TRACE
	hint.source_pins = [source_pin]
	hint.dest_pins = [dest_pin]
	hint.waypoints = points.duplicate()
	hint.layer = layer_name
	hint.width = trace_width
	hint.text = note
	hint.author = author_name
	hint.color = _get_author_color(author_name)
	hint.created_at = Time.get_unix_time_from_system()

	# Determine detail level based on waypoints
	if points.is_empty():
		hint.detail_level = DetailLevel.SPARSE
	elif points.size() <= 3:
		hint.detail_level = DetailLevel.GUIDED
	else:
		hint.detail_level = DetailLevel.DETAILED

	return hint


## Create a bus routing hint
static func create_bus_hint(
	src_pins: Array[String],
	dst_pins: Array[String],
	points: Array[Vector2] = [],
	layer_name: String = "",
	trace_width: float = 0.0,
	spacing: float = 0.0,
	note: String = "",
	author_name: String = "human"
) -> PCBRouteHint:
	var hint := _Self.new()
	hint.id = _generate_id()
	hint.hint_type = HintType.BUS
	hint.source_pins = src_pins.duplicate()
	hint.dest_pins = dst_pins.duplicate()
	hint.waypoints = points.duplicate()
	hint.layer = layer_name
	hint.width = trace_width
	hint.bus_spacing = spacing
	hint.text = note
	hint.author = author_name
	hint.color = _get_author_color(author_name)
	hint.created_at = Time.get_unix_time_from_system()

	# Determine detail level
	if points.is_empty():
		hint.detail_level = DetailLevel.SPARSE
	elif points.size() <= 3:
		hint.detail_level = DetailLevel.GUIDED
	else:
		hint.detail_level = DetailLevel.DETAILED

	return hint


## Generate a unique ID
static func _generate_id() -> String:
	return "rhint_%s" % str(randi() % 1000000).pad_zeros(6)


## Get default color for author
static func _get_author_color(author_name: String) -> Color:
	if author_name == "human":
		return Color(0.2, 0.8, 0.6, 0.8)  # Teal for human hints
	else:
		return Color(0.6, 0.4, 0.9, 0.8)  # Purple for AI hints


## Get the bounding rectangle of this hint's waypoints
func get_bounding_rect() -> Rect2:
	if waypoints.is_empty():
		return Rect2()

	var min_pos := waypoints[0]
	var max_pos := waypoints[0]

	for pos in waypoints:
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.y)
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is near this hint (for hit testing)
func contains_point(point: Vector2, threshold: float = 3.0) -> bool:
	if waypoints.is_empty():
		return false

	# Check if near any waypoint
	for wp in waypoints:
		if wp.distance_to(point) <= threshold:
			return true

	# Check if near any line segment between waypoints
	if waypoints.size() >= 2:
		for i in range(waypoints.size() - 1):
			if _point_to_segment_distance(point, waypoints[i], waypoints[i + 1]) <= threshold:
				return true

	return false


## Calculate distance from point to line segment
func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	var seg := seg_end - seg_start
	var seg_len_sq := seg.length_squared()

	if seg_len_sq < 0.0001:
		return point.distance_to(seg_start)

	var t := clampf((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)
	var closest := seg_start + t * seg
	return point.distance_to(closest)


## Get the center point of the hint
func get_center() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO

	var center := Vector2.ZERO
	for pos in waypoints:
		center += pos
	return center / waypoints.size()


## Parse a pin reference like "U1.15" into component and pin
static func parse_pin_ref(pin_ref: String) -> Dictionary:
	var parts := pin_ref.split(".")
	if parts.size() >= 2:
		return {"component": parts[0], "pin": parts[1]}
	return {"component": "", "pin": ""}


## Format pin references for display
func get_source_pins_display() -> String:
	if source_pins.is_empty():
		return ""
	if source_pins.size() == 1:
		return source_pins[0]
	return "%s...%s" % [source_pins[0], source_pins[source_pins.size() - 1]]


func get_dest_pins_display() -> String:
	if dest_pins.is_empty():
		return ""
	if dest_pins.size() == 1:
		return dest_pins[0]
	return "%s...%s" % [dest_pins[0], dest_pins[dest_pins.size() - 1]]


## Get a human-readable description
func get_description() -> String:
	var type_name: String = HintType.keys()[hint_type]
	var detail_name: String = DetailLevel.keys()[detail_level]

	var desc := "[%s] %s %s" % [id, type_name, detail_name]

	if not source_pins.is_empty() and not dest_pins.is_empty():
		desc += ": %s → %s" % [get_source_pins_display(), get_dest_pins_display()]

	if not layer.is_empty():
		desc += " on %s" % layer

	if not text.is_empty():
		desc += " \"%s\"" % text.substr(0, 30)

	return desc


## Serialize to dictionary
func to_dict() -> Dictionary:
	var waypoints_arr: Array = []
	for wp in waypoints:
		waypoints_arr.append({"x": wp.x, "y": wp.y})

	return {
		"id": id,
		"hint_type": HintType.keys()[hint_type],
		"detail_level": DetailLevel.keys()[detail_level],
		"layer": layer,
		"width": width,
		"bus_spacing": bus_spacing,
		"source_pins": source_pins.duplicate(),
		"dest_pins": dest_pins.duplicate(),
		"net_names": net_names.duplicate(),
		"waypoints": waypoints_arr,
		"author": author,
		"text": text,
		"color": color.to_html(),
		"created_at": created_at,
		"client_id": client_id
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")

	var type_str: String = data.get("hint_type", "SINGLE_TRACE")
	var type_idx := HintType.keys().find(type_str)
	hint_type = type_idx as HintType if type_idx >= 0 else HintType.SINGLE_TRACE

	var detail_str: String = data.get("detail_level", "GUIDED")
	var detail_idx := DetailLevel.keys().find(detail_str)
	detail_level = detail_idx as DetailLevel if detail_idx >= 0 else DetailLevel.GUIDED

	layer = data.get("layer", "")
	width = data.get("width", 0.0)
	bus_spacing = data.get("bus_spacing", 0.0)

	source_pins.clear()
	var src_arr: Array = data.get("source_pins", [])
	for pin in src_arr:
		source_pins.append(str(pin))

	dest_pins.clear()
	var dst_arr: Array = data.get("dest_pins", [])
	for pin in dst_arr:
		dest_pins.append(str(pin))

	net_names.clear()
	var net_arr: Array = data.get("net_names", [])
	for net in net_arr:
		net_names.append(str(net))

	waypoints.clear()
	var wp_arr: Array = data.get("waypoints", [])
	for wp_data in wp_arr:
		if wp_data is Dictionary:
			waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))

	author = data.get("author", "human")
	text = data.get("text", "")

	var color_str: String = data.get("color", "")
	if not color_str.is_empty():
		color = Color.from_string(color_str, Color(0.2, 0.8, 0.6, 0.8))

	created_at = data.get("created_at", 0.0)
	client_id = data.get("client_id", "")


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary) -> PCBRouteHint:
	var hint := _Self.new()
	hint.load_from_dict(data)
	return hint
