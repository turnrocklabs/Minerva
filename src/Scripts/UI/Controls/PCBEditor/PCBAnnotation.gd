class_name PCBAnnotation
extends RefCounted
## Represents an annotation overlay on the PCB (arrows, text, regions, polylines).
## Used for human-AI collaboration: marking areas of interest, suggesting changes, etc.

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd")

## Types of annotations
enum AnnotationType {
	ARROW,     # Arrow from one point to another (2 positions: start, end)
	TEXT,      # Text note at a position (1 position + text)
	REGION,    # Rectangular highlight region (2 positions: top-left, bottom-right)
	POLYLINE   # Freeform path/line (N positions)
}

## Unique identifier for this annotation
var id: String = ""

## Type of annotation
var type: AnnotationType = AnnotationType.TEXT

## Positions defining the annotation (meaning depends on type)
## ARROW: [start, end]
## TEXT: [position]
## REGION: [corner1, corner2]
## POLYLINE: [point1, point2, ..., pointN]
var positions: Array[Vector2] = []

## Text content (for TEXT type, or label for others)
var text: String = ""

## Display color
var color: Color = Color(0.95, 0.5, 0.9)  # Light magenta default for human

## Author of the annotation
var author: String = "human"  # "human" or "ai"

## Timestamp when annotation was created
var created_at: float = 0.0

## Optional: associate with a specific component
var associated_component: String = ""

## Optional: associate with a specific net
var associated_net: String = ""


## Create an arrow annotation
static func create_arrow(start: Vector2, end: Vector2, label: String = "", author_name: String = "ai") -> PCBAnnotation:
	var annotation := _Self.new()
	annotation.id = _generate_id()
	annotation.type = AnnotationType.ARROW
	annotation.positions = [start, end]
	annotation.text = label
	annotation.author = author_name
	annotation.color = _get_author_color(author_name)
	annotation.created_at = Time.get_unix_time_from_system()
	return annotation


## Create a text annotation
static func create_text(position: Vector2, text_content: String, author_name: String = "ai") -> PCBAnnotation:
	var annotation := _Self.new()
	annotation.id = _generate_id()
	annotation.type = AnnotationType.TEXT
	annotation.positions = [position]
	annotation.text = text_content
	annotation.author = author_name
	annotation.color = _get_author_color(author_name)
	annotation.created_at = Time.get_unix_time_from_system()
	return annotation


## Create a region highlight annotation
static func create_region(corner1: Vector2, corner2: Vector2, label: String = "", author_name: String = "ai") -> PCBAnnotation:
	var annotation := _Self.new()
	annotation.id = _generate_id()
	annotation.type = AnnotationType.REGION
	annotation.positions = [corner1, corner2]
	annotation.text = label
	annotation.author = author_name
	annotation.color = _get_author_color(author_name)
	annotation.created_at = Time.get_unix_time_from_system()
	return annotation


## Create a polyline annotation
static func create_polyline(points: Array[Vector2], label: String = "", author_name: String = "ai") -> PCBAnnotation:
	var annotation := _Self.new()
	annotation.id = _generate_id()
	annotation.type = AnnotationType.POLYLINE
	annotation.positions = points.duplicate()
	annotation.text = label
	annotation.author = author_name
	annotation.color = _get_author_color(author_name)
	annotation.created_at = Time.get_unix_time_from_system()
	return annotation


## Generate a unique ID
static func _generate_id() -> String:
	return "ann_%s" % str(randi() % 1000000).pad_zeros(6)


## Get default color for author
static func _get_author_color(author_name: String) -> Color:
	if author_name == "human":
		return Color(0.95, 0.5, 0.9)  # Light magenta for human
	else:
		return Color(0.3, 0.7, 0.9)  # Cyan for AI


## Get the bounding rectangle of this annotation
func get_bounding_rect() -> Rect2:
	if positions.is_empty():
		return Rect2()

	var min_pos := positions[0]
	var max_pos := positions[0]

	for pos in positions:
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.y)
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is near this annotation (for hit testing)
func contains_point(point: Vector2, threshold: float = 2.0) -> bool:
	match type:
		AnnotationType.ARROW:
			return _point_near_line(point, threshold)
		AnnotationType.TEXT:
			# For text, use a small hit area around the position
			# Don't use oversized padding that overlaps with other annotations
			if positions.is_empty():
				return false
			return positions[0].distance_to(point) <= threshold + 3.0
		AnnotationType.REGION:
			var rect := get_bounding_rect()
			rect = rect.grow(threshold)
			return rect.has_point(point)
		AnnotationType.POLYLINE:
			return _point_near_polyline(point, threshold)
	return false


## Check if point is near a line segment (for arrow)
func _point_near_line(point: Vector2, threshold: float) -> bool:
	if positions.size() < 2:
		return false
	return _point_to_segment_distance(point, positions[0], positions[1]) <= threshold


## Check if point is near any segment of polyline
func _point_near_polyline(point: Vector2, threshold: float) -> bool:
	if positions.size() < 2:
		return positions.size() == 1 and positions[0].distance_to(point) <= threshold

	for i in range(positions.size() - 1):
		if _point_to_segment_distance(point, positions[i], positions[i + 1]) <= threshold:
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


## Get the center point of the annotation
func get_center() -> Vector2:
	if positions.is_empty():
		return Vector2.ZERO

	var center := Vector2.ZERO
	for pos in positions:
		center += pos
	return center / positions.size()


## Move the annotation by an offset
func translate(offset: Vector2) -> void:
	for i in range(positions.size()):
		positions[i] += offset


## Rotate the annotation around its center
func rotate_around_center(angle_radians: float) -> void:
	var center := get_center()
	for i in range(positions.size()):
		var relative := positions[i] - center
		positions[i] = center + relative.rotated(angle_radians)


## Scale the annotation from its center
func scale_from_center(scale_factor: float) -> void:
	var center := get_center()
	for i in range(positions.size()):
		var relative := positions[i] - center
		positions[i] = center + relative * scale_factor


## Invert arrow direction (swap start and end)
func invert_direction() -> void:
	if type == AnnotationType.ARROW and positions.size() >= 2:
		var temp := positions[0]
		positions[0] = positions[1]
		positions[1] = temp


## Serialize to dictionary
func to_dict() -> Dictionary:
	var positions_arr: Array = []
	for pos in positions:
		positions_arr.append({"x": pos.x, "y": pos.y})

	return {
		"id": id,
		"type": AnnotationType.keys()[type],
		"positions": positions_arr,
		"text": text,
		"color": color.to_html(),
		"author": author,
		"created_at": created_at,
		"associated_component": associated_component,
		"associated_net": associated_net
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")

	var type_str: String = data.get("type", "TEXT")
	var type_idx := AnnotationType.keys().find(type_str)
	type = type_idx if type_idx >= 0 else AnnotationType.TEXT

	positions.clear()
	var positions_data: Array = data.get("positions", [])
	for pos_data in positions_data:
		if pos_data is Dictionary:
			positions.append(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))

	text = data.get("text", "")

	var color_str: String = data.get("color", "")
	if not color_str.is_empty():
		color = Color.from_string(color_str, Color(0.9, 0.7, 0.2))

	author = data.get("author", "human")
	created_at = data.get("created_at", 0.0)
	associated_component = data.get("associated_component", "")
	associated_net = data.get("associated_net", "")


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary) -> PCBAnnotation:
	var annotation := _Self.new()
	annotation.load_from_dict(data)
	return annotation


## Get a human-readable description
func get_description() -> String:
	var type_name: String = AnnotationType.keys()[type]
	var desc: String = "%s [%s] by %s" % [id, type_name, author]
	if not text.is_empty():
		desc += ": \"%s\"" % text.substr(0, 50)
	return desc
