class_name SelectTool
extends BaseTool

## A selection/arrow tool for selecting and moving layers.
## For TEXT layers, only allows dragging via the underline handle.

var _is_dragging: bool = false
var _dragging_layer: LayerV2 = null  # Store layer being dragged locally
var _drag_start_position: Vector2 = Vector2.ZERO
var _layer_start_position: Vector2 = Vector2.ZERO


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)


func handle_input_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			return _handle_mouse_down(event)
		else:
			return _handle_mouse_up(event)

	elif event is InputEventMouseMotion and _is_dragging:
		return _handle_drag(event)

	elif event is InputEventMouseMotion:
		_update_cursor(event)
		return false

	return false


func _handle_mouse_down(event: InputEventMouseButton) -> bool:
	# Check for double-click on TEXT layer to edit it
	if event.double_click:
		var text_layer = _get_text_layer_at_position()
		if text_layer:
			# Switch to text tool and trigger edit
			editor.active_tool = editor.text_tool
			editor.text_tool._edit_existing_layer(text_layer)
			return true

	# First, check if clicking on a TEXT layer's handle (prioritize these)
	var text_layer_with_handle = _get_text_layer_with_handle_at_position()
	if text_layer_with_handle:
		_start_drag(event, text_layer_with_handle)
		return true

	# Find layer under cursor (for non-TEXT layers or TEXT layers clicked outside handle)
	var clicked_layer = _get_layer_at_position()

	if clicked_layer:
		# For non-TEXT layers, can start dragging anywhere on the layer
		if clicked_layer.type != LayerV2.Type.TEXT:
			_start_drag(event, clicked_layer)
			return true

	return true


func _handle_mouse_up(_event: InputEventMouseButton) -> bool:
	if _is_dragging:
		_is_dragging = false
		_dragging_layer = null
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return true
	return false


func _handle_drag(event: InputEventMouseMotion) -> bool:
	if not _dragging_layer:
		_is_dragging = false
		return false

	# Move the layer
	var delta = event.screen_relative * editor.PAN_FACTOR * (1.0 / editor.input_area_camera.zoom.x)
	_dragging_layer.position += delta

	editor.queue_redraw()
	_dragging_layer.queue_redraw()
	return true


func _update_cursor(_event: InputEventMouseMotion) -> void:
	# First check if hovering over a TEXT layer's handle (prioritize these)
	var text_layer_with_handle = _get_text_layer_with_handle_at_position()
	if text_layer_with_handle:
		editor.set_custom_cursor(null, Input.CURSOR_MOVE)
		return

	# Check other layers
	var layer = _get_layer_at_position()

	if layer:
		if layer.type == LayerV2.Type.TEXT:
			# TEXT layer but not on handle - show arrow
			editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		else:
			# For other layers, show move cursor anywhere on the layer
			editor.set_custom_cursor(null, Input.CURSOR_MOVE)
	else:
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)


func _start_drag(event: InputEventMouseButton, layer: LayerV2) -> void:
	_is_dragging = true
	_dragging_layer = layer
	_drag_start_position = event.position
	_layer_start_position = layer.position
	editor.set_custom_cursor(null, Input.CURSOR_MOVE)


func _get_layer_at_position() -> LayerV2:
	# Check layers in reverse order (top layer first)
	# Use same approach as TextTool: get mouse in layers_container space, then transform to layer space
	var layers = editor.layers_container.get_children()
	var container_mouse = editor.layers_container.get_local_mouse_position()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.visible:
			# Transform from layers_container space to layer local space
			var local_pos = layer.get_transform().affine_inverse() * container_mouse
			var bounds = Rect2(Vector2.ZERO, layer.size)
			if bounds.has_point(local_pos):
				return layer
	return null


func _get_text_layer_at_position() -> LayerV2:
	# Check layers in reverse order (top layer first) - TEXT layers only
	var layers = editor.layers_container.get_children()
	var container_mouse = editor.layers_container.get_local_mouse_position()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.TEXT and layer.visible:
			var local_pos = layer.get_transform().affine_inverse() * container_mouse
			if Rect2(Vector2.ZERO, layer.size).has_point(local_pos):
				return layer
	return null


func _get_text_layer_with_handle_at_position() -> LayerV2:
	# Check all TEXT layers to see if click is on their underline handle
	var layers = editor.layers_container.get_children()
	var container_mouse = editor.layers_container.get_local_mouse_position()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.TEXT and layer.visible:
			var local_pos = layer.get_transform().affine_inverse() * container_mouse
			if layer.is_point_on_text_handle(local_pos):
				return layer
	return null
