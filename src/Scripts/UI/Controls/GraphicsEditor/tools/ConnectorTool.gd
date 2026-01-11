class_name ConnectorTool
extends BaseTool

## A tool for creating connectors between diagram shape anchor points

@export var line_color_picker: ColorPickerButton
@export var line_width_slider: Slider
@export var arrow_type_option: OptionButton

var _is_drawing: bool = false
var _source_layer: LayerV2 = null
var _source_anchor: LayerV2.AnchorPoint
var _preview_line_start: Vector2 = Vector2.ZERO
var _preview_line_end: Vector2 = Vector2.ZERO
var _preview_line: Line2D = null

const ANCHOR_HIT_RADIUS = 15.0


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func handle_input_event(event: InputEvent) -> bool:
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			return _handle_mouse_down(canvas_local_mouse_pos)
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


func _handle_mouse_down(pos: Vector2) -> bool:
	# Check if clicking on an anchor point
	var hit = _get_anchor_at_position(pos)
	if hit.layer:
		_is_drawing = true
		_source_layer = hit.layer
		_source_anchor = hit.anchor
		_preview_line_start = hit.layer.position + hit.layer.get_anchor_position(hit.anchor)
		_preview_line_end = pos

		# Create preview line
		var line_color = line_color_picker.color if line_color_picker else Color(0.53, 0.81, 0.92)
		var line_width = int(line_width_slider.value) if line_width_slider else 2

		_preview_line = Line2D.new()
		_preview_line.width = line_width
		_preview_line.default_color = line_color
		_preview_line.add_point(_preview_line_start)
		_preview_line.add_point(_preview_line_end)
		editor.layers_container.add_child(_preview_line)

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

	# Check if releasing on an anchor point
	var hit = _get_anchor_at_position(pos)
	if hit.layer and hit.layer != _source_layer:
		# Get connector settings
		var arrow_type = LayerV2.ArrowHeadType.SINGLE
		if arrow_type_option:
			arrow_type = arrow_type_option.selected as LayerV2.ArrowHeadType

		var line_color = line_color_picker.color if line_color_picker else Color(0.53, 0.81, 0.92)
		var line_width = int(line_width_slider.value) if line_width_slider else 2

		# Create connector
		var connector = LayerV2.create_diagram_connector(
			"Connector",
			_source_layer,
			_source_anchor,
			hit.layer,
			hit.anchor,
			line_color,
			line_width,
			arrow_type
		)

		editor.add_layer(connector)

		# Finalize connector bounds after it's in the tree
		_finalize_connector.call_deferred(connector)

	_source_layer = null
	return true


func _finalize_connector(connector: LayerV2) -> void:
	connector._update_connector_bounds()
	connector.queue_redraw()


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


func _update_cursor_for_anchor(pos: Vector2) -> void:
	var hit = _get_anchor_at_position(pos)
	if hit.layer:
		editor.set_custom_cursor(null, Input.CURSOR_POINTING_HAND)
	else:
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)
