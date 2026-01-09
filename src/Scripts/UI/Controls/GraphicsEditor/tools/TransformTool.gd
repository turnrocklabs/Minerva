class_name TransformTool
extends BaseTool

enum TransformMode { RESIZE, MOVE, ROTATE }

# Rotate cursor icon
var _rotate_cursor_image: ImageTexture = null

var _control_point_type: int = LayerV2.TransformPoint.NONE
var _current_operation: TransformMode = TransformMode.MOVE
var _is_transforming: bool = false

# Original state for transforms
var _original_image: Image = null
var _first_original_image: Image = null  # Store first original for quality preservation
var _original_dimensions: Vector2 = Vector2.ZERO
var _first_original_dimensions: Vector2 = Vector2.ZERO

# Position tracking
var _drag_start_global_pos: Vector2 = Vector2.ZERO
var _initial_click_position: Vector2 = Vector2.ZERO
var _layer_start_position: Vector2 = Vector2.ZERO
var _layer_start_size: Vector2 = Vector2.ZERO
var _layer_start_rotation: float = 0.0
var _rotation_center: Vector2 = Vector2.ZERO
var _last_mouse_position: Vector2 = Vector2.ZERO  # For rotation angle calculation

# Rotation constants (from PanTool)
const ROTATION_THRESHOLD: float = 0.005  # Minimum angular change to trigger rotation (in radians)
const ROTATION_SENSITIVITY: float = 1.0  # How fast layer rotation responds to mouse angular movement (1.0 = 1:1)
const MIN_DISTANCE_FROM_ROT_CENTER: float = 15.0  # Mouse must be at least this far from center to detect rotation reliably

# Resize position tracking
var _resize_reference_positions = {}
var _handles_global_positions = {}

func _ready() -> void:
	# Create rotate cursor programmatically (SVG can't be loaded dynamically at runtime)
	_rotate_cursor_image = _create_rotate_cursor(24)
	print("TransformTool: Rotate cursor created: ", _rotate_cursor_image)

	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				print("TransformTool: Tool selected")
				if editor.active_layer:
					editor.active_layer.transform_rect_visible = true
					editor.queue_redraw()
			else:
				# Reset cursor when switching away from this tool
				editor.set_custom_cursor(null, Input.CURSOR_ARROW)
				if editor.active_layer:
					editor.active_layer.transform_rect_visible = false
					editor.queue_redraw()
	)

	editor.active_layer_changed.connect(
		func(layer: LayerV2):
			if editor.active_tool != self: return
			layer.transform_rect_visible = true
			print(layer)
			editor.queue_redraw()
	)

func _process(_delta: float) -> void:
	# Ensure transform boxes are visible when tool is active
	if editor.active_tool == self and editor.active_layer and not editor.active_layer.transform_rect_visible:
		editor.active_layer.transform_rect_visible = true
		editor.queue_redraw()

func _tool_selected() -> void:
	_reset_state()

	# Set default cursor for transform tool
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)

	# Make transform boxes visible immediately when tool is selected
	if editor.active_layer:
		editor.active_layer.transform_rect_visible = true
		editor.queue_redraw()

func _reset_state() -> void:
	_control_point_type = LayerV2.TransformPoint.NONE
	_is_transforming = false
	_original_image = null
	_resize_reference_positions.clear()
	_handles_global_positions.clear()
	# We don't reset _first_original_image here to preserve quality across operations

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer: return false

	# Store original event position before localization (needed for rotation calculations)
	var original_event_position = event.position if event is InputEventMouse else Vector2.ZERO
	
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		
		#if editor.selected_layers.size() > 1:
			#display_tool_error(ToolError.MULTIPLE_LAYERS_SELECTED)
			#return false

		if event.pressed:
			_start_transform(event, original_event_position)
		else:
			_end_transform()
		return true

	elif event is InputEventMouseMotion and _is_transforming:
		_update_transform(event, original_event_position)
		return true

	elif event is InputEventMouseMotion and not _is_transforming and editor.active_layer:
		# Update cursor when hovering over handles
		_update_cursor(event.position)

	return false


## Returns the appropriate cursor shape for a given transform point
func _get_cursor_for_transform_point(point: LayerV2.TransformPoint) -> Input.CursorShape:
	match point:
		LayerV2.TransformPoint.TOP_LEFT, LayerV2.TransformPoint.BOTTOM_RIGHT:
			return Input.CURSOR_FDIAGSIZE
		LayerV2.TransformPoint.TOP_RIGHT, LayerV2.TransformPoint.BOTTOM_LEFT:
			return Input.CURSOR_BDIAGSIZE
		LayerV2.TransformPoint.LEFT, LayerV2.TransformPoint.RIGHT:
			return Input.CURSOR_HSIZE
		LayerV2.TransformPoint.TOP, LayerV2.TransformPoint.BOTTOM:
			return Input.CURSOR_VSIZE
		LayerV2.TransformPoint.MOVE:
			return Input.CURSOR_MOVE
	return Input.CURSOR_ARROW


## Updates the cursor based on hover position over transform handles
func _update_cursor(local_pos: Vector2) -> void:
	if not editor.active_layer:
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return

	var point = editor.active_layer.get_rect_by_mouse_position(local_pos)

	# Debug logging for Bug 2 investigation
	print("_update_cursor: local_pos=", local_pos, " detected_point=", point, " layer_size=", editor.active_layer.size)

	if point == LayerV2.TransformPoint.ROTATE:
		# Use custom rotate cursor
		if _rotate_cursor_image:
			editor.set_custom_cursor(_rotate_cursor_image, Input.CURSOR_ARROW, Vector2(12, 12))
		else:
			editor.set_custom_cursor(null, Input.CURSOR_ARROW)
	elif point != LayerV2.TransformPoint.NONE:
		# Use appropriate cursor for resize handles or move
		var cursor_shape = _get_cursor_for_transform_point(point)
		print("_update_cursor: Setting cursor for handle: ", point, " -> cursor_shape: ", cursor_shape)
		editor.set_custom_cursor(null, cursor_shape)
	else:
		# Check if inside layer bounds for move cursor
		var layer_rect = Rect2(Vector2.ZERO, editor.active_layer.size)
		if layer_rect.has_point(local_pos):
			editor.set_custom_cursor(null, Input.CURSOR_MOVE)
		else:
			# Outside layer = rotate mode (match _start_transform behavior)
			if _rotate_cursor_image:
				editor.set_custom_cursor(_rotate_cursor_image, Input.CURSOR_ARROW, Vector2(12, 12))
			else:
				editor.set_custom_cursor(null, Input.CURSOR_ARROW)

func _get_handle_global_positions() -> Dictionary:
	# Calculate global positions of all control handles
	var result = {}
	var local_positions = editor.active_layer._get_transform_rect_positions()
	var layer_transform = editor.active_layer.get_global_transform()
	
	for point_type in local_positions:
		# Convert local handle position to global
		result[point_type] = layer_transform * local_positions[point_type]
	
	return result

func _get_opposite_handle(handle_type: int) -> int:
	# Get the opposite corner handle for reference
	match handle_type:
		LayerV2.TransformPoint.TOP_LEFT:
			return LayerV2.TransformPoint.BOTTOM_RIGHT
		LayerV2.TransformPoint.TOP:
			return LayerV2.TransformPoint.BOTTOM
		LayerV2.TransformPoint.TOP_RIGHT:
			return LayerV2.TransformPoint.BOTTOM_LEFT
		LayerV2.TransformPoint.RIGHT:
			return LayerV2.TransformPoint.LEFT
		LayerV2.TransformPoint.BOTTOM_RIGHT:
			return LayerV2.TransformPoint.TOP_LEFT
		LayerV2.TransformPoint.BOTTOM:
			return LayerV2.TransformPoint.TOP
		LayerV2.TransformPoint.BOTTOM_LEFT:
			return LayerV2.TransformPoint.TOP_RIGHT
		LayerV2.TransformPoint.LEFT:
			return LayerV2.TransformPoint.RIGHT
	return LayerV2.TransformPoint.NONE

func _start_transform(event: InputEvent, editor_local_position: Vector2) -> void:
	if not editor.active_layer:
		return
	
	# Store initial global position (layer-local for other operations)
	_drag_start_global_pos = event.position
	_layer_start_position = editor.active_layer.position
	_layer_start_size = editor.active_layer.custom_minimum_size
	_layer_start_rotation = editor.active_layer.rotation
	
	# Store initial mouse position in editor-local space for rotation calculation
	_last_mouse_position = editor_local_position
	
	# Calculate rotation center: layer's pivot point in editor's local coordinate space
	# This matches the PanTool's approach for consistent rotation behavior
	var layer_global_rect = editor.active_layer.get_global_rect()
	# Convert layer's global center (pivot point) to the editor's local input area coordinates
	_rotation_center = editor.get_global_transform().affine_inverse() * (layer_global_rect.position + editor.active_layer.pivot_offset)
	
	print("Transform started at position: ", _layer_start_position, " with rotation: ", _layer_start_rotation)
	
	# Cache global positions of all control handles
	_handles_global_positions = _get_handle_global_positions()
	
	# Convert event to layer-local space
	# var local_pos = editor.active_layer.get_global_transform().affine_inverse() * event.position
	var local_pos = event.position
	
	# Try to get control point from mouse position
	_control_point_type = editor.active_layer.get_rect_by_mouse_position(local_pos)
	
	# Determine the operation based on the control point
	if _control_point_type == LayerV2.TransformPoint.ROTATE:
		_current_operation = TransformMode.ROTATE
		print("Starting ROTATE operation")
	elif _control_point_type == LayerV2.TransformPoint.MOVE:
		_current_operation = TransformMode.MOVE
		print("Starting MOVE operation")
	elif _control_point_type == LayerV2.TransformPoint.NONE:
		# Check if inside layer bounds for move
		var layer_rect = Rect2(Vector2.ZERO, editor.active_layer.size)
		if layer_rect.has_point(local_pos):
			# Inside layer = move mode
			_control_point_type = LayerV2.TransformPoint.MOVE
			_current_operation = TransformMode.MOVE
			print("Inside layer - using MOVE operation")
		else:
			# Outside layer = rotate mode (only if yellow handle wasn't found)
			_control_point_type = LayerV2.TransformPoint.ROTATE
			_current_operation = TransformMode.ROTATE
			print("Outside layer - using ROTATE operation")
	else:
		# It's a resize control point
		_current_operation = TransformMode.RESIZE
		
		# For resize, also store the opposite handle's position for reference
		var opposite_handle = _get_opposite_handle(_control_point_type)
		if opposite_handle != LayerV2.TransformPoint.NONE:
			_resize_reference_positions[opposite_handle] = _handles_global_positions[opposite_handle]
		
		print("Starting RESIZE operation with control point: ", _control_point_type)

	# Set cursor to reflect the current operation
	_set_cursor_for_operation()

	# Store initial state
	_is_transforming = true
	_initial_click_position = local_pos
	_backup_original_state()


## Sets the cursor based on the current transform operation
func _set_cursor_for_operation() -> void:
	match _current_operation:
		TransformMode.MOVE:
			editor.set_custom_cursor(null, Input.CURSOR_MOVE)
		TransformMode.ROTATE:
			if _rotate_cursor_image:
				editor.set_custom_cursor(_rotate_cursor_image, Input.CURSOR_ARROW, Vector2(12, 12))
			else:
				editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		TransformMode.RESIZE:
			editor.set_custom_cursor(null, _get_cursor_for_transform_point(_control_point_type))

func _update_transform(event: InputEventMouseMotion, editor_local_position: Vector2) -> void:
	if not _is_transforming or not editor.active_layer:
		return
	
	# Use the current operation mode that was set when starting transform
	match _current_operation:
		TransformMode.MOVE:
			_handle_move(event)
		TransformMode.RESIZE:
			_handle_resize(event)
		TransformMode.ROTATE:
			_handle_rotate(editor_local_position)
	
	# Force redraw to update transform rect
	editor.queue_redraw()
	editor.active_layer.queue_redraw()

func _end_transform() -> void:
	if _is_transforming and editor.active_layer:
		print("TransformTool: Ending transform")
		_finalize_transform()

		# Force redraw after operation completion
		editor.active_layer._adjust_control_size()
		editor.queue_redraw()

	_is_transforming = false
	_control_point_type = LayerV2.TransformPoint.NONE
	_resize_reference_positions.clear()

	# Reset cursor to default
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)

func _backup_original_state() -> void:
	print("TransformTool: Backing up original state")
	
	# Backup current image state
	_original_image = editor.active_layer.image.duplicate()
	_original_dimensions = Vector2(editor.active_layer.image.get_width(), editor.active_layer.image.get_height())
	
	# If this is the first operation, also store the first original (high quality preservation)
	if _first_original_image == null:
		_first_original_image = _original_image.duplicate()
		_first_original_dimensions = _original_dimensions
	
	print("  - Original dimensions: ", _original_dimensions)
	print("  - Original position: ", _layer_start_position)

# Placeholder for the move operation - implement your own logic
func _handle_move(event: InputEventMouseMotion) -> void:
	editor.active_layer.position += event.screen_relative * editor.PAN_FACTOR * (1 / editor.input_area_camera.zoom.x)

# Placeholder for the resize operation - implement your own logic
func _handle_resize(event: InputEventMouseMotion) -> void:
	var size_factor: = event.screen_relative
	var move_factor: = event.screen_relative

	match _control_point_type:
		LayerV2.TransformPoint.TOP_LEFT:
			size_factor *= Vector2.ONE
			move_factor *= Vector2.ONE
		LayerV2.TransformPoint.TOP:
			size_factor *= Vector2.DOWN
			move_factor *= Vector2(0, 1)
		LayerV2.TransformPoint.TOP_RIGHT:
			size_factor *= Vector2(-1, 1)
			move_factor *= Vector2(0, 1)
		LayerV2.TransformPoint.RIGHT:
			size_factor *= Vector2.LEFT
			move_factor *= Vector2.ZERO
		LayerV2.TransformPoint.BOTTOM_RIGHT:
			size_factor *= Vector2(-1, -1)
			move_factor *= Vector2.ZERO
		LayerV2.TransformPoint.BOTTOM:
			size_factor *= Vector2.UP
			move_factor *= Vector2.ZERO
		LayerV2.TransformPoint.BOTTOM_LEFT:
			size_factor *= Vector2(1, -1)
			move_factor *= Vector2(1, 0)
		LayerV2.TransformPoint.LEFT:
			size_factor *= Vector2.RIGHT
			move_factor *= Vector2(1, 0)
	
	editor.active_layer.position += move_factor * editor.PAN_FACTOR * (1 / editor.input_area_camera.zoom.x)
	editor.active_layer.size -= size_factor * editor.PAN_FACTOR * (1 / editor.input_area_camera.zoom.x)
	editor.active_layer.pivot_offset = editor.active_layer.size * 0.5

# Rotate operation using circular motion detection (from PanTool)
func _handle_rotate(editor_local_position: Vector2) -> void:
	var current_mouse_position = editor_local_position
	
	# Calculate angular change using the same logic as PanTool
	var angular_change = _calculate_rotation_angle_delta(_last_mouse_position, current_mouse_position, _rotation_center)
	
	# Apply rotation if angular change exceeds threshold
	if abs(angular_change) > ROTATION_THRESHOLD:
		editor.active_layer.rotation += angular_change * ROTATION_SENSITIVITY * editor.PAN_FACTOR * (1 / editor.input_area_camera.zoom.x)
	
	# Update last mouse position for next frame
	_last_mouse_position = current_mouse_position

# Calculates the signed angle between two mouse positions relative to a center point.
# This implements the same rotation logic as PanTool for consistency.
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
	

# Placeholder for finalizing the transform - implement your own logic
func _finalize_transform() -> void:
	print("TransformTool: Finalizing transform")
	
	if _current_operation == TransformMode.RESIZE:
		print("  - Original dimensions: ", _original_dimensions)
		print("  - New dimensions: ", editor.active_layer.custom_minimum_size)
		print("  - Current position: ", editor.active_layer.position)
		print("  - Current rotation: ", editor.active_layer.rotation)
		
		# Implement your resize finalization logic here
		# Don't forget to handle image resampling
	
	_original_image = null
	_original_dimensions = Vector2.ZERO
	
	print("TransformTool: Transform finalized")
	print("  - Final position: ", editor.active_layer.position)
	print("  - Final rotation: ", editor.active_layer.rotation)


## Creates a rotate cursor image programmatically (circular arrow)
func _create_rotate_cursor(size: int) -> ImageTexture:
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)

	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0 - 3.0
	var line_color = Color.WHITE
	var outline_color = Color.BLACK

	# Draw circular arc (about 270 degrees)
	for i in range(270):
		var angle = deg_to_rad(i - 45)  # Start from top-right, go counter-clockwise
		var x = center.x + cos(angle) * radius
		var y = center.y + sin(angle) * radius

		# Draw outline
		for ox in range(-1, 2):
			for oy in range(-1, 2):
				var px = int(x + ox)
				var py = int(y + oy)
				if px >= 0 and px < size and py >= 0 and py < size:
					if image.get_pixel(px, py).a < 0.5:
						image.set_pixel(px, py, outline_color)

		# Draw main line
		var px = int(x)
		var py = int(y)
		if px >= 0 and px < size and py >= 0 and py < size:
			image.set_pixel(px, py, line_color)

	# Draw arrow head at the end (pointing counter-clockwise)
	var arrow_angle = deg_to_rad(225)  # End of arc
	var arrow_tip = center + Vector2(cos(arrow_angle), sin(arrow_angle)) * radius

	# Arrow head lines
	for i in range(6):
		var t = i / 5.0
		# First arrow line (pointing inward-tangent)
		var a1_end = arrow_tip + Vector2(4, -4)
		var p1 = arrow_tip.lerp(a1_end, t)
		if int(p1.x) >= 0 and int(p1.x) < size and int(p1.y) >= 0 and int(p1.y) < size:
			image.set_pixel(int(p1.x), int(p1.y), line_color)
		# Second arrow line
		var a2_end = arrow_tip + Vector2(-2, -5)
		var p2 = arrow_tip.lerp(a2_end, t)
		if int(p2.x) >= 0 and int(p2.x) < size and int(p2.y) >= 0 and int(p2.y) < size:
			image.set_pixel(int(p2.x), int(p2.y), line_color)

	return ImageTexture.create_from_image(image)
