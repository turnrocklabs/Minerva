class_name EyedropperTool
extends BaseTool

func _ready() -> void:
	super()
	editor.active_tool_changed.connect(_on_tool_changed)

func _on_tool_changed(tool_: BaseTool) -> void:
	if tool_ == self:
		# Use existing pipette icon as cursor
		var cursor_texture = load("res://assets/icons/color_picker_pipette.svg")
		var cursor_image = cursor_texture.get_image()
		cursor_image.resize(24, 24)
		editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, Vector2(0, 24))

func handle_input_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			# Transform position from editor space to viewport container space
			var viewport_container = editor.input_area_camera.get_viewport().get_parent()
			var local_pos = viewport_container.get_local_mouse_position()
			_sample_composited_color(local_pos)
			return true
	return false

func _sample_composited_color(viewport_pos: Vector2) -> void:
	# Get the SubViewport texture which shows all visible layers composited
	var viewport = editor.input_area_camera.get_viewport()
	var viewport_texture = viewport.get_texture()
	var image = viewport_texture.get_image()

	var pixel_pos = Vector2i(viewport_pos.round())

	if pixel_pos.x >= 0 and pixel_pos.x < image.get_width() and \
	   pixel_pos.y >= 0 and pixel_pos.y < image.get_height():
		var sampled_color = image.get_pixelv(pixel_pos)
		# Only update if we got a visible color (not fully transparent)
		if sampled_color.a > 0.01:
			editor.last_selected_color = sampled_color
			editor.color_picker_button.color = sampled_color
