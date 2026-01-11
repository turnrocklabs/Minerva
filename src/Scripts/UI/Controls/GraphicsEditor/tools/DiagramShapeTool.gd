class_name DiagramShapeTool
extends BaseTool

## A tool for creating and editing diagram shapes (rectangle, ellipse, diamond)

@export var shape_type_option: OptionButton
@export var stroke_color_picker: ColorPickerButton
@export var fill_color_picker: ColorPickerButton
@export var stroke_width_slider: Slider
@export var stroke_enabled_check: CheckBox
@export var fill_enabled_check: CheckBox
# Text formatting controls
@export var text_size_spin_box: SpinBox
@export var text_color_picker: ColorPickerButton
@export var bold_check: CheckBox
@export var italic_check: CheckBox
@export var underline_check: CheckBox
@export var strikethrough_check: CheckBox

var _is_drawing: bool = false
var _start_position: Vector2 = Vector2.ZERO
var _current_position: Vector2 = Vector2.ZERO
var _preview_layer: LayerV2 = null

# Selection and dragging (like SelectTool)
var _selected_layer: LayerV2 = null
var _is_dragging: bool = false
var _drag_start_position: Vector2 = Vector2.ZERO

# Diagram shape text editing (inline)
var _editing_diagram_shape: LayerV2 = null
var _diagram_text_edit: LineEdit = null

# Track if we've connected toolbar signals
var _toolbar_signals_connected: bool = false

# Map option button index to shape type
const SHAPE_MAP = [
	LayerV2.DiagramShapeType.RECTANGLE,
	LayerV2.DiagramShapeType.ELLIPSE,
	LayerV2.DiagramShapeType.DIAMOND,
]


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)
	_selected_layer = null
	_connect_toolbar_signals()


func _tool_deselected() -> void:
	_selected_layer = null


func _connect_toolbar_signals() -> void:
	if _toolbar_signals_connected:
		return
	_toolbar_signals_connected = true

	# Connect shape property controls
	if stroke_color_picker and not stroke_color_picker.color_changed.is_connected(_on_stroke_color_changed):
		stroke_color_picker.color_changed.connect(_on_stroke_color_changed)
	if fill_color_picker and not fill_color_picker.color_changed.is_connected(_on_fill_color_changed):
		fill_color_picker.color_changed.connect(_on_fill_color_changed)
	if stroke_width_slider and not stroke_width_slider.value_changed.is_connected(_on_stroke_width_changed):
		stroke_width_slider.value_changed.connect(_on_stroke_width_changed)
	if stroke_enabled_check and not stroke_enabled_check.toggled.is_connected(_on_stroke_enabled_toggled):
		stroke_enabled_check.toggled.connect(_on_stroke_enabled_toggled)
	if fill_enabled_check and not fill_enabled_check.toggled.is_connected(_on_fill_enabled_toggled):
		fill_enabled_check.toggled.connect(_on_fill_enabled_toggled)

	# Connect text formatting controls
	if text_size_spin_box and not text_size_spin_box.value_changed.is_connected(_on_text_size_changed):
		text_size_spin_box.value_changed.connect(_on_text_size_changed)
	if text_color_picker and not text_color_picker.color_changed.is_connected(_on_text_color_changed):
		text_color_picker.color_changed.connect(_on_text_color_changed)
	if bold_check and not bold_check.toggled.is_connected(_on_bold_toggled):
		bold_check.toggled.connect(_on_bold_toggled)
	if italic_check and not italic_check.toggled.is_connected(_on_italic_toggled):
		italic_check.toggled.connect(_on_italic_toggled)
	if underline_check and not underline_check.toggled.is_connected(_on_underline_toggled):
		underline_check.toggled.connect(_on_underline_toggled)
	if strikethrough_check and not strikethrough_check.toggled.is_connected(_on_strikethrough_toggled):
		strikethrough_check.toggled.connect(_on_strikethrough_toggled)


func handle_input_event(event: InputEvent) -> bool:
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			return _handle_mouse_down(event, canvas_local_mouse_pos)
		else:
			return _handle_mouse_up(event)

	elif event is InputEventMouseMotion:
		if _is_drawing:
			return _handle_mouse_drag(event, canvas_local_mouse_pos)
		elif _is_dragging:
			return _handle_selection_drag(event)
		else:
			_update_cursor(event)
			return false

	return false


func _handle_mouse_down(event: InputEventMouseButton, pos: Vector2) -> bool:
	# Check for double-click on existing DIAGRAM_SHAPE to edit text
	if event.double_click:
		var diagram_layer = _get_diagram_shape_at_position()
		if diagram_layer:
			_start_diagram_text_edit(diagram_layer)
			return true

	# If clicking elsewhere while editing diagram shape text, commit the edit
	if _editing_diagram_shape != null:
		_commit_diagram_text()

	# Check if clicking on an existing diagram shape (for selection/dragging)
	var clicked_layer = _get_diagram_shape_at_position()
	if clicked_layer:
		_select_layer(clicked_layer)
		# Start dragging the selected shape
		_is_dragging = true
		_drag_start_position = pos
		editor.set_custom_cursor(null, Input.CURSOR_MOVE)
		return true

	# Clicking on empty space - deselect and start drawing new shape
	_select_layer(null)

	_is_drawing = true
	_start_position = pos
	_current_position = pos

	# Get shape settings
	var shape_type = SHAPE_MAP[shape_type_option.selected] if shape_type_option else LayerV2.DiagramShapeType.RECTANGLE
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var fill_color = fill_color_picker.color if fill_color_picker else Color.TRANSPARENT
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	# Apply enable/disable checkboxes
	if stroke_enabled_check and not stroke_enabled_check.button_pressed:
		stroke_color = Color.TRANSPARENT
	if fill_enabled_check and not fill_enabled_check.button_pressed:
		fill_color = Color.TRANSPARENT

	# Create preview layer
	_preview_layer = LayerV2.create_diagram_shape(
		"Preview",
		shape_type,
		Vector2(10, 10),
		stroke_color,
		fill_color,
		stroke_width
	)
	_preview_layer.position = pos
	_preview_layer.outline_visible = false
	editor.layers_container.add_child(_preview_layer)
	_preview_layer.queue_redraw()

	return true


func _handle_mouse_drag(_event: InputEventMouseMotion, pos: Vector2) -> bool:
	_current_position = pos

	# Hold Shift to constrain to square/circle
	if Input.is_key_pressed(KEY_SHIFT):
		var delta = _current_position - _start_position
		var max_dim = max(abs(delta.x), abs(delta.y))
		_current_position = _start_position + Vector2(
			sign(delta.x) * max_dim if delta.x != 0 else max_dim,
			sign(delta.y) * max_dim if delta.y != 0 else max_dim
		)

	# Update preview layer
	if _preview_layer:
		var rect = _calculate_rect(_start_position, _current_position)
		_preview_layer.position = rect.position
		_preview_layer.size = rect.size
		_preview_layer.custom_minimum_size = rect.size
		_preview_layer.pivot_offset = rect.size / 2
		_preview_layer.queue_redraw()

	return true


func _handle_mouse_up(_event: InputEventMouseButton) -> bool:
	# Handle drag completion
	if _is_dragging:
		_is_dragging = false
		editor.set_custom_cursor(null, Input.CURSOR_ARROW)
		return true

	if not _is_drawing:
		return false

	_is_drawing = false

	var rect = _calculate_rect(_start_position, _current_position)

	# Remove preview
	if _preview_layer:
		_preview_layer.queue_free()
		_preview_layer = null

	# Don't create if too small
	if rect.size.x < 20 or rect.size.y < 20:
		return true

	# Get shape settings
	var shape_type = SHAPE_MAP[shape_type_option.selected] if shape_type_option else LayerV2.DiagramShapeType.RECTANGLE
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var fill_color = fill_color_picker.color if fill_color_picker else Color.TRANSPARENT
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	# Apply enable/disable checkboxes
	if stroke_enabled_check and not stroke_enabled_check.button_pressed:
		stroke_color = Color.TRANSPARENT
	if fill_enabled_check and not fill_enabled_check.button_pressed:
		fill_color = Color.TRANSPARENT

	# Create the actual layer
	var shape_name = "Diagram: " + ["Rectangle", "Ellipse", "Diamond"][shape_type]
	var layer = LayerV2.create_diagram_shape(
		shape_name,
		shape_type,
		rect.size,
		stroke_color,
		fill_color,
		stroke_width
	)

	# Add to editor first (this triggers _ready)
	editor.add_layer(layer)

	# Defer position/size setup to after tree is ready
	_finalize_layer_position.call_deferred(layer, rect)

	return true


func _finalize_layer_position(layer: LayerV2, rect: Rect2) -> void:
	layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	layer.size = rect.size
	layer.position = rect.position
	layer.pivot_offset = rect.size / 2
	layer.queue_redraw()


func _calculate_rect(start: Vector2, end: Vector2) -> Rect2:
	var min_pos = Vector2(min(start.x, end.x), min(start.y, end.y))
	var max_pos = Vector2(max(start.x, end.x), max(start.y, end.y))
	return Rect2(min_pos, max_pos - min_pos)


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

	# Create LineEdit if needed
	if _diagram_text_edit == null:
		_diagram_text_edit = LineEdit.new()
		_diagram_text_edit.placeholder_text = "Enter text..."
		_diagram_text_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
		_diagram_text_edit.text_submitted.connect(_on_diagram_text_submitted)
		_diagram_text_edit.focus_exited.connect(_on_diagram_text_focus_exited)
		editor.add_child(_diagram_text_edit)

	# Pre-populate with existing text
	_diagram_text_edit.text = layer.diagram_text_content

	# Populate UI controls with layer's current formatting
	if text_size_spin_box:
		text_size_spin_box.value = layer.diagram_text_font_size
	if text_color_picker:
		text_color_picker.color = layer.diagram_text_color
	if bold_check:
		bold_check.button_pressed = layer.diagram_text_bold
	if italic_check:
		italic_check.button_pressed = layer.diagram_text_italic
	if underline_check:
		underline_check.button_pressed = layer.diagram_text_underline
	if strikethrough_check:
		strikethrough_check.button_pressed = layer.diagram_text_strikethrough

	# Position the LineEdit centered on the shape
	# Convert layer center to editor local coordinates
	var layer_center = layer.position + layer.size / 2
	var screen_pos = editor.layers_container.get_global_transform() * layer_center
	var editor_local = editor.get_global_transform().affine_inverse() * screen_pos

	# Size the LineEdit to match shape width (with some padding)
	var edit_width = max(150, layer.size.x * editor.input_area_camera.zoom.x - 20)
	_diagram_text_edit.custom_minimum_size = Vector2(edit_width, 30)
	_diagram_text_edit.position = editor_local - Vector2(edit_width / 2, 15)

	_diagram_text_edit.visible = true
	_diagram_text_edit.grab_focus()
	_diagram_text_edit.select_all()


func _commit_diagram_text() -> void:
	if _editing_diagram_shape == null or _diagram_text_edit == null:
		return

	# Update the layer's text content
	_editing_diagram_shape.diagram_text_content = _diagram_text_edit.text

	# Apply text formatting from controls
	if text_size_spin_box:
		_editing_diagram_shape.diagram_text_font_size = int(text_size_spin_box.value)
	if text_color_picker:
		_editing_diagram_shape.diagram_text_color = text_color_picker.color
	if bold_check:
		_editing_diagram_shape.diagram_text_bold = bold_check.button_pressed
	if italic_check:
		_editing_diagram_shape.diagram_text_italic = italic_check.button_pressed
	if underline_check:
		_editing_diagram_shape.diagram_text_underline = underline_check.button_pressed
	if strikethrough_check:
		_editing_diagram_shape.diagram_text_strikethrough = strikethrough_check.button_pressed

	_editing_diagram_shape.queue_redraw()

	# Cleanup
	_diagram_text_edit.visible = false
	_diagram_text_edit.text = ""
	_editing_diagram_shape = null


func _on_diagram_text_submitted(_text: String) -> void:
	_commit_diagram_text()


func _on_diagram_text_focus_exited() -> void:
	# Small delay to allow for other interactions
	if _editing_diagram_shape != null:
		_commit_diagram_text()


# Selection and dragging functions

func _select_layer(layer: LayerV2) -> void:
	_selected_layer = layer
	if layer:
		_populate_toolbar_from_layer(layer)


func _handle_selection_drag(event: InputEventMouseMotion) -> bool:
	if not _selected_layer:
		_is_dragging = false
		return false

	# Move the selected layer
	var delta = event.screen_relative * editor.PAN_FACTOR * (1.0 / editor.input_area_camera.zoom.x)
	_selected_layer.position += delta

	editor.queue_redraw()
	_selected_layer.queue_redraw()
	return true


func _update_cursor(_event: InputEventMouseMotion) -> void:
	var layer = _get_diagram_shape_at_position()
	if layer:
		editor.set_custom_cursor(null, Input.CURSOR_MOVE)
	else:
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func _populate_toolbar_from_layer(layer: LayerV2) -> void:
	# Populate shape properties
	if stroke_color_picker:
		stroke_color_picker.color = layer.diagram_stroke_color
	if fill_color_picker:
		fill_color_picker.color = layer.diagram_fill_color
	if stroke_width_slider:
		stroke_width_slider.value = layer.diagram_stroke_width
	if stroke_enabled_check:
		stroke_enabled_check.button_pressed = layer.diagram_stroke_color.a > 0
	if fill_enabled_check:
		fill_enabled_check.button_pressed = layer.diagram_fill_color.a > 0

	# Populate text properties
	if text_size_spin_box:
		text_size_spin_box.value = layer.diagram_text_font_size
	if text_color_picker:
		text_color_picker.color = layer.diagram_text_color
	if bold_check:
		bold_check.button_pressed = layer.diagram_text_bold
	if italic_check:
		italic_check.button_pressed = layer.diagram_text_italic
	if underline_check:
		underline_check.button_pressed = layer.diagram_text_underline
	if strikethrough_check:
		strikethrough_check.button_pressed = layer.diagram_text_strikethrough


# Toolbar change callbacks - apply immediately to selected layer

func _on_stroke_color_changed(color: Color) -> void:
	if _selected_layer:
		_selected_layer.diagram_stroke_color = color
		_selected_layer.queue_redraw()


func _on_fill_color_changed(color: Color) -> void:
	if _selected_layer:
		_selected_layer.diagram_fill_color = color
		_selected_layer.queue_redraw()


func _on_stroke_width_changed(value: float) -> void:
	if _selected_layer:
		_selected_layer.diagram_stroke_width = int(value)
		_selected_layer.queue_redraw()


func _on_stroke_enabled_toggled(pressed: bool) -> void:
	if _selected_layer:
		if pressed:
			# Restore color from picker
			if stroke_color_picker:
				_selected_layer.diagram_stroke_color = stroke_color_picker.color
		else:
			_selected_layer.diagram_stroke_color = Color.TRANSPARENT
		_selected_layer.queue_redraw()


func _on_fill_enabled_toggled(pressed: bool) -> void:
	if _selected_layer:
		if pressed:
			# Restore color from picker
			if fill_color_picker:
				_selected_layer.diagram_fill_color = fill_color_picker.color
		else:
			_selected_layer.diagram_fill_color = Color.TRANSPARENT
		_selected_layer.queue_redraw()


func _on_text_size_changed(value: float) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_font_size = int(value)
		_selected_layer.queue_redraw()


func _on_text_color_changed(color: Color) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_color = color
		_selected_layer.queue_redraw()


func _on_bold_toggled(pressed: bool) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_bold = pressed
		_selected_layer.queue_redraw()


func _on_italic_toggled(pressed: bool) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_italic = pressed
		_selected_layer.queue_redraw()


func _on_underline_toggled(pressed: bool) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_underline = pressed
		_selected_layer.queue_redraw()


func _on_strikethrough_toggled(pressed: bool) -> void:
	if _selected_layer:
		_selected_layer.diagram_text_strikethrough = pressed
		_selected_layer.queue_redraw()
