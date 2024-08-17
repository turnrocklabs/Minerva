class_name CloudControl
extends Control

## Radius of circles visualizing points in draw mode
const POINT_RADIUS: = 10

@onready var _lower_resizer: Control = %LowerBottomResizer
@onready var _upper_resizer: Control = %UpperLeftResizer
@onready var _text_edit: TextEdit = %TextEdit

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


## There are two control nodes that are used for resizing the speech bubble react.[br]
## This variable hold the active one during the drag.
var _active_resizer: Control

## Tail object defined by points.
## The type of the tail determines the way it's rendered on screen.
var tail: Tail

## Bounding rectange which contains the [member ellipse] that defines the speech bubble.
var _bubble_rect: Rect2

## Polygon that defines the speech bubble
var ellipse: PackedVector2Array


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

	## Draws the final form of the tail.
	func draw() -> void:
		push_error("NotImplemented: method draw of object %s is not implemented" % get_script().resource_path.get_file())

	## Draws the tail in the editing form.
	func draw_editing() -> void:
		push_error("NotImplemented: method draw_editing of object %s is not implemented" % get_script().resource_path.get_file())

	## Returns [memeber Tail.points] where Vector2's are untouched
	## and integers are convertes to Vector2 in the context of the [member CloudControl.ellipse].
	func get_points_vector_array() -> PackedVector2Array:
		var points_: = PackedVector2Array()
		
		for p in points:
			if p is Vector2:
				points_.append(p)
			
			elif p is int:
				points_.append(control.ellipse[p])
			
			else:
				push_error("Unexpected type %s.", type_string(p))
		
		return points_


class TriangleTail:
	extends Tail

	func draw() -> void:

		var points_: = get_points_vector_array()

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



# Request redraw in response to changes
func _ready():
	tail = TriangleTail.new(self)
	queue_redraw()


func _draw() -> void:
	if editing:
		_draw_editing()
		return
	
	# Take the resizer control positions to create the rectange that will contain the speech bubble
	var rect_start: = _upper_resizer.position + _upper_resizer.pivot_offset
	var rect_size: = _lower_resizer.position + _lower_resizer.pivot_offset - rect_start

	_bubble_rect = Rect2(rect_start, rect_size)

	# Create a ellipse thats contained within the given rectangle
	ellipse = create_ellipse(_bubble_rect)

	draw_colored_polygon(Geometry2D.convex_hull(ellipse), Color.WHITE)
	draw_polyline(ellipse, Color.BLACK, 7, true)
	
	tail.draw()


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
	var rect_start: = _upper_resizer.position + _upper_resizer.pivot_offset
	var rect_size: = _lower_resizer.position + _lower_resizer.pivot_offset - rect_start
	
	_bubble_rect = Rect2(rect_start, rect_size)

	ellipse = create_ellipse(_bubble_rect)

	draw_polyline(ellipse, Color.BLACK, 1)

	tail.draw_editing()

	var text_rect: = get_rectangle_in_ellipse(_bubble_rect)
	
	draw_rect(text_rect, Color.ORANGE_RED)
	
	_text_edit.position = text_rect.position
	_text_edit.size = text_rect.size

	_draw_editing_tail()

## Visualizes where the point will be placed, if the user clicks the mouse button.[br]
## Mostly stays at the same position as the cursor, but if close to the ellipse polygon,
## will become attached to it, and add a int instead of fixed Vector2 position.
func _draw_editing_tail() -> void:
	# Get the mouse position relative to the CloudControl node
	var local_mouse_pos = get_local_mouse_position()  
	
	var closest_point := ellipse[get_closest_ellipse_line(local_mouse_pos)]
	if local_mouse_pos.distance_to(closest_point) < 60:
		draw_circle(closest_point, 4, Color.DEEP_PINK)
	else:
		draw_circle(local_mouse_pos, 4, Color.DEEP_PINK) 
# region Input Handling

## Index of point inside the [member Tail.points] that the user is currently dragging
var _drag_point_idx: = -1

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# if the mouse is not pressed, disable the resizer and unset the `_drag_point_idx`
		if not event.is_pressed():
			_active_resizer = null
			_drag_point_idx = -1
		
		# if the mouse is pressed
		else:
			# Check if we pressed on existing tail point
			var points_arr: = tail.get_points_vector_array()

			for i in points_arr.size():
				var point: = points_arr[i]

				# if yes start dragging it
				if event.position.distance_to(point) < POINT_RADIUS:
					_drag_point_idx = i 
			
			# if we didn't click on any points, add a new one
			if _drag_point_idx == -1:
				var idx = get_closest_ellipse_line(event.position)

				var closest_point = ellipse[idx]

				if event.position.distance_to(closest_point) < 60:
					tail.points.append(idx)
				else:
					tail.points.append(event.position)

			queue_redraw() 

	if event is InputEventMouseMotion:
		# if we're dragging the resizer, move it to the mouse position
		if _active_resizer:
			_active_resizer.position += event.relative
		
		# if we're moving the mouse, pressing the mouse button and dragging the point
		# update that points position.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and _drag_point_idx != -1:
			var idx = get_closest_ellipse_line(event.position)

			var closest_point = ellipse[idx]

			if event.position.distance_to(closest_point) < 60:
				tail.points[_drag_point_idx] = idx
			else:
				tail.points[_drag_point_idx] = event.position
			
		queue_redraw()

## If we press enter, switch between editing states
func _input(event: InputEvent) -> void:
	if event is InputEventKey and not _active_resizer:
		if event.keycode == KEY_ENTER and event.is_pressed():
			editing = not editing
			queue_redraw()

func _on_lower_bottom_resizer_button_down() -> void:
	_active_resizer = _lower_resizer
	get_viewport().set_input_as_handled()

func _on_upper_left_resizer_button_down() -> void:
	_active_resizer = _upper_resizer
	get_viewport().set_input_as_handled()

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
	if ellipse.is_empty(): return -1

	var idx = -1

	for i in ellipse.size():
		var a = ellipse[i]
		# var b = ellipse[i+1]

		if idx == -1 or mouse_position.distance_squared_to(a) < mouse_position.distance_squared_to(ellipse[idx]):
			idx = i

	return idx
