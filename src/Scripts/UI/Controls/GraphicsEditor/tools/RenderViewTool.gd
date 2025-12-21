class_name RenderViewTool
extends BaseTool

signal draw_render_rect(rect: Rect2) # This signal is no longer needed. The tool directly updates render_view_control._rect

@export var control: Control = null # This control is %DrawingAreaSubViewport/Control, i.e., the LayersContainer wrapper

# Enum for different resize handles
enum ResizeHandle {
	NONE,
	TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT,
	LEFT, RIGHT, TOP, BOTTOM
}

# State variables for interaction
var _is_drawing_new_rect: bool = false
var _is_moving_rect: bool = false
var _is_resizing_rect: bool = false
var _resize_handle: ResizeHandle = ResizeHandle.NONE

# Positions tracked at the start of a drag
var _initial_mouse_pos_canvas: Vector2 = Vector2.ZERO
var _initial_rect_pos_canvas: Vector2 = Vector2.ZERO
var _initial_rect_size_canvas: Vector2 = Vector2.ZERO

const HANDLE_SIZE: float = 8.0 # Size of the clickable resize handles

func _tool_selected() -> void:
	_reset_state()
	# When this tool is selected, ensure the RenderViewControl is visible and drawing
	editor.render_view_control.draw_render_view = true
	editor.render_view_control.queue_redraw()
	editor.set_custom_cursor(null, Input.CURSOR_CROSS) # Default cursor for drawing/general interaction


func _reset_state() -> void:
	_is_drawing_new_rect = false
	_is_moving_rect = false
	_is_resizing_rect = false
	_resize_handle = ResizeHandle.NONE
	_initial_mouse_pos_canvas = Vector2.ZERO
	_initial_rect_pos_canvas = Vector2.ZERO
	_initial_rect_size_canvas = Vector2.ZERO
	# Note: _rect itself is NOT reset here to preserve the user's last rectangle.
	# If you want to clear it, add: editor.render_view_control._rect = Rect2()


func handle_input_event(event: InputEvent) -> bool:
	# Input events are already relative to GraphicsEditorV2
	# We need them relative to the 'canvas' area, which is `layers_container`
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_initial_mouse_pos_canvas = canvas_local_mouse_pos
			_initial_rect_pos_canvas = editor.render_view_control._rect.position
			_initial_rect_size_canvas = editor.render_view_control._rect.size

			_resize_handle = _get_resize_handle_at_pos(canvas_local_mouse_pos)

			if _resize_handle != ResizeHandle.NONE:
				_is_resizing_rect = true
				editor.set_custom_cursor(null, _get_cursor_for_handle(_resize_handle))
			elif editor.render_view_control._rect.size != Vector2.ZERO and editor.render_view_control._rect.has_point(canvas_local_mouse_pos):
				_is_moving_rect = true
				editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE) # Or CURSOR_MOVE
			else:
				_is_drawing_new_rect = true
				# Start a new rectangle from the click point with 1x1 size
				editor.render_view_control._rect = Rect2(canvas_local_mouse_pos, Vector2(1,1))
				editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE) # Cross or resize cursor

			editor.render_view_control.queue_redraw() # Redraw to show potential initial rect/handles
			return true # Event handled

		else: # Mouse button released
			_is_drawing_new_rect = false
			_is_moving_rect = false
			_is_resizing_rect = false
			_resize_handle = ResizeHandle.NONE
			editor.set_custom_cursor(null, Input.CURSOR_CROSS) # Reset to default for tool
			
			# Ensure the rectangle has positive dimensions after drag
			editor.render_view_control._rect = editor.render_view_control._rect.abs()
			editor.render_view_control.queue_redraw()
			return true # Event handled

	elif event is InputEventMouseMotion:
		if _is_drawing_new_rect:
			var start_pos = _initial_mouse_pos_canvas
			var end_pos = canvas_local_mouse_pos
			
			var new_x = min(start_pos.x, end_pos.x)
			var new_y = min(start_pos.y, end_pos.y)
			var new_width = abs(start_pos.x - end_pos.x)
			var new_height = abs(start_pos.y - end_pos.y)
			
			editor.render_view_control._rect = Rect2(new_x, new_y, new_width, new_height)
			editor.render_view_control.queue_redraw()
			return true
		elif _is_moving_rect:
			var delta = canvas_local_mouse_pos - _initial_mouse_pos_canvas
			editor.render_view_control._rect.position = _initial_rect_pos_canvas + delta
			editor.render_view_control.queue_redraw()
			return true
		elif _is_resizing_rect:
			var new_rect = Rect2(_initial_rect_pos_canvas, _initial_rect_size_canvas)
			var mouse_delta = canvas_local_mouse_pos - _initial_mouse_pos_canvas

			match _resize_handle:
				ResizeHandle.TOP_LEFT:
					new_rect.position.x += mouse_delta.x
					new_rect.position.y += mouse_delta.y
					new_rect.size.x -= mouse_delta.x
					new_rect.size.y -= mouse_delta.y
				ResizeHandle.TOP_RIGHT:
					new_rect.position.y += mouse_delta.y
					new_rect.size.x += mouse_delta.x
					new_rect.size.y -= mouse_delta.y
				ResizeHandle.BOTTOM_LEFT:
					new_rect.position.x += mouse_delta.x
					new_rect.size.x -= mouse_delta.x
					new_rect.size.y += mouse_delta.y
				ResizeHandle.BOTTOM_RIGHT:
					new_rect.size.x += mouse_delta.x
					new_rect.size.y += mouse_delta.y
				ResizeHandle.LEFT:
					new_rect.position.x += mouse_delta.x
					new_rect.size.x -= mouse_delta.x
				ResizeHandle.RIGHT:
					new_rect.size.x += mouse_delta.x
				ResizeHandle.TOP:
					new_rect.position.y += mouse_delta.y
					new_rect.size.y -= mouse_delta.y
				ResizeHandle.BOTTOM:
					new_rect.size.y += mouse_delta.y
			
			# Update the rect in RenderViewControl. It will handle abs() if needed during draw.
			editor.render_view_control._rect = new_rect
			editor.render_view_control.queue_redraw()
			return true
		else: # Mouse motion without active drag, update cursor for hover feedback
			_update_mouse_cursor(canvas_local_mouse_pos)
			return false # Not handled, allow other controls to receive it if they want

	return false # Event not handled by this tool


# Helper for cursor management based on hover position
func _update_mouse_cursor(pos: Vector2) -> void:
	var handle = _get_resize_handle_at_pos(pos)
	if handle != ResizeHandle.NONE:
		editor.set_custom_cursor(null, _get_cursor_for_handle(handle))
	elif editor.render_view_control._rect.size != Vector2.ZERO and editor.render_view_control._rect.has_point(pos):
		editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE) # Move cursor
	else:
		editor.set_custom_cursor(null, Input.CURSOR_CROSS) # Default draw cursor


# Returns the appropriate cursor for a given resize handle
func _get_cursor_for_handle(handle: ResizeHandle) -> Input.CursorShape:
	match handle:
		ResizeHandle.TOP_LEFT, ResizeHandle.BOTTOM_RIGHT: return Input.CURSOR_FDIAGSIZE
		ResizeHandle.TOP_RIGHT, ResizeHandle.BOTTOM_LEFT: return Input.CURSOR_BDIAGSIZE
		ResizeHandle.LEFT, ResizeHandle.RIGHT: return Input.CURSOR_HSIZE
		ResizeHandle.TOP, ResizeHandle.BOTTOM: return Input.CURSOR_VSIZE
	return Input.CURSOR_CROSS # Fallback


# Determines if a resize handle is being hovered/clicked
func _get_resize_handle_at_pos(pos: Vector2) -> ResizeHandle:
	var rect = editor.render_view_control._rect
	if rect.size.x <= 0 or rect.size.y <= 0: return ResizeHandle.NONE

	# Calculate corner points in canvas coordinates
	var tl = rect.position
	var tr = Vector2(rect.end.x, rect.position.y)
	var bl = Vector2(rect.position.x, rect.end.y)
	var br = rect.end
	
	# Check corners first (higher priority)
	if Rect2(tl - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.TOP_LEFT
	if Rect2(tr - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.TOP_RIGHT
	if Rect2(bl - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.BOTTOM_LEFT
	if Rect2(br - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.BOTTOM_RIGHT
	
	# Check mid-edges (lower priority, require sufficient rect size to avoid overlap with corners)
	var min_edge_check_size = HANDLE_SIZE * 2 # To prevent edge handles from overlapping corners
	
	if rect.size.x > min_edge_check_size:
		# Top edge
		if Rect2(tl.x + HANDLE_SIZE/2, tl.y - HANDLE_SIZE/2, rect.size.x - HANDLE_SIZE, HANDLE_SIZE).has_point(pos): return ResizeHandle.TOP
		# Bottom edge
		if Rect2(bl.x + HANDLE_SIZE/2, bl.y - HANDLE_SIZE/2, rect.size.x - HANDLE_SIZE, HANDLE_SIZE).has_point(pos): return ResizeHandle.BOTTOM
	
	if rect.size.y > min_edge_check_size:
		# Left edge
		if Rect2(tl.x - HANDLE_SIZE/2, tl.y + HANDLE_SIZE/2, HANDLE_SIZE, rect.size.y - HANDLE_SIZE).has_point(pos): return ResizeHandle.LEFT
		# Right edge
		if Rect2(tr.x - HANDLE_SIZE/2, tr.y + HANDLE_SIZE/2, HANDLE_SIZE, rect.size.y - HANDLE_SIZE).has_point(pos): return ResizeHandle.RIGHT

	return ResizeHandle.NONE
