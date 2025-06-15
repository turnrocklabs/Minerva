class_name TransformTool
extends BaseTool

enum TransformMode { RESIZE, MOVE, ROTATE }

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

# Resize position tracking
var _resize_reference_positions = {}
var _handles_global_positions = {}

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				print("TransformTool: Tool selected")
				if editor.active_layer:
					editor.active_layer.transform_rect_visible = true
					editor.queue_redraw()
			else:
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

func handle_input_event(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		
		if editor.selected_layers.size() > 1:
			display_tool_error(ToolError.MULTIPLE_LAYERS_SELECTED)
			return

		if event.pressed:
			_start_transform(event)
		else:
			_end_transform()
	elif event is InputEventMouseMotion and _is_transforming:
		_update_transform(event)
	elif event is InputEventMouseMotion and not _is_transforming and editor.active_layer:
		# Update cursor when hovering over handles
		var local_pos = editor.active_layer.get_global_transform().affine_inverse() * event.position
		var hover_point = editor.active_layer.get_rect_by_mouse_position(local_pos)
		
		# You could implement cursor changes based on the hover_point if needed

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

func _start_transform(event: InputEvent) -> void:
	if not editor.active_layer:
		return
	
	# Store initial global position
	_drag_start_global_pos = event.position
	_layer_start_position = editor.active_layer.position
	_layer_start_size = editor.active_layer.custom_minimum_size
	_layer_start_rotation = editor.active_layer.rotation
	
	# Store global center of layer for rotation
	_rotation_center = editor.active_layer.global_position + editor.active_layer.size/2
	print("Transform started at position: ", _layer_start_position, " with rotation: ", _layer_start_rotation)
	
	# Cache global positions of all control handles
	_handles_global_positions = _get_handle_global_positions()
	
	# Convert event to layer-local space
	var local_pos = editor.active_layer.get_global_transform().affine_inverse() * event.position
	
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
	
	# Store initial state
	_is_transforming = true
	_initial_click_position = local_pos
	_backup_original_state()

func _update_transform(event: InputEventMouseMotion) -> void:
	if not _is_transforming or not editor.active_layer:
		return
	
	# Use the current operation mode that was set when starting transform
	match _current_operation:
		TransformMode.MOVE:
			_handle_move(event)
		TransformMode.RESIZE:
			_handle_resize(event)
		TransformMode.ROTATE:
			_handle_rotate(event)
	
	# Force redraw to update transform rect
	editor.queue_redraw()

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
	editor.active_layer.position += event.screen_relative

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
			move_factor *= Vector2(0, 	1)
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


	editor.active_layer.position += move_factor
	editor.active_layer.size -= size_factor

# Placeholder for the rotate operation - implement your own logic
func _handle_rotate(event: InputEventMouseMotion) -> void:
	# Get the distance of mouse from pivot
	var pivot = editor.active_layer.global_position + editor.active_layer.size/2
	
	# Calculate how far mouse moved around the pivot
	var move_delta = event.screen_relative
	
	# Cross product to determine direction (positive = CCW, negative = CW)
	# This uses the relative movement and vector from pivot to mouse
	var pivot_to_mouse = event.position - pivot
	var direction = pivot_to_mouse.x * move_delta.y - pivot_to_mouse.y * move_delta.x
	
	# Calculate rotation factor based on movement and distance
	var rotation_speed = 0.005
	var rotate_factor = move_delta.length() * rotation_speed * sign(direction)
	
	# Apply rotation
	editor.active_layer.rotation += rotate_factor
	


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
