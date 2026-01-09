class_name RenderViewTool
extends BaseTool

#signal draw_render_rect(rect: Rect2)

@export var control: Control = null #LayersContainer
@export var get_texture_button: Button = null
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

var _initial_mouse_pos_canvas: Vector2 = Vector2.ZERO
var _initial_rect_pos_canvas: Vector2 = Vector2.ZERO
var _initial_rect_size_canvas: Vector2 = Vector2.ZERO

const HANDLE_SIZE: float = 8.0

func _tool_selected() -> void:
	_reset_state()
	editor.render_view_control.draw_render_view = true
	editor.render_view_control.queue_redraw()
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)
	get_texture_button.show()


func _reset_state() -> void:
	_is_drawing_new_rect = false
	_is_moving_rect = false
	_is_resizing_rect = false
	_resize_handle = ResizeHandle.NONE
	_initial_mouse_pos_canvas = Vector2.ZERO
	_initial_rect_pos_canvas = Vector2.ZERO
	_initial_rect_size_canvas = Vector2.ZERO
	get_texture_button.hide()


func handle_input_event(event: InputEvent) -> bool:
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()
	
	if !editor.layers_container.get_rect().has_point(canvas_local_mouse_pos):
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return false
	elif get_texture_button.get_rect().has_point(canvas_local_mouse_pos):
		editor.set_custom_cursor(null, Input.CURSOR_POINTING_HAND)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			if get_texture_button.get_rect().has_point(canvas_local_mouse_pos):
				get_texture_button.pressed.emit()
				get_texture_button.hide()
			_initial_mouse_pos_canvas = canvas_local_mouse_pos
			_initial_rect_pos_canvas = editor.render_view_control._rect.position
			_initial_rect_size_canvas = editor.render_view_control._rect.size
			
			_resize_handle = _get_resize_handle_at_pos(canvas_local_mouse_pos)
			
			if _resize_handle != ResizeHandle.NONE:
				_is_resizing_rect = true
				editor.set_custom_cursor(null, _get_cursor_for_handle(_resize_handle))
			elif editor.render_view_control._rect.size != Vector2.ZERO and editor.render_view_control._rect.has_point(canvas_local_mouse_pos):
				_is_moving_rect = true
				editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE) 
			else:
				_is_drawing_new_rect = true
				editor.render_view_control._rect = Rect2(canvas_local_mouse_pos, Vector2(1,1))
				editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE)
			
			editor.render_view_control.queue_redraw()
			return true # Event handled
		
		else: # Mouse button released
			_is_drawing_new_rect = false
			_is_moving_rect = false
			_is_resizing_rect = false
			_resize_handle = ResizeHandle.NONE
			editor.set_custom_cursor(null, Input.CURSOR_CROSS) # Reset to default for tool
			
			editor.render_view_control._rect = editor.render_view_control._rect.abs()
			editor.render_view_control.queue_redraw()
			return true
	
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
			
			editor.render_view_control._rect = new_rect
			editor.render_view_control.queue_redraw()
			return true
		else: # Mouse motion without active drag, update cursor for hover feedback
			_update_mouse_cursor(canvas_local_mouse_pos)
			return false
	
	return false


func _update_mouse_cursor(pos: Vector2) -> void:
	var handle = _get_resize_handle_at_pos(pos)
	if handle != ResizeHandle.NONE:
		editor.set_custom_cursor(null, _get_cursor_for_handle(handle))
	elif editor.render_view_control._rect.size != Vector2.ZERO and editor.render_view_control._rect.has_point(pos):
		editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE)
	else:
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)


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
	
	var tl = rect.position
	var top_right = Vector2(rect.end.x, rect.position.y)
	var bl = Vector2(rect.position.x, rect.end.y)
	var br = rect.end
	
	if Rect2(tl - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.TOP_LEFT
	if Rect2(top_right - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)).has_point(pos): return ResizeHandle.TOP_RIGHT
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
		if Rect2(top_right.x - HANDLE_SIZE/2, top_right.y + HANDLE_SIZE/2, HANDLE_SIZE, rect.size.y - HANDLE_SIZE).has_point(pos): return ResizeHandle.RIGHT

	return ResizeHandle.NONE
