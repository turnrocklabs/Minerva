class_name ConnectorTool
extends BaseTool

## A tool for creating connectors between diagram shape anchor points

@export var line_color_picker: ColorPickerButton
@export var line_width_slider: Slider
@export var arrow_type_option: OptionButton
@export var text_size_spin_box: SpinBox
@export var text_color_picker: ColorPickerButton

var _is_drawing: bool = false
var _source_layer: LayerV2 = null
var _source_anchor: LayerV2.AnchorPoint
var _source_anchor_explicit: bool = false  # True if user clicked directly on anchor
var _preview_line_start: Vector2 = Vector2.ZERO
var _preview_line_end: Vector2 = Vector2.ZERO
var _preview_line: Line2D = null

# Text editing state
var _editing_connector: LayerV2 = null
var _connector_text_edit: LineEdit = null

const ANCHOR_HIT_RADIUS = 15.0


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func handle_input_event(event: InputEvent) -> bool:
	var canvas_local_mouse_pos = editor.last_pointer_pos

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			return _handle_mouse_down(event, canvas_local_mouse_pos)
		else:
			return _handle_mouse_up(canvas_local_mouse_pos)

	elif event is InputEventMouseMotion:
		if _is_drawing:
			_preview_line_end = canvas_local_mouse_pos
			# Update preview line
			if _preview_line:
				_preview_line.set_point_position(1, _preview_line_end)
			return true
		else:
			_update_cursor_for_anchor(canvas_local_mouse_pos)
			return false

	return false


func _handle_mouse_down(event: InputEventMouseButton, pos: Vector2) -> bool:
	# Check for double-click on existing connector to edit text
	if event.double_click:
		var connector = _get_connector_at_position(pos)
		if connector:
			_start_connector_text_edit(connector)
			return true

	# If clicking elsewhere while editing connector text, commit the edit
	if _editing_connector != null:
		_commit_connector_text()

	# First, check if clicking directly on an anchor point (precise mode)
	var hit = _get_anchor_at_position(pos)
	if hit.layer:
		_is_drawing = true
		_source_layer = hit.layer
		_source_anchor = hit.anchor
		_source_anchor_explicit = true  # User explicitly chose this anchor
		_preview_line_start = hit.layer.position + hit.layer.get_anchor_position(hit.anchor)
		_preview_line_end = pos
		_create_preview_line()
		return true

	# Fall back: clicking anywhere on a shape uses nearest anchor
	var shape = _get_shape_at_position(pos)
	if shape:
		_is_drawing = true
		_source_layer = shape
		_source_anchor = _get_nearest_anchor(shape, pos)
		_source_anchor_explicit = false  # Auto-selected, can be overridden
		_preview_line_start = shape.position + shape.get_anchor_position(_source_anchor)
		_preview_line_end = pos
		_create_preview_line()
		return true

	return false


func _handle_mouse_up(pos: Vector2) -> bool:
	if not _is_drawing:
		return false

	_is_drawing = false

	# Remove preview line
	if _preview_line:
		_preview_line.queue_free()
		_preview_line = null

	# First, check if releasing on an anchor point (precise mode)
	var hit = _get_anchor_at_position(pos)
	var target_layer: LayerV2 = null
	var target_anchor: LayerV2.AnchorPoint

	if hit.layer and hit.layer != _source_layer:
		target_layer = hit.layer
		target_anchor = hit.anchor
	else:
		# Fall back: releasing on a shape uses best anchor facing the source
		var shape = _get_shape_at_position(pos)
		if shape and shape != _source_layer:
			target_layer = shape
			# Use the anchor that faces toward the source shape
			var source_center = _source_layer.position + _source_layer.size / 2
			target_anchor = _get_best_anchor_for_connection(shape, source_center)

	if target_layer:
		# Get connector settings
		var arrow_type = LayerV2.ArrowHeadType.SINGLE
		if arrow_type_option:
			arrow_type = arrow_type_option.selected as LayerV2.ArrowHeadType

		var line_color = line_color_picker.color if line_color_picker else Color(0.53, 0.81, 0.92)
		var line_width = int(line_width_slider.value) if line_width_slider else 2

		# Only use smart routing for source if user didn't explicitly select an anchor
		if not _source_anchor_explicit:
			var target_center = target_layer.position + target_layer.size / 2
			_source_anchor = _get_best_anchor_for_connection(_source_layer, target_center)

		# Create connector
		var connector = LayerV2.create_diagram_connector(
			"Connector",
			_source_layer,
			_source_anchor,
			target_layer,
			target_anchor,
			line_color,
			line_width,
			arrow_type
		)

		editor.add_layer(connector)

		# Finalize connector bounds after it's in the tree
		_finalize_connector.call_deferred(connector)

	_source_layer = null
	_source_anchor_explicit = false
	return true


func _finalize_connector(connector: LayerV2) -> void:
	connector._update_connector_bounds()
	connector.queue_redraw()


func _create_preview_line() -> void:
	var line_color = line_color_picker.color if line_color_picker else Color(0.53, 0.81, 0.92)
	var line_width = int(line_width_slider.value) if line_width_slider else 2

	_preview_line = Line2D.new()
	_preview_line.width = line_width
	_preview_line.default_color = line_color
	_preview_line.add_point(_preview_line_start)
	_preview_line.add_point(_preview_line_end)
	editor.layers_container.add_child(_preview_line)


func _get_anchor_at_position(pos: Vector2) -> Dictionary:
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_SHAPE:
			for anchor in [LayerV2.AnchorPoint.TOP, LayerV2.AnchorPoint.RIGHT,
						   LayerV2.AnchorPoint.BOTTOM, LayerV2.AnchorPoint.LEFT]:
				var anchor_pos = layer.position + layer.get_anchor_position(anchor)
				if pos.distance_to(anchor_pos) < ANCHOR_HIT_RADIUS:
					return {"layer": layer, "anchor": anchor}
	return {"layer": null, "anchor": null}


func _get_shape_at_position(pos: Vector2) -> LayerV2:
	## Returns a DIAGRAM_SHAPE layer if pos is within its bounds
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_SHAPE and layer.visible:
			var local_pos = layer.get_transform().affine_inverse() * pos
			if Rect2(Vector2.ZERO, layer.size).has_point(local_pos):
				return layer
	return null


func _get_nearest_anchor(shape: LayerV2, from_point: Vector2) -> LayerV2.AnchorPoint:
	## Returns the anchor point on shape that is closest to from_point
	var anchors = [LayerV2.AnchorPoint.TOP, LayerV2.AnchorPoint.RIGHT,
				   LayerV2.AnchorPoint.BOTTOM, LayerV2.AnchorPoint.LEFT]
	var nearest_anchor = anchors[0]
	var nearest_distance = INF

	for anchor in anchors:
		var anchor_pos = shape.position + shape.get_anchor_position(anchor)
		var dist = from_point.distance_to(anchor_pos)
		if dist < nearest_distance:
			nearest_distance = dist
			nearest_anchor = anchor

	return nearest_anchor


func _get_best_anchor_for_connection(shape: LayerV2, other_shape_center: Vector2) -> LayerV2.AnchorPoint:
	## Returns the anchor that faces toward the other shape's center
	## This creates more intuitive connector routing
	var shape_center = shape.position + shape.size / 2
	var direction = other_shape_center - shape_center

	# Pick anchor based on which direction is dominant
	if abs(direction.x) > abs(direction.y):
		# Horizontal connection
		return LayerV2.AnchorPoint.RIGHT if direction.x > 0 else LayerV2.AnchorPoint.LEFT
	else:
		# Vertical connection
		return LayerV2.AnchorPoint.BOTTOM if direction.y > 0 else LayerV2.AnchorPoint.TOP


func _update_cursor_for_anchor(pos: Vector2) -> void:
	var hit = _get_anchor_at_position(pos)
	if hit.layer:
		editor.set_custom_cursor(null, Input.CURSOR_POINTING_HAND)
	else:
		# Check if over a shape (for nearest anchor mode)
		var shape = _get_shape_at_position(pos)
		if shape:
			editor.set_custom_cursor(null, Input.CURSOR_POINTING_HAND)
		else:
			# Check if over a connector
			var connector = _get_connector_at_position(pos)
			if connector:
				editor.set_custom_cursor(null, Input.CURSOR_POINTING_HAND)
			else:
				editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func _get_connector_at_position(pos: Vector2) -> LayerV2:
	# Check layers for DIAGRAM_CONNECTOR type
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.DIAGRAM_CONNECTOR and layer.visible:
			# Check if point is near the connector path (works with manual waypoints too)
			var path = layer.get_connector_path()
			if path.size() >= 2 and _point_near_path(pos, path, 10.0):
				return layer
	return null


func _point_near_path(point: Vector2, path: PackedVector2Array, threshold: float) -> bool:
	# Check if point is near any segment of the path
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

	# Clamp to line segment
	projection = clamp(projection, 0, line_len)
	var closest = line_start + line_dir * projection

	return point.distance_to(closest) < threshold


func _start_connector_text_edit(connector: LayerV2) -> void:
	_editing_connector = connector

	# Create LineEdit if needed (add to layers_container so it appears on canvas)
	if _connector_text_edit == null:
		_connector_text_edit = LineEdit.new()
		_connector_text_edit.placeholder_text = "Type..."
		_connector_text_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
		_connector_text_edit.flat = true
		_connector_text_edit.expand_to_text_length = true
		_connector_text_edit.custom_minimum_size = Vector2(50, 0)

		# Minimal style with subtle background
		var style = StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, 0.9)
		style.set_corner_radius_all(2)
		_connector_text_edit.add_theme_stylebox_override("normal", style)
		_connector_text_edit.add_theme_stylebox_override("focus", style)

		_connector_text_edit.text_submitted.connect(_on_connector_text_submitted)
		editor.layers_container.add_child(_connector_text_edit)

	# Pre-populate with existing text
	_connector_text_edit.text = connector.connector_text_content

	# Populate UI controls with connector's current formatting
	if text_size_spin_box:
		text_size_spin_box.value = connector.connector_text_font_size
	if text_color_picker:
		text_color_picker.color = connector.connector_text_color

	# Style the LineEdit to match the text settings
	_update_connector_text_edit_style()

	# Position at midpoint of connector line
	var source = connector._source_layer_ref.get_ref() if connector._source_layer_ref else null
	var target = connector._target_layer_ref.get_ref() if connector._target_layer_ref else null
	if source and target:
		var source_pos = source.position + source.get_anchor_position(connector.connector_source_anchor)
		var target_pos = target.position + target.get_anchor_position(connector.connector_target_anchor)
		var midpoint = (source_pos + target_pos) / 2
		_connector_text_edit.position = midpoint

	_connector_text_edit.visible = true
	_connector_text_edit.grab_focus()
	_connector_text_edit.select_all()

	# Center the LineEdit (deferred to get correct size)
	_center_connector_text_edit.call_deferred(connector)


func _center_connector_text_edit(connector: LayerV2) -> void:
	if _connector_text_edit and connector:
		var source = connector._source_layer_ref.get_ref() if connector._source_layer_ref else null
		var target = connector._target_layer_ref.get_ref() if connector._target_layer_ref else null
		if source and target:
			var source_pos = source.position + source.get_anchor_position(connector.connector_source_anchor)
			var target_pos = target.position + target.get_anchor_position(connector.connector_target_anchor)
			var midpoint = (source_pos + target_pos) / 2
			var edit_size = _connector_text_edit.size
			_connector_text_edit.position = midpoint - edit_size / 2


func _update_connector_text_edit_style() -> void:
	if not _connector_text_edit:
		return

	var font = ThemeDB.get_fallback_font()
	var font_size = int(text_size_spin_box.value) if text_size_spin_box else 12
	var text_color = text_color_picker.color if text_color_picker else Color.BLACK

	_connector_text_edit.add_theme_font_override("font", font)
	_connector_text_edit.add_theme_font_size_override("font_size", font_size)
	_connector_text_edit.add_theme_color_override("font_color", text_color)
	_connector_text_edit.add_theme_color_override("font_placeholder_color", Color(text_color, 0.5))
	_connector_text_edit.add_theme_color_override("caret_color", text_color)


func _commit_connector_text() -> void:
	if _editing_connector == null or _connector_text_edit == null:
		return

	# Update the connector's text content
	_editing_connector.connector_text_content = _connector_text_edit.text

	# Apply text formatting from controls
	if text_size_spin_box:
		_editing_connector.connector_text_font_size = int(text_size_spin_box.value)
	if text_color_picker:
		_editing_connector.connector_text_color = text_color_picker.color

	_editing_connector.queue_redraw()

	# Cleanup
	_connector_text_edit.visible = false
	_connector_text_edit.text = ""
	_editing_connector = null


func _on_connector_text_submitted(_text: String) -> void:
	_commit_connector_text()
