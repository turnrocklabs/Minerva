class_name RectangleTool
extends BaseTool

## A tool for drawing rectangles with optional stroke and fill.

@export var stroke_color_picker: ColorPickerButton
@export var fill_color_picker: ColorPickerButton
@export var stroke_width_slider: Slider
@export var stroke_enabled_check: CheckBox
@export var fill_enabled_check: CheckBox

var _is_drawing: bool = false
var _start_position: Vector2 = Vector2.ZERO
var _current_position: Vector2 = Vector2.ZERO
var _preview_rect: Rect2 = Rect2()
var _layer_backup: Image = null  # Backup for live preview

# Performance: throttle preview updates
var _last_preview_msec: int = 0
const PREVIEW_INTERVAL_MS: int = 32  # ~30fps for preview


func _tool_selected() -> void:
	editor.set_custom_cursor(null, Input.CURSOR_CROSS)


func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer:
		return false

	# Localize the event to layer coordinates
	var local_event = editor.active_layer.localize_input(event)

	if local_event is InputEventMouseButton and local_event.button_index == MOUSE_BUTTON_LEFT:
		if local_event.is_pressed():
			return _handle_mouse_down(local_event)
		else:
			return _handle_mouse_up(local_event)

	elif local_event is InputEventMouseMotion and _is_drawing:
		return _handle_mouse_drag(local_event)

	return false


func _handle_mouse_down(event: InputEventMouseButton) -> bool:
	_is_drawing = true
	_start_position = event.position
	_current_position = event.position
	_update_preview_rect()

	# Save backup for live preview
	if editor.active_layer and editor.active_layer.image:
		_layer_backup = editor.active_layer.image.duplicate()

	return true


func _handle_mouse_drag(event: InputEventMouseMotion) -> bool:
	_current_position = event.position

	# Hold Shift to constrain to square
	if Input.is_key_pressed(KEY_SHIFT):
		var delta = _current_position - _start_position
		var max_dim = max(abs(delta.x), abs(delta.y))
		_current_position = _start_position + Vector2(
			sign(delta.x) * max_dim if delta.x != 0 else max_dim,
			sign(delta.y) * max_dim if delta.y != 0 else max_dim
		)

	_update_preview_rect()

	# Throttle preview updates for performance
	var now = Time.get_ticks_msec()
	if now - _last_preview_msec < PREVIEW_INTERVAL_MS:
		return true
	_last_preview_msec = now

	# Draw live preview: restore backup then draw rectangle
	if _layer_backup and editor.active_layer and editor.active_layer.image:
		# Restore from backup
		editor.active_layer.image.blit_rect(_layer_backup, Rect2i(Vector2i.ZERO, _layer_backup.get_size()), Vector2i.ZERO)
		# Draw preview rectangle (skip selection check for speed)
		_draw_rectangle_to_image(editor.active_layer.image, _preview_rect, true)
		editor.active_layer.queue_redraw()

	return true


func _handle_mouse_up(_event: InputEventMouseButton) -> bool:
	if not _is_drawing:
		return false

	_is_drawing = false

	# Restore from backup before drawing final result
	if _layer_backup and editor.active_layer and editor.active_layer.image:
		editor.active_layer.image.blit_rect(_layer_backup, Rect2i(Vector2i.ZERO, _layer_backup.get_size()), Vector2i.ZERO)

	# Don't draw if rectangle is too small
	if _preview_rect.size.x < 1 or _preview_rect.size.y < 1:
		_preview_rect = Rect2()
		_layer_backup = null
		editor.queue_redraw()
		return true

	# Draw the final rectangle to the layer
	_draw_rectangle_to_layer()

	_preview_rect = Rect2()
	_layer_backup = null
	editor.queue_redraw()
	return true


func _update_preview_rect() -> void:
	# Calculate normalized rect (handles negative sizes from dragging in any direction)
	var min_pos = Vector2(
		min(_start_position.x, _current_position.x),
		min(_start_position.y, _current_position.y)
	)
	var max_pos = Vector2(
		max(_start_position.x, _current_position.x),
		max(_start_position.y, _current_position.y)
	)
	_preview_rect = Rect2(min_pos, max_pos - min_pos)


func _draw_rectangle_to_layer() -> void:
	var layer = editor.active_layer
	if not layer or not layer.image:
		return

	_draw_rectangle_to_image(layer.image, _preview_rect)
	layer.queue_redraw()


func _draw_rectangle_to_image(img: Image, rect: Rect2, preview_only: bool = false) -> void:
	var stroke_enabled = stroke_enabled_check.button_pressed if stroke_enabled_check else true
	var fill_enabled = fill_enabled_check.button_pressed if fill_enabled_check else false
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	# During preview, only draw stroke outline (skip fill for performance)
	if preview_only:
		# Draw a 1px outline for fast preview
		_draw_outline(img, rect, stroke_color if stroke_enabled else fill_color)
		return

	# Final draw: fill first (if enabled)
	if fill_enabled:
		_fill_rect(img, rect, fill_color, false)

	# Draw stroke on top (if enabled)
	if stroke_enabled:
		_stroke_rect(img, rect, stroke_color, stroke_width, false)


func _draw_outline(img: Image, rect: Rect2, color: Color) -> void:
	var img_size = img.get_size()
	var x1 = int(max(0, rect.position.x))
	var y1 = int(max(0, rect.position.y))
	var x2 = int(min(img_size.x - 1, rect.end.x))
	var y2 = int(min(img_size.y - 1, rect.end.y))

	# Draw horizontal lines (top and bottom)
	for x in range(x1, x2 + 1):
		if y1 >= 0 and y1 < img_size.y:
			img.set_pixel(x, y1, color)
		if y2 >= 0 and y2 < img_size.y and y2 != y1:
			img.set_pixel(x, y2, color)

	# Draw vertical lines (left and right)
	for y in range(y1 + 1, y2):
		if x1 >= 0 and x1 < img_size.x:
			img.set_pixel(x1, y, color)
		if x2 >= 0 and x2 < img_size.x and x2 != x1:
			img.set_pixel(x2, y, color)


func _fill_rect(img: Image, rect: Rect2, color: Color, skip_selection_check: bool = false) -> void:
	var img_size = img.get_size()
	var start_x = int(max(0, rect.position.x))
	var start_y = int(max(0, rect.position.y))
	var end_x = int(min(img_size.x, rect.end.x))
	var end_y = int(min(img_size.y, rect.end.y))

	# Fast path: use fill_rect when no selection check needed and color is opaque
	if skip_selection_check and color.a >= 0.99:
		img.fill_rect(Rect2i(start_x, start_y, end_x - start_x, end_y - start_y), color)
		return

	# Slow path: pixel-by-pixel with selection check and blending
	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			if skip_selection_check or editor.is_pixel_selected(x, y):
				img.set_pixel(x, y, _blend_color(img.get_pixel(x, y), color))


func _stroke_rect(img: Image, rect: Rect2, color: Color, width: int, skip_selection_check: bool = false) -> void:
	# Draw four sides of the rectangle with the given stroke width
	# Top edge
	_fill_rect(img, Rect2(rect.position.x, rect.position.y, rect.size.x, width), color, skip_selection_check)
	# Bottom edge
	_fill_rect(img, Rect2(rect.position.x, rect.end.y - width, rect.size.x, width), color, skip_selection_check)
	# Left edge
	_fill_rect(img, Rect2(rect.position.x, rect.position.y, width, rect.size.y), color, skip_selection_check)
	# Right edge
	_fill_rect(img, Rect2(rect.end.x - width, rect.position.y, width, rect.size.y), color, skip_selection_check)


func _blend_color(bottom: Color, top: Color) -> Color:
	if top.a >= 0.99:
		return top
	if top.a <= 0.01:
		return bottom

	var one_minus_top_a = 1.0 - top.a
	var bottom_factor = bottom.a * one_minus_top_a
	var a = 1.0 - one_minus_top_a * (1.0 - bottom.a)

	if a < 0.01:
		return Color(0, 0, 0, 0)

	var inv_a = 1.0 / a
	var r = (top.r * top.a + bottom.r * bottom_factor) * inv_a
	var g = (top.g * top.a + bottom.g * bottom_factor) * inv_a
	var b = (top.b * top.a + bottom.b * bottom_factor) * inv_a

	return Color(r, g, b, a)
