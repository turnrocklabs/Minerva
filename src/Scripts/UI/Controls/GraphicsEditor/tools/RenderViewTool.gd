class_name RenderViewTool
extends BaseTool

signal draw_render_rect(rect: Rect2)

@export var control: Control = null

enum RenderViewMode { 
	RESIZE,
	MOVE, 
	ROTATE # not implemented yet, it apears to be a bit difficult
	}

var _control_point_type: int = LayerV2.TransformPoint.NONE
var _current_operation: RenderViewMode = RenderViewMode.MOVE
var _is_transforming: bool = false
var is_drawing_rect: = false
# Position tracking
var _rect_start_global_pos: Vector2 = Vector2.ZERO
var _rect_end_global_pos: Vector2 = Vector2.ZERO
var _initial_click_position: Vector2 = Vector2.ZERO
var _rotation_center: Vector2 = Vector2.ZERO
var _rotation_angle: float = 0.0
var _points_positions: Array[Vector2] = []

# Resize position tracking
var _resize_reference_positions = {}
var _handles_global_positions = {}

var draw_rect : = false
var _rect: Rect2 = Rect2(_rect_start_global_pos,  _rect_end_global_pos - _rect_start_global_pos)

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				print("RenderViewTool: Tool selected")
				editor.draw_render_view = true
				editor.set_custom_cursor(null, Input.CursorShape.CURSOR_MOVE,)
			else:
				editor.draw_render_view = false
	)
	
	editor.active_layer_changed.connect(
		func(layer: LayerV2):
			if editor.active_tool != self: 
				draw_rect = false
			print(layer)
			editor.queue_redraw()
	)
	
	control.z_index = 10
	_rect_start_global_pos = control.position
	_rect_end_global_pos = control.size
	
	#top left
	_points_positions.append(_rect_start_global_pos)
	#top right
	_points_positions.append(Vector2(_rect_end_global_pos.x, _rect_start_global_pos.y))
	#bottom.
	# bottom left
	_points_positions.append(Vector2(_rect_start_global_pos.x, _rect_end_global_pos.y))
	
	


func _tool_selected() -> void:
	_reset_state()


func _reset_state() -> void:
	_control_point_type = LayerV2.TransformPoint.NONE
	_is_transforming = false
	is_drawing_rect = false
	_resize_reference_positions.clear()
	_handles_global_positions.clear()
	# We don't reset _first_original_image here to preserve quality across operations


func handle_input_event(event: InputEvent) -> bool:
	#if not editor.active_layer: return false
	
	event  = editor.active_layer.localize_input(event)
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			if _rect.has_point(event.position):
				_current_operation = RenderViewMode.MOVE
			elif not _rect.has_point(event.position) and event.is_action_pressed("rotate"):
				_current_operation = RenderViewMode.ROTATE
			else:
				_current_operation = RenderViewMode.RESIZE
				is_drawing_rect = true
			_start_drawing(event)
		else:
			if _current_operation == RenderViewMode.RESIZE:
				is_drawing_rect = false
			if _current_operation == RenderViewMode.MOVE:
				_end_drawing(event)
	elif event is InputEventMouseMotion and is_drawing_rect:
		match _current_operation:
			RenderViewMode.MOVE:
				_draw_viewport(event)
			RenderViewMode.RESIZE:
				pass
			RenderViewMode.ROTATE:
				pass
			
		if _rect_start_global_pos != event.position:
			_draw_viewport(event)
	
	return true

func _draw_viewport(event: InputEvent) -> void:
	#is_drawing_rect = true
	#if event.position.x < _rect.position.x:
		#_rect.position.x = event.position.x
	#elif event.position.x > _rect.end.x:
		#_rect.end.x = event.position.x
		#
	#if event.position.y < _rect.position.y:
		#_rect.position.y = event.position.y
	#elif event.position.y > _rect.end.y:
		#_rect.end.y = event.position.y
	if event.position < _rect.position:
		_rect.position = event.position
	if event.position > _rect.end:
		_rect.end = event.position
	emit_signal("draw_render_rect", _rect)


func _start_drawing(event: InputEvent) -> void:
	#is_drawing_rect = true
	match _current_operation:
		RenderViewMode.RESIZE:
			#if event.position.x < _rect.position.x:
				#_rect.position.x = event.position.x
			#elif event.position.x > _rect.position.x:
				#_rect.position.x = event.position.x
			#if event.position.x > _rect.end.x:
				#_rect.end.x = event.position.x
			#elif event.position.x < _rect.end.x:
				#_rect.end.x = event.position.x
			#if event.position.y < _rect.position.y:
				#_rect.position.y = event.position.y
			#elif event.position.y > _rect.end.y:
				#_rect.end.y = event.position.y
			if event.position < _rect.position:
				_rect.position = event.position
			if event.position > _rect.end:
				_rect.end = event.position
		RenderViewMode.MOVE:
			pass
	#_rect_start_global_pos = event.position
	emit_signal("draw_render_rect", _rect)


func _end_drawing(event: InputEvent) -> void:
	#is_drawing_rect = false
	#editor.draw_render_view = false
	if event.position.x < _rect.position.x:
		_rect.position.x = event.position.x
	elif event.position.x > _rect.end.x:
		_rect.end.x = event.position.x
		
	if event.position.y < _rect.position.y:
		_rect.position.y = event.position.y
	elif event.position.y > _rect.end.y:
		_rect.end.y = event.position.y
	emit_signal("draw_render_rect", _rect)
