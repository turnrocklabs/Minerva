class_name SelectTool
extends BaseTool

## A selection/arrow tool for selecting and moving layers.
## For TEXT layers, only allows dragging via the underline handle.
## For DIAGRAM_SHAPE layers, double-click to edit text.

var _is_dragging: bool = false
var _dragging_layer: LayerV2 = null  # Store layer being dragged locally
var _drag_start_position: Vector2 = Vector2.ZERO
var _layer_start_position: Vector2 = Vector2.ZERO

# Diagram shape text editing
var _editing_diagram_shape: LayerV2 = null
var _diagram_text_edit: LineEdit = null


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

		# Check for double-click on DIAGRAM_SHAPE layer to edit text
		var diagram_layer = _get_diagram_shape_at_position()
		if diagram_layer:
			_start_diagram_text_edit(diagram_layer)
			return true

	# If clicking elsewhere while editing diagram shape text, commit the edit
	if _editing_diagram_shape != null:
		_commit_diagram_text()

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


func _get_diagram_shape_at_position() -> LayerV2:
	# Check layers in reverse order (top layer first) - DIAGRAM_SHAPE layers only
	var layers = editor.layers_container.get_children()
	var container_mouse = editor.layers_container.get_local_mouse_position()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_SHAPE and layer.visible:
			var local_pos = layer.get_transform().affine_inverse() * container_mouse
			if Rect2(Vector2.ZERO, layer.size).has_point(local_pos):
				return layer
	return null


func _start_diagram_text_edit(layer: LayerV2) -> void:
	_editing_diagram_shape = layer

	# Create LineEdit if needed (add to layers_container so it appears on canvas)
	if _diagram_text_edit == null:
		_diagram_text_edit = LineEdit.new()
		_diagram_text_edit.placeholder_text = "Type..."
		_diagram_text_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
		_diagram_text_edit.flat = true
		_diagram_text_edit.expand_to_text_length = true
		_diagram_text_edit.custom_minimum_size = Vector2(50, 0)

		# Minimal style with subtle background
		var style = StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, 0.9)
		style.set_corner_radius_all(2)
		_diagram_text_edit.add_theme_stylebox_override("normal", style)
		_diagram_text_edit.add_theme_stylebox_override("focus", style)

		_diagram_text_edit.text_submitted.connect(_on_diagram_text_submitted)
		editor.layers_container.add_child(_diagram_text_edit)

	# Pre-populate with existing text
	_diagram_text_edit.text = layer.diagram_text_content

	# Style the LineEdit to match the layer's text settings
	var font = layer.diagram_text_font if layer.diagram_text_font else ThemeDB.get_fallback_font()
	var font_size = layer.diagram_text_font_size
	var text_color = layer.diagram_text_color

	_diagram_text_edit.add_theme_font_override("font", font)
	_diagram_text_edit.add_theme_font_size_override("font_size", font_size)
	_diagram_text_edit.add_theme_color_override("font_color", text_color)
	_diagram_text_edit.add_theme_color_override("font_placeholder_color", Color(text_color, 0.5))
	_diagram_text_edit.add_theme_color_override("caret_color", text_color)

	# Position at center of shape (in layers_container local coordinates)
	var center_pos = layer.position + layer.size / 2
	_diagram_text_edit.position = center_pos

	_diagram_text_edit.visible = true
	_diagram_text_edit.grab_focus()
	_diagram_text_edit.select_all()

	# Center the LineEdit on the shape (deferred to get correct size)
	_center_diagram_text_edit.call_deferred(layer)


func _center_diagram_text_edit(layer: LayerV2) -> void:
	if _diagram_text_edit and layer:
		var center_pos = layer.position + layer.size / 2
		var edit_size = _diagram_text_edit.size
		_diagram_text_edit.position = center_pos - edit_size / 2


func _commit_diagram_text() -> void:
	if _editing_diagram_shape == null or _diagram_text_edit == null:
		return

	# Update the layer's text
	_editing_diagram_shape.diagram_text_content = _diagram_text_edit.text
	_editing_diagram_shape.queue_redraw()

	# Cleanup
	_diagram_text_edit.visible = false
	_diagram_text_edit.text = ""
	_editing_diagram_shape = null


func _on_diagram_text_submitted(_text: String) -> void:
	_commit_diagram_text()
