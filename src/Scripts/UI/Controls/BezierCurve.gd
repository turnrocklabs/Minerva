class_name BezierCurve
extends Control

const POINT_RADIUS := 10
const BEZIER_STEPS := 60

var points: Array[Point] = []

## Whether adding new points via clicking is allowed.[br]
## If disabled, points can only be added through code.
@export var allow_gui_add: = true

class Point:
	var position: Vector2
	var control_point_out: Vector2
	var control_point_in: Vector2
	
	func _init(pos: Vector2) -> void:
		position = pos
		control_point_out = pos
		control_point_in = pos

var _dragged_point: Point
var _dragged_control: String  # "in" or "out"


func create_point(pos: Vector2) -> Point:
	var new_point = Point.new(pos)
	if points.size() > 0:
		var prev_point = points[-1]
		var direction = (pos - prev_point.position).normalized()
		var third_distance = prev_point.position.distance_to(pos) / 3.0
		prev_point.control_point_out = prev_point.position + direction * third_distance
		new_point.control_point_in = new_point.position - direction * third_distance
	points.append(new_point)
	queue_redraw()
	return new_point

func calculate_polygons() -> Array[PackedVector2Array]:
	var curves: Array[PackedVector2Array] = []
	if points.size() > 1:
		for i in range(points.size() - 1):
			var start = points[i]
			var end = points[i + 1]
			var bezier_curve = get_cubic_bezier_curve(
				start.position, start.control_point_out,
				end.control_point_in, end.position,
				BEZIER_STEPS
			)
			curves.append(bezier_curve)

	return curves


func _draw() -> void:
	for i in range(points.size()):
		var point = points[i]
		draw_circle(point.position, POINT_RADIUS, Color.WHITE)
		draw_circle(point.control_point_out, POINT_RADIUS, Color.AQUA)
		draw_circle(point.control_point_in, POINT_RADIUS, Color.AQUA)
		draw_line(point.position, point.control_point_out, Color.GRAY, 1)
		draw_line(point.position, point.control_point_in, Color.GRAY, 1)

	for bezier_curve in calculate_polygons():
		draw_polyline(bezier_curve, Color.BLACK, 2)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var click_pos = event.position
			_dragged_point = null
			_dragged_control = ""

			for point in points:
				if click_pos.distance_to(point.position) < POINT_RADIUS and allow_gui_add:
					_dragged_point = point
					accept_event()
					return
				if click_pos.distance_to(point.control_point_out) < POINT_RADIUS:
					_dragged_point = point
					_dragged_control = "out"
					accept_event()
					return
				if click_pos.distance_to(point.control_point_in) < POINT_RADIUS:
					_dragged_point = point
					_dragged_control = "in"
					accept_event()
					return

			if allow_gui_add:
				create_point(click_pos)
				accept_event()
				queue_redraw()
		else:
			_dragged_point = null
			_dragged_control = ""

	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if _dragged_point:
			if _dragged_control == "out":
				_dragged_point.control_point_out = event.position
				accept_event()
			elif _dragged_control == "in":
				_dragged_point.control_point_in = event.position
				accept_event()
			elif allow_gui_add:
				var delta = event.position - _dragged_point.position
				_dragged_point.position = event.position
				_dragged_point.control_point_out += delta
				_dragged_point.control_point_in += delta
			
			queue_redraw()

static func get_cubic_bezier_curve(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, steps: int) -> PackedVector2Array:
	var curve = PackedVector2Array()
	for i in range(steps + 1):
		var t = float(i) / steps
		var q0 = p0.lerp(p1, t)
		var q1 = p1.lerp(p2, t)
		var q2 = p2.lerp(p3, t)
		var r0 = q0.lerp(q1, t)
		var r1 = q1.lerp(q2, t)
		var point = r0.lerp(r1, t)
		curve.append(point)
	return curve
