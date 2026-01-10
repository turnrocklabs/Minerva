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

# Font paths
const FONTS = [
	"res://assets/fonts/CascadiaCode/CascadiaCode.ttf",
	"res://assets/fonts/CascadiaCode/static/CascadiaCode-Bold.ttf",
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
		return

	_create_text_layer(text)


func _cancel_editing() -> void:
	if _inline_edit:
		_inline_edit.visible = false
		_inline_edit.text = ""
	_is_editing = false


func _create_text_layer(text: String) -> void:
	# Get current options
	var font = _get_selected_font()
	var font_size = int(font_size_spin_box.value) if font_size_spin_box else 48
	var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	# Render text to Image
	var image = await _render_text_to_image(text, font, font_size, fill_color, stroke_color, stroke_width)

	if image == null or image.is_empty():
		push_error("TextTool: Failed to render text to image")
		return

	# Calculate target position before any async operations
	var padding = stroke_width + 4
	var target_position = _placement_position - Vector2(padding, padding)
	var image_size = image.get_size()

	# Create layer and add to editor
	var layer = LayerV2.create_image_layer("Text: " + text.left(20), image)
	editor.add_layer(layer)

	# Wait for the async image setter to complete (it awaits process_frame internally)
	# Note: Don't await layer.ready - it already fired when add_layer() added it to tree
	for i in range(3):
		await editor.get_tree().process_frame

	# Force TOP_LEFT anchors on both layer and texture_rect so position/size work correctly
	# (Without this, offsets are interpreted as margins from stretched anchors)
	layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	layer.position = target_position
	layer.size = Vector2(image_size)

	layer.texture_rect.set_anchors_preset(Control.PRESET_TOP_LEFT)
	layer.texture_rect.position = Vector2.ZERO
	layer.texture_rect.size = Vector2(image_size)

	# Use a one-shot timer as a final safeguard
	var timer = editor.get_tree().create_timer(0.1)
	timer.timeout.connect(func():
		layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
		layer.position = target_position
		layer.size = Vector2(image_size)
		layer.texture_rect.set_anchors_preset(Control.PRESET_TOP_LEFT)
		layer.texture_rect.position = Vector2.ZERO
		layer.texture_rect.size = Vector2(image_size)
	)


func _render_text_to_image(text: String, font: Font, size: int,
						   fill: Color, stroke: Color, stroke_width: int) -> Image:
	# Handle multiline text - filter out empty lines
	var lines = text.split("\n")
	var text_lines: Array[TextLine] = []
	var total_height: float = 0
	var max_width: float = 0
	var line_heights: Array[float] = []

	for line in lines:
		if line.strip_edges().is_empty():
			continue  # Skip empty lines
		var tl = TextLine.new()
		tl.add_string(line, font, size)
		text_lines.append(tl)
		var line_size = tl.get_size()
		max_width = max(max_width, line_size.x)
		total_height += line_size.y
		line_heights.append(line_size.y)

	# Safety check - if no valid lines, create a placeholder
	if text_lines.is_empty():
		var tl = TextLine.new()
		tl.add_string(text, font, size)
		text_lines.append(tl)
		var line_size = tl.get_size()
		max_width = line_size.x
		total_height = line_size.y
		line_heights.append(line_size.y)

	# Calculate image size with padding for stroke
	var padding = stroke_width + 4  # Extra padding for safety
	var img_width = int(max_width) + padding * 2
	var img_height = int(total_height) + padding * 2

	# Ensure minimum size
	img_width = max(img_width, 10)
	img_height = max(img_height, 10)

	# Render via viewport
	return await _render_via_viewport(text_lines, line_heights, img_width, img_height, padding,
									 fill, stroke, stroke_width, font, size, text)


func _render_via_viewport(text_lines: Array[TextLine], line_heights: Array[float],
						  width: int, height: int, padding: int,
						  fill: Color, stroke: Color, stroke_width: int,
						  font: Font, font_size: int, text: String) -> Image:
	# Create temporary SubViewport
	var viewport = SubViewport.new()
	viewport.size = Vector2i(width, height)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Create Control to draw on - use position/size directly (anchors don't work well in SubViewport)
	var draw_control = Control.new()
	draw_control.position = Vector2.ZERO
	draw_control.size = Vector2(width, height)

	# Use a one-shot draw - try draw_string instead of TextLine
	draw_control.draw.connect(func():
		var pos = Vector2(padding, padding + text_lines[0].get_line_ascent())
		print("TextTool: Using draw_string at pos=", pos, " font=", font, " text=", text)
		# Use Control's draw_string method instead of TextLine.draw
		if stroke_width > 0:
			draw_control.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, stroke_width, stroke)
		draw_control.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fill)
	)

	viewport.add_child(draw_control)
	editor.get_tree().root.add_child(viewport)

	# Force a redraw and wait for render
	draw_control.queue_redraw()

	# Wait for render - need frames to ensure the viewport renders
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	# Capture image
	var image = viewport.get_texture().get_image()

	# Note: flip_y removed - testing if it's needed
	print("TextTool: Captured image size=", image.get_size())

	# Cleanup
	viewport.queue_free()

	return image


func _get_selected_font() -> Font:
	var idx = font_option_button.selected if font_option_button else 0
	if idx >= 0 and idx < FONTS.size():
		return load(FONTS[idx])
	return ThemeDB.fallback_font
