class_name CloudControl
extends Control

## Radius of circles visualizing points in draw mode
const POINT_RADIUS: = 10

enum Type {
	ELLIPSE,
	CLOUD,
	RECTANGLE,
}
var type: = Type.ELLIPSE
var circle_radius
@onready var _lower_resizer: Control = %LowerBottomResizer
@onready var _upper_resizer: Control = %UpperLeftResizer
@onready var _text_edit: TextEdit = %TextEdit
@onready var _bezier_curve: BezierCurve = %BezierCurve


var _drag_start_position: Vector2
var _dragging: = false:
	set(value):
		_dragging = value
		_text_edit.mouse_filter = MOUSE_FILTER_IGNORE if _dragging else MOUSE_FILTER_STOP

## Font used to display text
var font: = ThemeDB.fallback_font

## Font size
var font_size: = ThemeDB.fallback_font_size

## In editing mode, wireframe of speech bubble and a text edit are displayed.[br]
## When not in editing mode the scene is rendered in final form.
var editing: = true:
	set(value):
		editing = value
		_text_edit.visible = editing
		_lower_resizer.visible = editing
		_upper_resizer.visible = editing
		_bezier_curve.visible = editing


## There are two control nodes that are used for resizing the speech bubble react.[br]
## This variable hold the active one during the drag.
var _active_resizer: Control

## Tail object defined by points.
## The type of the tail determines the way it's rendered on screen.
var tail: Tail

## Bounding rectange which contains the [member ellipse] that defines the speech bubble.
var _bubble_rect: Rect2

## Polygon that defines the speech bubble
var bubble_poly: PackedVector2Array


func set_bounding_rect(rect: Rect2) -> void:
	_upper_resizer.position = rect.position
	_lower_resizer.position = rect.end
	queue_redraw()

## Move the speech bubble center point relative to the control origin[br].
## Center point being the middle between the resizer nodes.
func move(to: Vector2):
	var current_offset = _upper_resizer.position - _lower_resizer.position

	_upper_resizer.position = to + current_offset / 2
	_lower_resizer.position = to - current_offset / 2
	


# region Tails

func _create_tail() -> PackedVector2Array:

	# Take the resizer control positions to create the rectange that will contain the speech bubble
	var rect_start: = _upper_resizer.position + _upper_resizer.pivot_offset
	var rect_size: = _lower_resizer.position + _lower_resizer.pivot_offset - rect_start

	_bubble_rect = Rect2(rect_start, rect_size)

	if type == Type.ELLIPSE:
			return create_ellipse(_bubble_rect)
	elif type == Type.CLOUD:
			return cloud_bubble(_bubble_rect)
	elif type == Type.RECTANGLE:
			return PackedVector2Array([
				_bubble_rect.position,
				_bubble_rect.position + Vector2(0, _bubble_rect.size.y),
				_bubble_rect.end,
				_bubble_rect.position + Vector2(_bubble_rect.size.x, 0),
			])
	
	else:
		push_error("Speech Bubble of type %s has no implementation inside the _create_tail method." % type)

	return PackedVector2Array()

class Tail:
	## Base class for all Tail types

	## Holds the control on which the tail should be rendered
	var control: CloudControl

	## Mixed type array of Vector2 and integers.[br]
	## If element is Vector2 it defines the fixed position of the point.[br]
	## If element is a integer, the point is attached to the [member CloudControl.ellipse],
	## and it defines the index of ellipse polygon point.[br]
	## Use [method get_points_vector_array] method to get them as [PackedVector2Array].
	var points: = []

	func _init(control_: CloudControl) -> void:
		control = control_
	
	func add_point(point) -> void:
		points.append(point)

	## Draws the final form of the tail.
	func draw() -> void:
		push_error("NotImplemented: method draw of object %s is not implemented" % get_script().resource_path.get_file())

	func get_polygon() -> PackedVector2Array:
		return get_points_vector_array()

	## Draws the tail in the editing form.
	func draw_editing() -> void:
		push_error("NotImplemented: method draw_editing of object %s is not implemented" % get_script().resource_path.get_file())

	## Returns [memeber Tail.points] where Vector2's are untouched
	## and integers are convertes to Vector2 in the context of the [member CloudControl.bubble_poly].
	func get_points_vector_array() -> PackedVector2Array:
		var points_: = PackedVector2Array()
		
		for p in points:
			if p is Vector2:
				points_.append(p)
			
			elif p is int:
				points_.append(control.bubble_poly[p])
			
			elif p is float:
				var total_distance: = control.get_point_distance(control.bubble_poly, control.bubble_poly.size()-1)
				var target_distance: float = total_distance / 100 * p
				var traveled: =  0.

				for i in control.bubble_poly.size():
					var a = control.bubble_poly[i]
					var b = control.bubble_poly[i+1 if i < control.bubble_poly.size()-1 else 0]

					var d = a.distance_to(b)

					if traveled + d > target_distance:
						points_.append(a)
						break

					traveled += d
			
			else:
				push_error("Unexpected type %s.", type_string(p))
		
		return points_


class TriangleTail:
	extends Tail

	func draw() -> void:

		var points_: = get_points_vector_array()

		if points_.size() < 3: return

		# To create a border effect we offset the polygon by negative delta
		# which will make it smaller and draw it on top of the original one
		control.draw_colored_polygon(points_.slice(0, 3), Color.BLACK)
		for poly in Geometry2D.offset_polygon(points_.slice(0, 3), -2):
			control.draw_colored_polygon(poly , Color.WHITE)

	func draw_editing() -> void:
		var points_ = get_points_vector_array()
		for point in points_:
			control.draw_circle(point, 10, Color.BLACK)
			control.draw_circle(point, 10, Color.DARK_ORANGE, false, 3)

		# Make the last point same as the first, so we get a connected polygon
		if points_.size() >= 2:
			if points_[0] != points_[-1]: points_.append(points_[0])
			control.draw_polyline(points_, Color.BLACK)

class CurvedTriangleTail:
	extends TriangleTail

	func add_point(point):
		super(point)
		
		var position = point if point is Vector2 else control.bubble_poly[point]
		control._bezier_curve.create_point(position)
	
	func get_polygon():
		var poly: = PackedVector2Array()

		for p in control._bezier_curve.calculate_polygons():
			poly.append_array(p)

		return poly
	
	func draw():
		var points_: Array[Vector2] = control._bezier_curve.points.map(func(p: BezierCurve.Point): return p.position)

		control.draw_colored_polygon(points_, Color.WHITE)

	func draw_editing() -> void:
		var points_ = get_points_vector_array()

		var bc_points: = control._bezier_curve.points

		for i in range(points_.size()):
			# TODO: control point should also move
			bc_points[i].position = points_[i]
			control._bezier_curve.queue_redraw()

		for point in points_:
			control.draw_circle(point, 10, Color.BLACK)
			control.draw_circle(point, 10, Color.DARK_ORANGE, false, 3)


class BubbleTail:
	extends Tail

	func draw() -> void:
		var points_: = get_points_vector_array()

		var current_area: = control._bubble_rect.get_area() / 16

		for point in points_:
			var radius: = sqrt(current_area / PI)
			control.draw_circle(point, radius, Color.WHITE)
			control.draw_circle(point, radius, Color.BLACK, false, 3)

			current_area /= 2

	func draw_editing() -> void:
		var points_ = get_points_vector_array()

		for point in points_:
			control.draw_circle(point, POINT_RADIUS, Color.BLACK)
			control.draw_circle(point, POINT_RADIUS, Color.DARK_ORANGE, false, 3)

		if points_.size() >= 2:
			control.draw_polyline(points_, Color.GREEN_YELLOW)

# endregion

# Request redraw in response to changes
func _ready():
	circle_radius = 50
	if SingletonObject.CloudType == Type.CLOUD:
		type = Type.CLOUD
	elif SingletonObject.CloudType == Type.ELLIPSE:
		type = Type.ELLIPSE
	elif SingletonObject.CloudType == Type.RECTANGLE:
		type = Type.RECTANGLE
		
	tail = CurvedTriangleTail.new(self)
	queue_redraw()



# When the node is not visible anymore, don't accept any input events anymore.
func _on_visibility_changed() -> void:
	set_process_input(is_visible_in_tree())
	set_process_unhandled_input(is_visible_in_tree())
	set_process_unhandled_key_input(is_visible_in_tree())
	set_process_shortcut_input(is_visible_in_tree())


func _draw() -> void:
	if editing:
		_draw_editing()
		return
		
	# Create a ellipse thats contained within the given rectangle
	bubble_poly = _create_tail()
	
	var polys := Geometry2D.merge_polygons(bubble_poly, tail.get_polygon())
	
	for poly in polys:
		draw_colored_polygon(Geometry2D.offset_polygon(poly, 3)[0], Color.BLACK)
		draw_colored_polygon(poly, Color.WHITE)
		
	# draw_polyline(ellipse, Color.BLACK, 7, true)
	
	# tail.draw()
	
	# Get the rectangle thats completly within the speech bubble ellipse
	# and defines the area there text can be in
	var text_rect: = get_rectangle_in_ellipse(_bubble_rect)
	
	# Draw the text from the text edit
	draw_multiline_string(
		font,
		text_rect.position + Vector2(0, font.get_ascent()),
		_text_edit.text,
		HORIZONTAL_ALIGNMENT_LEFT,
		text_rect.size.x,
		font_size,
		100,
		Color.BLACK,
		TextServer.BREAK_ADAPTIVE | TextServer.BREAK_WORD_BOUND
	)


func _draw_editing() -> void:
	bubble_poly = _create_tail()

	# what type of bubble
	draw_polyline(bubble_poly, Color.BLACK, 1)

	tail.draw_editing()

	var text_rect: = get_rectangle_in_ellipse(_bubble_rect)
	
	#draw_rect(text_rect, Color.ORANGE_RED)
	
	_text_edit.position = text_rect.position
	_text_edit.size = text_rect.size

	_draw_editing_tail()

## Visualizes where the point will be placed, if the user clicks the mouse button.[br]
## Mostly stays at the same position as the cursor, but if close to the ellipse polygon,
## will become attached to it, and add a int instead of fixed Vector2 position.
func _draw_editing_tail() -> void:
	# Get the mouse position relative to the CloudControl node
	var local_mouse_pos = get_local_mouse_position()
	
	var closest_point: = get_closest_polyline_position(bubble_poly, local_mouse_pos)

	if local_mouse_pos.distance_to(closest_point) < 60 and not Input.is_physical_key_pressed(KEY_SHIFT):
		draw_circle(closest_point, 4, Color.DEEP_PINK)
	else:
		draw_circle(local_mouse_pos, 4, Color.DEEP_PINK)


# region Input Handling

func _get_drag_data(at_position: Vector2) -> Variant:
	if (
		_upper_resizer.get_rect().has_point(at_position) or
		_lower_resizer.get_rect().has_point(at_position)
	): return null

	# Check if we pressed on existing tail point
	var points_arr: = tail.get_points_vector_array()

	for i in points_arr.size():
		var point: = points_arr[i]

		# if yes start dragging it
		if at_position.distance_to(point) < POINT_RADIUS:
			_drag_point_idx = i 
			return null


	if _bubble_rect.grow(15).has_point(at_position):
		_dragging = true
	

	return null

func _can_drop_data(_at_position: Vector2, _data: Variant) -> bool:
	return true

## Index of point inside the [member Tail.points] that the user is currently dragging
var _drag_point_idx: = -1

func _gui_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseMotion and event.pressure:
		_lower_resizer.position += event.relative
		_upper_resizer.position += event.relative
	else:
		_dragging = false

	if not editing: return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		
		if event.is_pressed():
			_drag_start_position = event.position
		
		# if the mouse is not pressed, disable the resizer and unset the `_drag_point_idx`
		else:
			_active_resizer = null
			_drag_point_idx = -1

			# if the mouse is released, check if we are on same place or we dragged the mouse

			if _drag_start_position.is_equal_approx(event.position):
				# if the mouse is pressed outside of the resizers
				if not (
					_upper_resizer.get_rect().has_point(event.position) or
					_lower_resizer.get_rect().has_point(event.position)
				):
					
					# if we didn't click on any points, add a new one
					if _drag_point_idx == -1:
						# var closest_point: = get_closest_polyline_position(bubble_poly, event.position)

						var idx: = get_closest_ellipse_line(event.position)

						var closest_point = bubble_poly[idx]

						if event.position.distance_to(closest_point) < 60 and not Input.is_physical_key_pressed(KEY_SHIFT):
							# var ratio: = get_closest_point_distance_ratio(bubble_poly, closest_point)
							tail.add_point(idx)
						else:
							tail.add_point(event.position)

			queue_redraw()
			accept_event()
	
	if event is InputEventMouseMotion:
		# if we're dragging the resizer, move it to the mouse position
		if _active_resizer:
			# var offset: Vector2 = event.relative

			var estimated_position = _active_resizer.position + event.relative

			# lower resizer can't be above the upper one
			if _active_resizer == _lower_resizer:
				if estimated_position.x < _upper_resizer.position.x:
					estimated_position.x = _upper_resizer.position.x

				if estimated_position.y < _upper_resizer.position.y:
					estimated_position.y = _upper_resizer.position.y
			# and upper can't be under the lower one
			elif _active_resizer == _upper_resizer:
				if estimated_position.x > _lower_resizer.position.x:
					estimated_position.x = _lower_resizer.position.x

				if estimated_position.y > _lower_resizer.position.y:
					estimated_position.y = _lower_resizer.position.y
			
			_active_resizer.position = estimated_position
			

			
			
		# if we're moving the mouse, pressing the mouse button and dragging the point
		# update that points position.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and _drag_point_idx != -1:
			# var closest_point: = get_closest_polyline_position(bubble_poly, event.position)

			var idx: = get_closest_ellipse_line(event.position)

			var closest_point = bubble_poly[idx]

			if event.position.distance_to(closest_point) < 60 and not Input.is_physical_key_pressed(KEY_SHIFT):
				# var ratio: = get_closest_point_distance_ratio(bubble_poly, closest_point)
				tail.points[_drag_point_idx] = idx
			else:
				tail.points[_drag_point_idx] = event.position
			
		queue_redraw()
		accept_event()

## If we press enter, switch between editing states
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and not _active_resizer:
		if event.keycode == KEY_ENTER and event.is_pressed():
			editing = not editing
			get_viewport().set_input_as_handled()
			queue_redraw()

func _on_lower_bottom_resizer_button_down() -> void:
	_active_resizer = _lower_resizer
	get_viewport().set_input_as_handled()

func _on_upper_left_resizer_button_down() -> void:
	_active_resizer = _upper_resizer
	get_viewport().set_input_as_handled()
# endregion


# region Speech Bubble

func cloud_bubble(rect: Rect2) -> PackedVector2Array:
	var ellipse_poly: = create_ellipse(rect)

	var cloud: = ellipse_poly.duplicate()
	
	var last_point: = -1
	for i in ellipse_poly.size():
		var point: = ellipse_poly[i]

		if last_point == -1:
			var circle: = create_circle(point, circle_radius)
			cloud = Geometry2D.merge_polygons(cloud, circle).front()
			last_point = i
			continue
		
		elif ellipse_poly[last_point].distance_to(point) > circle_radius * 0.8:
			var prev_point: = ellipse_poly[last_point-1]
			var circle: = create_circle(prev_point, circle_radius)
			cloud = Geometry2D.merge_polygons(cloud, circle).front()
			last_point = i
			continue
		
		elif i == ellipse_poly.size()-1:
			if point.distance_squared_to(ellipse_poly[0]) > circle_radius * 0.8:
				var circle: = create_circle(ellipse_poly[0], circle_radius)
				cloud = Geometry2D.merge_polygons(cloud, circle).front()

	return cloud

# endregion


# Function to create an ellipse inside a rectangle defined by Rect2
func create_ellipse(rect: Rect2, num_segments: int = 360) -> PackedVector2Array:
	var ellipse_points = PackedVector2Array()
	
	# Calculate the center and radii of the ellipse
	var center = rect.position + rect.size / 2
	var radius_x = rect.size.x / 2
	var radius_y = rect.size.y / 2
	
	# Generate the points for the ellipse
	for i in range(num_segments):
		var angle = (PI * 2 * i) / num_segments
		var x = center.x + radius_x * cos(angle)
		var y = center.y + radius_y * sin(angle)
		ellipse_points.append(Vector2(x, y))
	
	ellipse_points.append(ellipse_points[0])

	return ellipse_points

func create_circle(center: Vector2, radius: float, resolution: int = 32) -> PackedVector2Array:
	var circle: = PackedVector2Array()

	for i in range(resolution):
		var angle = TAU * i / resolution # TAU is 2π
		var x = radius * cos(angle)
		var y = radius * sin(angle)
		circle.append(center + Vector2(x, y))

	return circle

# Function to generate a Bézier curve with variable control points
func get_bezier_curve(p1: Vector2, p2: Vector2, control_points: Array, steps: int) -> PackedVector2Array:
	var bezier_curve = PackedVector2Array()
	
	for i in range(steps + 1):
		var t = i / float(steps)
		var current_points = [p1] + control_points + [p2]
		
		# De Casteljau's algorithm to recursively calculate the Bézier curve
		while current_points.size() > 1:
			var next_points = []
			for j in range(current_points.size() - 1):
				next_points.append(current_points[j].lerp(current_points[j + 1], t))
			current_points = next_points
		
		bezier_curve.append(current_points[0])
	
	return bezier_curve


## Gets biggest possible rectangle thats completly contained withing the ellipse.[br]
## Ellipse is defined by the smallest rectange that containes it. 
func get_rectangle_in_ellipse(rect: Rect2) -> Rect2:
	# Calculate the center of the ellipse
	var center = rect.position + rect.size / 2
	
	# Calculate the radii of the ellipse
	var radius_x = rect.size.x / 2
	var radius_y = rect.size.y / 2

	# Calculate the width and height of the rectangle that fits within the ellipse
	var rect_width = sqrt(2) * radius_x
	var rect_height = sqrt(2) * radius_y

	# Calculate the top-left corner of the rectangle
	var top_left = center - Vector2(rect_width / 2, rect_height / 2)

	# Create and return the Rect2
	return Rect2(top_left, Vector2(rect_width, rect_height))


## @experimental
## Simmilar to [method get_rectangle_in_ellipse], but retruned array of [parameter num_slices] rectangles,
## that tries to fill the ellipse as much as possible.[br]
## Calling this with [parameter num_slices] set to 1 should yield same results as [method get_rectangle_in_ellipse].
func get_rectangles_in_ellipse(rect: Rect2, num_slices: int = 4) -> Array:
	var rectangles = []
	
	# Calculate the center and radii of the ellipse
	var center = rect.end / 2
	var radius_x = rect.size.x / 2
	var radius_y = rect.size.y / 2
	
	# Divide the ellipse into horizontal slices
	var slice_height = rect.size.y / num_slices
	
	for i in range(num_slices):
		# Calculate the y-position of the current slice's center
		var y_center = rect.position.y + (i + 0.5) * slice_height
		var y_distance_from_center = abs(y_center - center.y)
		
		# Calculate the x-radius at the current y-position
		var current_radius_x = radius_x * sqrt(1 - pow(y_distance_from_center / radius_y, 2))
		
		var rect_width = 2 * current_radius_x	
		
		# Calculate the top-left corner of the rectangle for this slice
		var top_left = Vector2(center.x - current_radius_x, y_center - slice_height / 2)
		
		# Add the rectangle to the list
		rectangles.append(Rect2(top_left, Vector2(rect_width, slice_height)))
	
	return rectangles

## Given the [parameter mouse_position] returnes the closest point to it on the ellipse.
func get_closest_ellipse_line(mouse_position: Vector2) -> int:
	if bubble_poly.is_empty(): return -1

	var idx = -1

	for i in bubble_poly.size():
		var a = bubble_poly[i]
		# var b = ellipse[i+1]

		if idx == -1 or mouse_position.distance_squared_to(a) < mouse_position.distance_squared_to(bubble_poly[idx]):
			idx = i

	return idx


func get_closest_point_distance_ratio(polygon: PackedVector2Array, pos: Vector2) -> float:
	var total_length: = 0.0
	var length: = -1.

	for i in polygon.size():
		var a = polygon[i]
		var b = polygon[i+1 if i < polygon.size()-1 else 0]

		total_length += a.distance_to(b)

		if length > -1: continue

		prints(a, b, pos)
		if is_point_between(a, b, pos):
			
			length = total_length + a.distance_to(pos)
	
	prints(total_length, 100,  length)

	return total_length / 100 * length


func get_closest_polyline_position(polygon: PackedVector2Array, pos: Vector2) -> Vector2:
	var closest: Vector2

	for i in polygon.size():
		var a = polygon[i]
		var b = polygon[i+1 if i < polygon.size()-1 else 0]

		var cpts: = Geometry2D.get_closest_point_to_segment(pos, a, b)
		if pos.distance_squared_to(cpts) < pos.distance_squared_to(closest):
			closest = cpts
	
	return closest

	


func get_point_distance(polygon: PackedVector2Array, to: int, from: int = 0) -> float:
	var distance: = 0.0

	for i in range(from, polygon.size()):
		var point_a: = polygon[i]
		var point_b: = polygon[i+1 if i < polygon.size()-1 else 0]

		distance += point_a.distance_to(point_b)
		
		if i == to: break
	
	return distance


func is_point_between(A: Vector2, B: Vector2, C: Vector2) -> bool:
	# Calculate vectors AB and AC
	var AB = B - A
	var AC = C - A
	
	# Check if the points are collinear by using the cross product
	# If the cross product is zero, then the points are collinear
	if AB.cross(AC) != 0:
		return false
	
	# Check if point C is within the bounds of A and B
	# For collinear points, C should satisfy:
	# min(A.x, B.x) <= C.x <= max(A.x, B.x)
	# min(A.y, B.y) <= C.y <= max(A.y, B.y)
	return (
		min(A.x, B.x) <= C.x <= max(A.x, B.x) and
		min(A.y, B.y) <= C.y <= max(A.y, B.y)
	)

# Function to toggle editing state without event input
func toggle_editing_state() -> void:
	if not _active_resizer:
		editing = not editing
		queue_redraw()

func set_circle_radius(new_radius: float) -> void:
	circle_radius = new_radius
	cloud_bubble(_bubble_rect) # Recalculate the cloud shape
	queue_redraw() # Tell Godot to redraw the CloudControl 
	
	
func CancleEditing():
	editing = not editing
	queue_redraw()

func ApplyEditing():
	editing = false
	queue_redraw()
