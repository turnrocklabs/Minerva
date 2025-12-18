class_name RectangleSelectTool
extends BaseTool

enum SelectionMode { REPLACE, ADD, SUBTRACT, INTERSECT }

var selection_mode: SelectionMode = SelectionMode.REPLACE
var _is_dragging: bool = false
var _start_position: Vector2
var _current_position: Vector2

func _ready() -> void:
	super()
	editor.active_tool_changed.connect(_on_tool_changed)

func _on_tool_changed(tool_: BaseTool) -> void:
	if tool_ == self:
		# Use crosshair cursor for precision
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)
	else:
		# Cancel any in-progress selection when switching away
		_is_dragging = false

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		event = editor.active_layer.localize_input(event)

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

			_is_dragging = true
			_start_position = event.position
			_current_position = event.position
			editor.selection_overlay.queue_redraw()
			return true
		else:
			# Mouse released - finalize selection
			if _is_dragging:
				_is_dragging = false
				_current_position = event.position
				_create_rectangle_selection()
				editor.selection_overlay.queue_redraw()
				return true

	elif event is InputEventMouseMotion and _is_dragging:
		event = editor.active_layer.localize_input(event)
		_current_position = event.position
		editor.selection_overlay.queue_redraw()
		return true

	return false

func _create_rectangle_selection() -> void:
	var image := editor.active_layer.image
	var size := image.get_size()

	# Calculate rectangle bounds
	var rect = _get_selection_rect()

	# Clamp to image bounds
	var x1 = clampi(int(rect.position.x), 0, size.x - 1)
	var y1 = clampi(int(rect.position.y), 0, size.y - 1)
	var x2 = clampi(int(rect.end.x), 0, size.x)
	var y2 = clampi(int(rect.end.y), 0, size.y)

	if x2 <= x1 or y2 <= y1:
		return  # Invalid selection

	# Create temporary mask for this selection operation
	var new_selection = Image.create(size.x, size.y, false, Image.FORMAT_L8)
	new_selection.fill(Color.BLACK)

	# Fill the rectangle
	for y in range(y1, y2):
		for x in range(x1, x2):
			new_selection.set_pixel(x, y, Color.WHITE)

	# Apply selection mode with bounding box for optimization
	_apply_selection(new_selection, Vector2i(x1, y1), Vector2i(x2 - 1, y2 - 1))

func _apply_selection(new_mask: Image, bbox_min: Vector2i = Vector2i.ZERO, bbox_max: Vector2i = Vector2i.ZERO) -> void:
	var size = new_mask.get_size()

	# Ensure editor has a selection mask
	if not editor.selection_mask or editor.selection_mask.get_size() != size:
		editor.create_selection_mask(size)

	# Use bounding box to limit iteration (much faster for small selections)
	var x_start = bbox_min.x if bbox_min != Vector2i.ZERO else 0
	var y_start = bbox_min.y if bbox_min != Vector2i.ZERO else 0
	var x_end = bbox_max.x + 1 if bbox_max != Vector2i.ZERO else size.x
	var y_end = bbox_max.y + 1 if bbox_max != Vector2i.ZERO else size.y

	# Clamp to valid range
	x_start = clampi(x_start, 0, size.x)
	y_start = clampi(y_start, 0, size.y)
	x_end = clampi(x_end, 0, size.x)
	y_end = clampi(y_end, 0, size.y)

	match selection_mode:
		SelectionMode.REPLACE:
			# For replace, just copy the new mask directly
			editor.selection_mask = new_mask.duplicate()
		SelectionMode.ADD:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.WHITE)
		SelectionMode.SUBTRACT:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)
		SelectionMode.INTERSECT:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r < 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)

	# Update the selection cache after modifying the mask
	editor._update_selection_cache()
	editor.selection_changed.emit()
	editor.selection_overlay.queue_redraw()

## Returns the selection rectangle (normalized so position is top-left)
func _get_selection_rect() -> Rect2:
	var x1 = min(_start_position.x, _current_position.x)
	var y1 = min(_start_position.y, _current_position.y)
	var x2 = max(_start_position.x, _current_position.x)
	var y2 = max(_start_position.y, _current_position.y)
	return Rect2(x1, y1, x2 - x1, y2 - y1)

## Returns true if currently dragging a selection rectangle
func is_selecting() -> bool:
	return _is_dragging

## Get the current selection rect for drawing preview
func get_preview_rect() -> Rect2:
	return _get_selection_rect()
