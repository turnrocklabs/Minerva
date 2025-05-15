class_name PaneTool
extends BaseTool

var hand_icon: = preload("res://assets/icons/drag_hand.png")
var dragging: = false
var last_mouse_position: Vector2 = Vector2.ZERO

# Infinite canvas support
var canvas_min_bounds: Vector2 = Vector2(-5000, -5000)  # Arbitrary large limits
var canvas_max_bounds: Vector2 = Vector2(5000, 5000)
# var background_grid: = preload("res://assets/textures/grid.png")  # Optional grid texture

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				editor.set_custom_cursor(hand_icon)
	)

func handle_input_event(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				dragging = true
				last_mouse_position = event.position
			else:
				dragging = false

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(event.position, 1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(event.position, 0.9)

	if event is InputEventMouseMotion:
		if dragging:
			# Pan all layers together
			var relative = event.position - last_mouse_position
			_pan_canvas(relative)
			last_mouse_position = event.position

func _pan_canvas(relative: Vector2) -> void:
	# Move all layers together for canvas panning
	for layer in editor.layers:
		layer.position += relative
	
	# Update canvas bounds
	_check_canvas_bounds()

func _zoom(mouse_position: Vector2, factor: float) -> void:
	# Calculate the combined center of all layers
	var center = Vector2.ZERO
	for layer in editor.layers:
		center += layer.position + layer.size * 0.5
	center /= max(1, editor.layers.size())
	
	# Zoom all layers together
	for layer in editor.layers:
		var old_pos = layer.position
		var old_size = layer.custom_minimum_size
		
		# Scale the layer
		layer.custom_minimum_size *= factor
		
		# Adjust position to keep the point under the mouse stable
		var mouse_offset = mouse_position - old_pos
		var new_mouse_offset = mouse_offset * factor
		layer.position = mouse_position - new_mouse_offset
	
	# Update canvas bounds
	_check_canvas_bounds()

func _check_canvas_bounds() -> void:
	# Check if we need to expand the canvas
	var min_pos = Vector2(INF, INF)
	var max_pos = Vector2(-INF, -INF)
	
	for layer in editor.layers:
		min_pos.x = min(min_pos.x, layer.position.x)
		min_pos.y = min(min_pos.y, layer.position.y)
		max_pos.x = max(max_pos.x, layer.position.x + layer.size.x)
		max_pos.y = max(max_pos.y, layer.position.y + layer.size.y)
	
	# Expand canvas bounds if needed
	if min_pos.x < canvas_min_bounds.x:
		canvas_min_bounds.x = min_pos.x - 1000  # Add extra space
	if min_pos.y < canvas_min_bounds.y:
		canvas_min_bounds.y = min_pos.y - 1000
	if max_pos.x > canvas_max_bounds.x:
		canvas_max_bounds.x = max_pos.x + 1000
	if max_pos.y > canvas_max_bounds.y:
		canvas_max_bounds.y = max_pos.y + 1000
	
	# Notify the editor to update the background grid
	_update_background_grid()

func _update_background_grid() -> void:
	# This function would update your background grid to cover the new canvas bounds
	# Implementation depends on how your background is handled
	pass
