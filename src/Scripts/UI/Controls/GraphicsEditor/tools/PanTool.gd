class_name PanTool
extends BaseTool

var hand_icon: = preload("res://assets/icons/drag_hand.png")
var dragging: = false
var last_mouse_position: Vector2 = Vector2.ZERO
var drag_start_position: Vector2 = Vector2.ZERO # Not directly used for continuous rotation angle, but good to keep for drag start

# Infinite canvas support
var canvas_min_bounds: Vector2 = Vector2(-5000, -5000)  # Arbitrary large limits
var canvas_max_bounds: Vector2 = Vector2(5000, 5000)

# For rotation
var rotation_center: Vector2 = Vector2.ZERO # The global pivot of the layer, converted to editor's local space
var is_rotating: bool = false
const ROTATION_THRESHOLD: float = 0.005  # Minimum angular change to trigger rotation (in radians)
const ROTATION_SENSITIVITY: float = 1.0  # How fast layer rotation responds to mouse angular movement (1.0 = 1:1)
const MIN_DISTANCE_FROM_ROT_CENTER: float = 15.0 # Mouse must be at least this far from center to detect rotation reliably

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				editor.set_custom_cursor(hand_icon)
	)


func handle_input_event(event: InputEvent) -> bool:
	# Consume mouse wheel events for zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(event.position, editor.ZOOM_INCREMENT)
			return true
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(event.position, editor.ZOOM_DECREMENT)
			return true
		
		# Handle left-click for drag start/end
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				dragging = true
				drag_start_position = event.position # Store initial drag start position
				last_mouse_position = event.position # Store initial last position for delta calculation
				is_rotating = false
				
				# Determine rotation center: active layer's pivot, converted to editor's local coordinates
				if editor.active_layer:
					var layer_global_rect = editor.active_layer.get_global_rect()
					# Convert layer's global center (pivot point) to the editor's local input area coordinates
					rotation_center = editor.get_global_transform().affine_inverse() * (layer_global_rect.position + editor.active_layer.pivot_offset)
				else:
					# If no active layer, rotation center defaults to the initial click position
					rotation_center = event.position
				return true # Consume event on press to prevent other handlers from interfering
			else:
				dragging = false
				is_rotating = false
				return true # Consume event on release to prevent other tools from acting
	
	# Handle mouse motion for pan/rotate
	if event is InputEventMouseMotion:
		if dragging:
			var current_mouse_position = event.position
			
			var angular_change = 0.0
			if editor.active_layer:
				angular_change = _calculate_rotation_angle_delta(last_mouse_position, current_mouse_position, rotation_center)
			
			if abs(angular_change) > ROTATION_THRESHOLD:
				# Circular motion detected - rotate the layer
				is_rotating = true
				editor.active_layer.rotation += angular_change * ROTATION_SENSITIVITY
				
				# When rotating, don't pan. Just update last_mouse_position to current
				# to prevent a pan "jump" when rotation stops.
				last_mouse_position = current_mouse_position 
				return true # Consume the event
			else:
				is_rotating = false
			
			# Normal panning (only if not currently rotating)
			if not is_rotating:
				var relative_motion = current_mouse_position - last_mouse_position
				_pan_canvas(relative_motion)
				last_mouse_position = current_mouse_position
				return true # Consume the event
	
	return false # Event not handled by PanTool

# Calculates the signed angle between two mouse positions relative to a center point.
# This implements the core rotation logic from the C++ snippet.
func _calculate_rotation_angle_delta(prev_pos: Vector2, curr_pos: Vector2, center: Vector2) -> float:
	var vec_prev_to_mouse = prev_pos - center
	var vec_curr_to_mouse = curr_pos - center
	
	# Filter out if mouse is too close to the rotation center (can cause erratic angles)
	if vec_prev_to_mouse.length() < MIN_DISTANCE_FROM_ROT_CENTER or vec_curr_to_mouse.length() < MIN_DISTANCE_FROM_ROT_CENTER:
		return 0.0
	
	# Get normalized vectors from center to mouse positions
	var normalized_vec_prev = vec_prev_to_mouse.normalized()
	var normalized_vec_curr = vec_curr_to_mouse.normalized()
	
	# Calculate the smallest signed angle between these two normalized vectors
	var angle_delta = normalized_vec_prev.angle_to(normalized_vec_curr)
	
	return angle_delta

func _pan_canvas(relative: Vector2) -> void:
	if editor == null:
		return
	editor._pan_canvas(relative)

func _zoom(mouse_position: Vector2, factor: float) -> void:
	if editor == null:
		return
	editor._zoom(mouse_position, factor)

# _check_canvas_bounds is not relevant to PanTool's direct rotation logic
# and is not called from within this tool.
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
