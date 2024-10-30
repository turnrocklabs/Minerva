class_name PaneTool
extends BaseTool

var dragging: = false

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				dragging = true
			else:
				dragging = false

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			editor.active_layer.scale *= 1.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			editor.active_layer.scale *= 0.9

	if event is InputEventMouseMotion:
		if dragging:
			editor.active_layer.position += event.relative * editor.active_layer.scale
	