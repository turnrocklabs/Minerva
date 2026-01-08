class_name MagicWandTool
extends BaseTool

enum SelectionMode { REPLACE, ADD, SUBTRACT, INTERSECT }

var selection_mode: SelectionMode = SelectionMode.REPLACE

func _ready() -> void:
	super()
	editor.active_tool_changed.connect(_on_tool_changed)

func _on_tool_changed(tool_: BaseTool) -> void:
	if tool_ == self:
		# Use magic wand icon as cursor with hotspot at bottom-left sparkle
		var cursor_texture = load("res://assets/icons/magic_wand.svg")
		var cursor_image = cursor_texture.get_image()
		cursor_image.resize(24, 24)
		editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, Vector2(5, 19))

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			# Determine selection mode from modifier keys
			if Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_ALT):
				selection_mode = SelectionMode.INTERSECT
			elif Input.is_key_pressed(KEY_SHIFT):
				selection_mode = SelectionMode.ADD
			elif Input.is_key_pressed(KEY_ALT):
				selection_mode = SelectionMode.SUBTRACT
			else:
				selection_mode = SelectionMode.REPLACE

			event = editor.active_layer.localize_input(event)
			_select_contiguous_area(event.position)
			return true
	return false

func _select_contiguous_area(position: Vector2) -> void:
	var point := Vector2i(position.round())
	var image := editor.active_layer.image
	var size := image.get_size()

	if point.x < 0 or point.x >= size.x or point.y < 0 or point.y >= size.y:
		return

	var target_color := image.get_pixelv(point)

	# Create temporary mask for this selection operation
	var new_selection = Image.create(size.x, size.y, false, Image.FORMAT_L8)
	new_selection.fill(Color.BLACK)

	# Track visited pixels to avoid infinite loops
	var visited = Image.create(size.x, size.y, false, Image.FORMAT_L8)
	visited.fill(Color.BLACK)

	# Scanline flood fill to mark selected pixels
	var stack := [point]
	while stack.size() > 0:
		var p = stack.pop_back()
		var x = p.x
		var y = p.y

		# Skip if already visited
		if visited.get_pixel(x, y).r > 0.5:
			continue

		# Find leftmost pixel of this color on this row
		while x >= 0 and _colors_match(image.get_pixel(x, y), target_color):
			x -= 1
		x += 1

		var span_above := false
		var span_below := false

		while x < size.x and _colors_match(image.get_pixel(x, y), target_color):
			new_selection.set_pixel(x, y, Color.WHITE)
			visited.set_pixel(x, y, Color.WHITE)

			if not span_above and y > 0:
				if _colors_match(image.get_pixel(x, y - 1), target_color) and visited.get_pixel(x, y - 1).r < 0.5:
					stack.push_back(Vector2i(x, y - 1))
					span_above = true
			elif span_above and y > 0:
				if not _colors_match(image.get_pixel(x, y - 1), target_color):
					span_above = false

			if not span_below and y < size.y - 1:
				if _colors_match(image.get_pixel(x, y + 1), target_color) and visited.get_pixel(x, y + 1).r < 0.5:
					stack.push_back(Vector2i(x, y + 1))
					span_below = true
			elif span_below and y < size.y - 1:
				if not _colors_match(image.get_pixel(x, y + 1), target_color):
					span_below = false

			x += 1

	# Apply selection mode
	_apply_selection(new_selection)

func _apply_selection(new_mask: Image) -> void:
	var size = new_mask.get_size()

	# Ensure editor has a selection mask
	if not editor.selection_mask or editor.selection_mask.get_size() != size:
		editor.create_selection_mask(size)

	match selection_mode:
		SelectionMode.REPLACE:
			editor.selection_mask = new_mask.duplicate()
		SelectionMode.ADD:
			for y in size.y:
				for x in size.x:
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.WHITE)
		SelectionMode.SUBTRACT:
			for y in size.y:
				for x in size.x:
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)
		SelectionMode.INTERSECT:
			for y in size.y:
				for x in size.x:
					if new_mask.get_pixel(x, y).r < 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)

	# Update the selection cache after modifying the mask
	editor._update_selection_cache()
	editor.selection_changed.emit()
	editor.selection_overlay.queue_redraw()

func _colors_match(c1: Color, c2: Color) -> bool:
	# Exact match for now (could add tolerance slider later)
	return c1 == c2
