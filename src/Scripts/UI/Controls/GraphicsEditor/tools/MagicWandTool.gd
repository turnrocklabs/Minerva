class_name MagicWandTool
extends BaseTool

func _ready() -> void:
	super()
	editor.active_tool_changed.connect(_on_tool_changed)

func _on_tool_changed(tool_: BaseTool) -> void:
	if tool_ == self:
		# Use crosshair cursor for precision
		editor.set_custom_cursor(null)
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			event = editor.active_layer.localize_input(event)
			_delete_contiguous_area(event.position)
			return true
	return false

func _delete_contiguous_area(position: Vector2) -> void:
	var point := Vector2i(position.round())
	var image := editor.active_layer.image
	var size := image.get_size()

	if point.x < 0 or point.x >= size.x or point.y < 0 or point.y >= size.y:
		return

	var target_color := image.get_pixelv(point)

	# Don't delete if already transparent
	if target_color.a < 0.01:
		return

	# Create undo command - captures "before" state
	var command = GraphicsEditorUndo.DrawStrokeCommand.new(editor.active_layer)

	# Scanline flood fill (adapted from BucketTool)
	var stack := [point]

	while stack.size() > 0:
		var p = stack.pop_back()
		var x = p.x
		var y = p.y

		# Find leftmost pixel of this color on this row
		while x >= 0 and _colors_match(image.get_pixel(x, y), target_color):
			x -= 1
		x += 1

		var span_above := false
		var span_below := false

		# Process the scanline
		while x < size.x and _colors_match(image.get_pixel(x, y), target_color):
			image.set_pixel(x, y, Color.TRANSPARENT)

			# Check pixel above
			if not span_above and y > 0 and _colors_match(image.get_pixel(x, y - 1), target_color):
				stack.push_back(Vector2i(x, y - 1))
				span_above = true
			elif span_above and y > 0 and not _colors_match(image.get_pixel(x, y - 1), target_color):
				span_above = false

			# Check pixel below
			if not span_below and y < size.y - 1 and _colors_match(image.get_pixel(x, y + 1), target_color):
				stack.push_back(Vector2i(x, y + 1))
				span_below = true
			elif span_below and y < size.y - 1 and not _colors_match(image.get_pixel(x, y + 1), target_color):
				span_below = false

			x += 1

	# Finalize and execute command
	command.finalize_stroke()
	editor.execute_command(command)
	editor.active_layer.queue_redraw()

func _colors_match(c1: Color, c2: Color) -> bool:
	# Exact match for now (could add tolerance later)
	return c1 == c2
