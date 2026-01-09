class_name RenderViewTool
extends BaseTool

@export var control: Control = null #LayersContainer

# State variables for interaction
var _is_drawing_new_rect: bool = false

var _initial_mouse_pos_canvas: Vector2 = Vector2.ZERO

const HANDLE_SIZE: float = 8.0
const MIN_RECT_SIZE: float = 10.0  # Minimum size to consider a valid selection

func _tool_selected() -> void:
	_reset_state()
	editor.render_view_control.draw_render_view = true
	editor.render_view_control._rect = Rect2()  # Clear any previous rectangle
	editor.render_view_control.queue_redraw()
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func _reset_state() -> void:
	_is_drawing_new_rect = false
	_initial_mouse_pos_canvas = Vector2.ZERO


func handle_input_event(event: InputEvent) -> bool:
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()

	# Handle Escape key to cancel
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.is_pressed():
		_cancel_and_exit()
		return true

	if !editor.layers_container.get_rect().has_point(canvas_local_mouse_pos):
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			# Start drawing a new rectangle
			_is_drawing_new_rect = true
			_initial_mouse_pos_canvas = canvas_local_mouse_pos
			editor.render_view_control._rect = Rect2(canvas_local_mouse_pos, Vector2(1, 1))
			editor.set_custom_cursor(null, Input.CURSOR_FDIAGSIZE)
			editor.render_view_control.queue_redraw()
			return true

		else:  # Mouse button released
			if _is_drawing_new_rect:
				_is_drawing_new_rect = false
				editor.render_view_control._rect = editor.render_view_control._rect.abs()
				editor.render_view_control.queue_redraw()

				# Check if rectangle is large enough to be valid
				var rect = editor.render_view_control._rect
				if rect.size.x >= MIN_RECT_SIZE and rect.size.y >= MIN_RECT_SIZE:
					# Trigger export immediately
					editor.export_region_and_exit()
				else:
					# Rectangle too small, reset and let user try again
					editor.render_view_control._rect = Rect2()
					editor.render_view_control.queue_redraw()

				editor.set_custom_cursor(null, Input.CURSOR_CROSS)
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

	return false


func _cancel_and_exit() -> void:
	# Clear rectangle and exit tool
	editor.render_view_control._rect = Rect2()
	editor.render_view_control.draw_render_view = false
	editor.render_view_control.queue_redraw()
	editor.render_viewport_button.set_pressed_no_signal(false)
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)
	# Return to default tool
	editor._tools_option_button.select(0)
	editor._tools_option_button.item_selected.emit(0)
