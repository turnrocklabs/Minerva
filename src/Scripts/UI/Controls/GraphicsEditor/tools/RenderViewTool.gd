class_name RenderViewTool
extends BaseTool

signal draw_render_rect(rect_pos:Vector2, rect_size: Vector2)

@export var control: Control = null

enum RenderViewMode { 
	RESIZE,
	MOVE, 
	ROTATE
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

# Resize position tracking
var _resize_reference_positions = {}
var _handles_global_positions = {}

var draw_rect : = false
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


func _tool_selected() -> void:
	_reset_state()


func _reset_state() -> void:
	_control_point_type = LayerV2.TransformPoint.NONE
	_is_transforming = false
	is_drawing_rect = false
	#_original_image = null
	_resize_reference_positions.clear()
	_handles_global_positions.clear()
	# We don't reset _first_original_image here to preserve quality across operations


func handle_input_event(event: InputEvent) -> bool:
	#if not editor.active_layer: return false
	
	event  = editor.active_layer.localize_input(event)
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_start_drawing(event)
		else:
			_end_drawing(event)
	elif event is InputEventMouseMotion and is_drawing_rect:
		if _rect_start_global_pos != event.position:
			_draw_viewport(event)
	
	return true

func _draw_viewport(event: InputEvent) -> void:
	is_drawing_rect = true
	_rect_end_global_pos = event.position
	emit_signal("draw_render_rect", _rect_start_global_pos, _rect_end_global_pos)


func _start_drawing(event: InputEvent) -> void:
	is_drawing_rect = true
	_rect_start_global_pos = event.position
	emit_signal("draw_render_rect", _rect_start_global_pos, _rect_end_global_pos)


func _end_drawing(event: InputEvent) -> void:
	is_drawing_rect = false
	#editor.draw_render_view = false
	_rect_end_global_pos = event.position
	emit_signal("draw_render_rect", _rect_start_global_pos, _rect_end_global_pos)
