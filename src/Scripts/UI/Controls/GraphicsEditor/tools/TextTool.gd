class_name TextTool
extends BaseTool

# Tool options (connected via @export)
@export var font_option_button: OptionButton
@export var font_size_spin_box: SpinBox
@export var fill_color_picker: ColorPickerButton
@export var stroke_color_picker: ColorPickerButton
@export var stroke_width_slider: Slider

# State
var _placement_position: Vector2 = Vector2.ZERO
var _inline_edit: LineEdit = null
var _is_editing: bool = false
var _editing_layer: LayerV2 = null  # Track which layer is being edited

# Font paths (alphabetical order)
const FONTS = [
	"res://assets/fonts/ArchitectsDaughter/ArchitectsDaughter-Regular.ttf",
	"res://assets/fonts/CascadiaCode/CascadiaCode.ttf",
	"res://assets/fonts/CascadiaCode/static/CascadiaCode-Bold.ttf",
	"res://assets/fonts/Caveat/Caveat-Variable.ttf",
	"res://assets/fonts/Mono_Space/SpaceMono-Regular.ttf",
	"res://assets/fonts/Mono_Space/SpaceMono-Bold.ttf",
]


func _ready() -> void:
	super._ready()
	# Connect to option changes to update preview while typing
	if font_option_button:
		font_option_button.item_selected.connect(_on_option_changed)
	if font_size_spin_box:
		font_size_spin_box.value_changed.connect(_on_option_changed)
	if fill_color_picker:
		fill_color_picker.color_changed.connect(_on_option_changed)


func _on_option_changed(_value = null) -> void:
	# Update inline edit style when options change
	if _is_editing and _inline_edit:
		_update_inline_edit_style()
		_inline_edit.grab_focus()  # Re-focus after clicking option


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_IBEAM)


func handle_input_event(event: InputEvent) -> bool:
	# Use layers_container local coordinates - this already accounts for camera transform
	var canvas_local_mouse_pos = editor.layers_container.get_local_mouse_position()

	# Handle Escape to cancel editing
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.is_pressed():
		if _is_editing:
			_cancel_editing()
			return true

	if !editor.layers_container.get_rect().has_point(canvas_local_mouse_pos):
		# Clicked outside canvas area - commit if editing
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
			if _is_editing:
				_commit_text()
				return true
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			# Check for double-click on existing TEXT layer
			if event.double_click:
				var clicked_layer = _get_text_layer_at_position(canvas_local_mouse_pos)
				if clicked_layer:
					_edit_existing_layer(clicked_layer)
					return true

			# If already editing, commit current text first
			if _is_editing:
				_commit_text()

			# Use canvas local coordinates directly (already in correct space for layer placement)
			_placement_position = canvas_local_mouse_pos
			_start_inline_edit()
			return true
	return false


func _start_inline_edit() -> void:
	_is_editing = true

	# Create inline LineEdit if needed
	if _inline_edit == null:
		_inline_edit = LineEdit.new()
		_inline_edit.placeholder_text = "Type here..."
		_inline_edit.flat = true
		_inline_edit.expand_to_text_length = true
		_inline_edit.custom_minimum_size = Vector2(150, 0)

		# Style it to be minimal but visible
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.3)
		style.set_corner_radius_all(4)
		_inline_edit.add_theme_stylebox_override("normal", style)
		_inline_edit.add_theme_stylebox_override("focus", style)

		# Connect signals - only text_submitted, NOT focus_exited
		_inline_edit.text_submitted.connect(_on_text_submitted)

		editor.layers_container.add_child(_inline_edit)

	# Position at click location
	_inline_edit.position = _placement_position

	# Style based on current settings
	_update_inline_edit_style()

	# Show and focus
	_inline_edit.text = ""
	_inline_edit.visible = true
	_inline_edit.grab_focus()


func _update_inline_edit_style() -> void:
	if not _inline_edit:
		return

	var font = _get_selected_font()
	var font_size = int(font_size_spin_box.value) if font_size_spin_box else 48
	var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE

	_inline_edit.add_theme_font_override("font", font)
	_inline_edit.add_theme_font_size_override("font_size", font_size)
	_inline_edit.add_theme_color_override("font_color", fill_color)
	_inline_edit.add_theme_color_override("font_placeholder_color", Color(fill_color, 0.5))
	_inline_edit.add_theme_color_override("caret_color", fill_color)


func _on_text_submitted(_new_text: String) -> void:
	_commit_text()


func _commit_text() -> void:
	if not _is_editing or not _inline_edit:
		return

	var text = _inline_edit.text.strip_edges()
	_inline_edit.visible = false
	_is_editing = false

	if text.is_empty():
		# If editing existing layer with empty text, delete the layer
		if _editing_layer:
			editor.remove_layer(_editing_layer)
			_editing_layer = null
		return

	if _editing_layer:
		# Update existing layer
		var font = _get_selected_font()
		var font_size = int(font_size_spin_box.value) if font_size_spin_box else 48
		var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE
		var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
		var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

		_editing_layer.set_text_properties(text, font, font_size, fill_color, stroke_color, stroke_width)
		_editing_layer.name = "Text: " + text.left(20)
		_editing_layer.visible = true  # Restore visibility
		_editing_layer = null
	else:
		# Create new layer
		_create_text_layer(text)


func _cancel_editing() -> void:
	if _inline_edit:
		_inline_edit.visible = false
		_inline_edit.text = ""
	_is_editing = false
	# Restore visibility of layer being edited
	if _editing_layer:
		_editing_layer.visible = true
		_editing_layer = null


## Find a TEXT layer at the given position (in layers_container local coords)
func _get_text_layer_at_position(pos: Vector2) -> LayerV2:
	# Check layers in reverse order (top layer first)
	var layers = editor.layers_container.get_children()
	for i in range(layers.size() - 1, -1, -1):
		var layer = layers[i]
		if layer is LayerV2 and layer.type == LayerV2.Type.TEXT:
			# pos is in layers_container space, layer is a child of layers_container
			# Use layer's transform to convert from parent space to layer local space
			var local_pos = layer.get_transform().affine_inverse() * pos
			if Rect2(Vector2.ZERO, layer.size).has_point(local_pos):
				return layer
	return null


## Start editing an existing TEXT layer
func _edit_existing_layer(layer: LayerV2) -> void:
	# Cancel any current editing first (from the single-click before double-click)
	if _is_editing and _inline_edit:
		_inline_edit.visible = false
		_inline_edit.text = ""
		_is_editing = false

	_editing_layer = layer
	# Position at the layer's top-left (where text starts with padding)
	_placement_position = layer.position

	# Pre-populate options from layer
	if font_size_spin_box:
		font_size_spin_box.value = layer.text_font_size
	if fill_color_picker:
		fill_color_picker.color = layer.text_fill_color
	if stroke_color_picker:
		stroke_color_picker.color = layer.text_stroke_color
	if stroke_width_slider:
		stroke_width_slider.value = layer.text_stroke_width

	_start_inline_edit()
	_inline_edit.text = layer.text_content
	# Hide the original layer while editing so we don't see double text
	layer.visible = false


func _create_text_layer(text: String) -> void:
	# Get current options
	var font = _get_selected_font()
	var font_size = int(font_size_spin_box.value) if font_size_spin_box else 48
	var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	# Create TEXT layer (not IMAGE layer)
	var layer = LayerV2.create_text_layer("Text: " + text.left(20), text, font,
										  font_size, fill_color, stroke_color, stroke_width)

	# Calculate size BEFORE adding to tree
	var padding = stroke_width + 4
	var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var layer_size = text_size + Vector2(padding * 2, padding * 2)

	# Add to editor first (this triggers _ready which sets anchors)
	editor.add_layer(layer)

	# Wait for tree to be ready
	await editor.get_tree().process_frame

	# Now set position and size AFTER _ready() has run
	layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	layer.size = layer_size
	layer.position = _placement_position
	layer.pivot_offset = layer_size / 2
	layer.queue_redraw()


func _get_selected_font() -> Font:
	var idx = font_option_button.selected if font_option_button else 0
	if idx >= 0 and idx < FONTS.size():
		return load(FONTS[idx])
	return ThemeDB.fallback_font
