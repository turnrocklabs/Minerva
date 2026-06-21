class_name SelectTool
extends BaseTool

## A selection/arrow tool for selecting and moving layers.
## For TEXT layers, only allows dragging via the underline handle.
## For DIAGRAM_SHAPE layers, double-click to edit text.
## For DIAGRAM_CONNECTOR layers, drag handles to adjust path or reconnect endpoints.

var _is_dragging: bool = false
var _dragging_layer: LayerV2 = null  # Store layer being dragged locally
var _drag_start_position: Vector2 = Vector2.ZERO
var _layer_start_position: Vector2 = Vector2.ZERO

# Segment dragging for connectors (adjusting path bends)
var _dragging_segment: bool = false
var _segment_connector: LayerV2 = null
var _segment_index: int = -1
var _segment_is_horizontal: bool = false

# Endpoint dragging for connectors (reconnecting to different anchors)
var _dragging_endpoint: bool = false
var _endpoint_connector: LayerV2 = null
var _endpoint_is_source: bool = false  # True = dragging source, False = dragging target
var _endpoint_preview_line: Line2D = null

# Diagram shape text editing
var _editing_diagram_shape: LayerV2 = null
var _diagram_text_edit: LineEdit = null

const SEGMENT_HIT_RADIUS = 10.0


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)


func handle_input_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			return _handle_mouse_down(event)
		else:
			return _handle_mouse_up(event)

	elif event is InputEventMouseMotion and (_is_dragging or _dragging_endpoint or _dragging_segment):
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

	# Check for segment handle click on selected connectors (for adjusting bends)
	var segment_hit = _get_segment_at_position()
	if segment_hit.connector:
		_start_segment_drag(segment_hit.connector, segment_hit.segment_index, segment_hit.is_horizontal)
		return true

	# Check for endpoint handle click on selected connectors (for reconnecting)
	var endpoint_hit = _get_endpoint_at_position()
	if endpoint_hit.connector:
		_start_endpoint_drag(endpoint_hit.connector, endpoint_hit.is_source)
		return true

	# First, check if clicking on a TEXT layer's handle (prioritize these)
	var text_layer_with_handle = _get_text_layer_with_handle_at_position()
	if text_layer_with_handle:
		_start_drag(event, text_layer_with_handle)
		return true

	# Find layer under cursor (for non-TEXT layers or TEXT layers clicked outside handle)
	var clicked_layer = _get_layer_at_position()

	# Also check for connector line hit (connectors have sparse bounds)
	if not clicked_layer:
		clicked_layer = _get_connector_at_position()

	if clicked_layer:
		# For non-TEXT layers, can start dragging anywhere on the layer
		if clicked_layer.type != LayerV2.Type.TEXT:
			_start_drag(event, clicked_layer)
			return true
	else:
		# Clicked on empty space - clear connector selection
		_clear_connector_selection()

	return true


func _handle_mouse_up(_event: InputEventMouseButton) -> bool:
	if _dragging_segment:
		_finish_segment_drag()
		return true

	if _dragging_endpoint:
		_finish_endpoint_drag()
		return true

	if _is_dragging:
		_is_dragging = false
		_dragging_layer = null
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return true
	return false


func _handle_drag(event: InputEventMouseMotion) -> bool:
	# Handle segment dragging - move the segment orthogonally
	if _dragging_segment and _segment_connector:
		var _delta = event.screen_relative * editor.PAN_FACTOR * (1.0 / editor.input_area_camera.zoom.x)
		_move_segment(_delta)
		return true

	# Handle endpoint dragging - update preview line
	if _dragging_endpoint and _endpoint_connector:
		if _endpoint_preview_line:
			var cursor_pos = editor.last_pointer_pos
			_endpoint_preview_line.set_point_position(1, cursor_pos)
		_endpoint_connector.queue_redraw()
		return true

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
	# Check if hovering over a segment handle (for adjusting bends)
	var segment_hit = _get_segment_at_position()
	if segment_hit.connector:
		# Show appropriate cursor based on segment orientation
		if segment_hit.is_horizontal:
			editor.set_custom_cursor(null, Input.CURSOR_VSIZE)  # Vertical resize for horizontal segment
		else:
			editor.set_custom_cursor(null, Input.CURSOR_HSIZE)  # Horizontal resize for vertical segment
		return

	# Check if hovering over an endpoint handle (for reconnection)
	var endpoint_hit = _get_endpoint_at_position()
	if endpoint_hit.connector:
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)
		return

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

	# For connectors, set transform_rect_visible to show waypoint handles
	if layer.type == LayerV2.Type.DIAGRAM_CONNECTOR:
		# Clear previous connector selection
		_clear_connector_selection()
		layer.transform_rect_visible = true
		layer.queue_redraw()


func _clear_connector_selection() -> void:
	# Clear transform_rect_visible on any previously selected connectors
	for child in editor.layers_container.get_children():
		if child is LayerV2 and child.type == LayerV2.Type.DIAGRAM_CONNECTOR:
			if child.transform_rect_visible:
				child.transform_rect_visible = false
				child.queue_redraw()


func _get_connector_at_position() -> LayerV2:
	# Check if mouse is near a connector line (not just in bounds)
	var container_mouse = editor.last_pointer_pos
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_CONNECTOR and layer.visible:
			var path = layer.get_connector_path()
			if path.size() >= 2 and _point_near_path(container_mouse, path, 10.0):
				return layer
	return null


func _point_near_path(point: Vector2, path: PackedVector2Array, threshold: float) -> bool:
	for i in range(1, path.size()):
		if _point_near_line(point, path[i - 1], path[i], threshold):
			return true
	return false


func _point_near_line(point: Vector2, line_start: Vector2, line_end: Vector2, threshold: float) -> bool:
	var line_vec = line_end - line_start
	var line_len = line_vec.length()
	if line_len < 0.001:
		return point.distance_to(line_start) < threshold

	var line_dir = line_vec / line_len
	var point_vec = point - line_start
	var projection = point_vec.dot(line_dir)
	projection = clamp(projection, 0, line_len)
	var closest = line_start + line_dir * projection

	return point.distance_to(closest) < threshold


func _get_layer_at_position() -> LayerV2:
	# Check layers in reverse order (top layer first)
	# Use same approach as TextTool: get mouse in layers_container space, then transform to layer space
	var layers = editor.layers_container.get_children()
	var container_mouse = editor.last_pointer_pos
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
	var container_mouse = editor.last_pointer_pos
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
	var container_mouse = editor.last_pointer_pos
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
	var container_mouse = editor.last_pointer_pos
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


## Check if mouse is over an endpoint handle (source or target) on any selected connector
func _get_endpoint_at_position() -> Dictionary:
	var container_mouse = editor.last_pointer_pos
	var endpoint_hit_radius = 15.0  # Larger hit area for endpoints

	for child in editor.layers_container.get_children():
		if child is LayerV2 and child.type == LayerV2.Type.DIAGRAM_CONNECTOR and child.transform_rect_visible:
			var path = child.get_connector_path()
			if path.size() >= 2:
				# Check source endpoint
				if container_mouse.distance_to(path[0]) < endpoint_hit_radius:
					return {"connector": child, "is_source": true}
				# Check target endpoint
				if container_mouse.distance_to(path[path.size() - 1]) < endpoint_hit_radius:
					return {"connector": child, "is_source": false}

	return {"connector": null, "is_source": false}


## Start dragging an endpoint to reconnect it
func _start_endpoint_drag(connector: LayerV2, is_source: bool) -> void:
	_dragging_endpoint = true
	_endpoint_connector = connector
	_endpoint_is_source = is_source
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)

	# Create preview line
	var path = connector.get_connector_path()
	if path.size() >= 2:
		_endpoint_preview_line = Line2D.new()
		_endpoint_preview_line.width = connector.connector_line_width
		_endpoint_preview_line.default_color = Color(connector.connector_line_color, 0.5)

		# Start from the fixed end, draw to cursor
		var fixed_pos: Vector2
		if is_source:
			fixed_pos = path[path.size() - 1]  # Target is fixed
		else:
			fixed_pos = path[0]  # Source is fixed

		var cursor_pos = editor.last_pointer_pos
		_endpoint_preview_line.add_point(fixed_pos)
		_endpoint_preview_line.add_point(cursor_pos)
		editor.layers_container.add_child(_endpoint_preview_line)


## Finish endpoint drag - reconnect to new anchor if over one
func _finish_endpoint_drag() -> void:
	# Clean up preview line
	if _endpoint_preview_line:
		_endpoint_preview_line.queue_free()
		_endpoint_preview_line = null

	if not _endpoint_connector:
		_dragging_endpoint = false
		return

	var container_mouse = editor.last_pointer_pos

	# Check if over an anchor point
	var hit = _get_anchor_at_position(container_mouse)

	if hit.layer:
		# Don't allow connecting to self (both endpoints on same shape)
		var other_layer: LayerV2
		if _endpoint_is_source:
			other_layer = _endpoint_connector._target_layer_ref.get_ref() if _endpoint_connector._target_layer_ref else null
		else:
			other_layer = _endpoint_connector._source_layer_ref.get_ref() if _endpoint_connector._source_layer_ref else null

		if hit.layer != other_layer:
			# Reconnect the endpoint
			if _endpoint_is_source:
				_reconnect_source(hit.layer, hit.anchor)
			else:
				_reconnect_target(hit.layer, hit.anchor)

	_dragging_endpoint = false
	_endpoint_connector.queue_redraw()
	_endpoint_connector = null
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)


## Get anchor point at position (for endpoint reconnection)
func _get_anchor_at_position(pos: Vector2) -> Dictionary:
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_SHAPE and layer.visible:
			for anchor in [LayerV2.AnchorPoint.TOP, LayerV2.AnchorPoint.RIGHT,
						   LayerV2.AnchorPoint.BOTTOM, LayerV2.AnchorPoint.LEFT]:
				var anchor_pos = layer.position + layer.get_anchor_position(anchor)
				if pos.distance_to(anchor_pos) < 15.0:
					return {"layer": layer, "anchor": anchor}
	return {"layer": null, "anchor": null}


## Reconnect connector source to new layer/anchor
func _reconnect_source(new_layer: LayerV2, new_anchor: LayerV2.AnchorPoint) -> void:
	var connector = _endpoint_connector

	# Disconnect from old source
	var old_source = connector._source_layer_ref.get_ref() if connector._source_layer_ref else null
	if old_source and old_source.shape_moved.is_connected(connector._on_connected_shape_moved):
		old_source.shape_moved.disconnect(connector._on_connected_shape_moved)

	# Connect to new source
	connector._source_layer_ref = weakref(new_layer)
	connector.connector_source_layer_id = new_layer.get_instance_id()
	connector.connector_source_anchor = new_anchor
	new_layer.shape_moved.connect(connector._on_connected_shape_moved)

	# Clear manual waypoints so path recalculates with new anchor
	connector.connector_manual_waypoints = PackedVector2Array()

	connector._update_connector_bounds()


## Reconnect connector target to new layer/anchor
func _reconnect_target(new_layer: LayerV2, new_anchor: LayerV2.AnchorPoint) -> void:
	var connector = _endpoint_connector

	# Disconnect from old target
	var old_target = connector._target_layer_ref.get_ref() if connector._target_layer_ref else null
	if old_target and old_target.shape_moved.is_connected(connector._on_connected_shape_moved):
		old_target.shape_moved.disconnect(connector._on_connected_shape_moved)

	# Connect to new target
	connector._target_layer_ref = weakref(new_layer)
	connector.connector_target_layer_id = new_layer.get_instance_id()
	connector.connector_target_anchor = new_anchor
	new_layer.shape_moved.connect(connector._on_connected_shape_moved)

	# Clear manual waypoints so path recalculates with new anchor
	connector.connector_manual_waypoints = PackedVector2Array()

	connector._update_connector_bounds()


## Check if mouse is over a segment midpoint handle on any selected connector
func _get_segment_at_position() -> Dictionary:
	var container_mouse = editor.last_pointer_pos

	# Check connectors that have transform_rect_visible set (selected)
	for child in editor.layers_container.get_children():
		if child is LayerV2 and child.type == LayerV2.Type.DIAGRAM_CONNECTOR and child.transform_rect_visible:
			var path = child.get_connector_path()
			# Check all segment midpoints (skip first and last segments which are endpoint handles)
			for i in range(path.size() - 1):
				var start = path[i]
				var end = path[i + 1]
				var midpoint = (start + end) / 2
				if container_mouse.distance_to(midpoint) < SEGMENT_HIT_RADIUS:
					# Determine if horizontal or vertical segment
					var is_horizontal = abs(end.y - start.y) < abs(end.x - start.x)
					return {"connector": child, "segment_index": i, "is_horizontal": is_horizontal}

	return {"connector": null, "segment_index": -1, "is_horizontal": false}


## Start dragging a segment to adjust the connector path
func _start_segment_drag(connector: LayerV2, segment_index: int, is_horizontal: bool) -> void:
	_dragging_segment = true
	_segment_connector = connector
	_segment_index = segment_index
	_segment_is_horizontal = is_horizontal

	# Initialize manual waypoints if this is the first edit
	if connector.connector_manual_waypoints.size() == 0:
		# Copy current auto-calculated path (excluding source/target endpoints)
		var path = connector.get_connector_path()
		var manual: PackedVector2Array = []
		for i in range(1, path.size() - 1):
			manual.append(path[i])
		connector.connector_manual_waypoints = manual

	if is_horizontal:
		editor.set_custom_cursor(null, Input.CURSOR_VSIZE)
	else:
		editor.set_custom_cursor(null, Input.CURSOR_HSIZE)


## Move the currently dragged segment orthogonally
func _move_segment(delta: Vector2) -> void:
	if not _segment_connector or _segment_index < 0:
		return

	# Constrain movement based on segment orientation
	var constrained_delta: Vector2
	if _segment_is_horizontal:
		# Horizontal segment can only move vertically
		constrained_delta = Vector2(0, delta.y)
	else:
		# Vertical segment can only move horizontally
		constrained_delta = Vector2(delta.x, 0)

	var manual = _segment_connector.connector_manual_waypoints
	#var path = _segment_connector.get_connector_path()

	# Segment i connects path[i] to path[i+1]
	# Manual waypoints are the middle points: path[1] to path[size-2]
	# So manual[j] = path[j+1], meaning path index = manual index + 1

	# For segment i:
	#   start = path[i], end = path[i+1]
	#   If i > 0, start is manual[i-1]
	#   If i+1 < path.size()-1, end is manual[i]

	var wp_start_idx = _segment_index - 1  # Index in manual waypoints for segment start
	var wp_end_idx = _segment_index        # Index in manual waypoints for segment end

	# Move the waypoints that define this segment
	if wp_start_idx >= 0 and wp_start_idx < manual.size():
		manual[wp_start_idx] += constrained_delta
	if wp_end_idx >= 0 and wp_end_idx < manual.size():
		manual[wp_end_idx] += constrained_delta

	_segment_connector.connector_manual_waypoints = manual
	_segment_connector._update_connector_bounds()


## Finish segment drag
func _finish_segment_drag() -> void:
	if _segment_connector:
		_segment_connector._update_connector_bounds()

	_dragging_segment = false
	_segment_connector = null
	_segment_index = -1
	editor.set_custom_cursor(null, Input.CURSOR_ARROW)
