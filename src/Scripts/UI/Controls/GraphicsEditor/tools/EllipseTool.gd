class_name EllipseTool
extends BaseTool

## A tool for drawing ellipses/circles with optional stroke and fill.

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

	# Hold Shift to constrain to circle
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

	# Draw live preview: restore backup then draw ellipse
	if _layer_backup and editor.active_layer and editor.active_layer.image:
		# Restore from backup
		editor.active_layer.image.blit_rect(_layer_backup, Rect2i(Vector2i.ZERO, _layer_backup.get_size()), Vector2i.ZERO)
		# Draw preview ellipse (skip selection check for speed)
		_draw_ellipse_to_image(editor.active_layer.image, _preview_rect, true)
		editor.active_layer.queue_redraw()

	return true


func _handle_mouse_up(_event: InputEventMouseButton) -> bool:
	if not _is_drawing:
		return false

	_is_drawing = false

	# Restore from backup before drawing final result
	if _layer_backup and editor.active_layer and editor.active_layer.image:
		editor.active_layer.image.blit_rect(_layer_backup, Rect2i(Vector2i.ZERO, _layer_backup.get_size()), Vector2i.ZERO)

	# Don't draw if ellipse is too small
	if _preview_rect.size.x < 1 or _preview_rect.size.y < 1:
		_preview_rect = Rect2()
		_layer_backup = null
		editor.queue_redraw()
		return true

	# Draw the final ellipse to the layer
	_draw_ellipse_to_layer()

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


func _draw_ellipse_to_layer() -> void:
	var layer = editor.active_layer
	if not layer or not layer.image:
		return

	_draw_ellipse_to_image(layer.image, _preview_rect)
	layer.queue_redraw()


func _draw_ellipse_to_image(img: Image, rect: Rect2, preview_only: bool = false) -> void:
	var stroke_enabled = stroke_enabled_check.button_pressed if stroke_enabled_check else true
	var fill_enabled = fill_enabled_check.button_pressed if fill_enabled_check else false
	var stroke_color = stroke_color_picker.color if stroke_color_picker else Color.BLACK
	var fill_color = fill_color_picker.color if fill_color_picker else Color.WHITE
	var stroke_width = int(stroke_width_slider.value) if stroke_width_slider else 2

	var center = rect.position + rect.size / 2.0
	var radius_x = rect.size.x / 2.0
	var radius_y = rect.size.y / 2.0

	# During preview, only draw 1px outline (skip fill for performance)
	if preview_only:
		_draw_ellipse_outline(img, center, radius_x, radius_y, stroke_color if stroke_enabled else fill_color)
		return

	# Final draw: fill first (if enabled)
	if fill_enabled:
		_fill_ellipse(img, center, radius_x, radius_y, fill_color, false)

	# Draw stroke on top (if enabled)
	if stroke_enabled:
		_stroke_ellipse(img, center, radius_x, radius_y, stroke_color, stroke_width, false)


func _draw_ellipse_outline(img: Image, center: Vector2, radius_x: float, radius_y: float, color: Color) -> void:
	# Midpoint ellipse algorithm for fast 1px outline
	if radius_x <= 0 or radius_y <= 0:
		return

	var img_size = img.get_size()
	var cx = int(center.x)
	var cy = int(center.y)
	var rx = int(radius_x)
	var ry = int(radius_y)

	var rx2 = rx * rx
	var ry2 = ry * ry
	var two_rx2 = 2 * rx2
	var two_ry2 = 2 * ry2

	var x = 0
	var y = ry
	var px = 0
	var py = two_rx2 * y

	# Plot initial points
	_plot_ellipse_points(img, cx, cy, x, y, color, img_size)

	# Region 1
	var p = int(ry2 - (rx2 * ry) + (0.25 * rx2))
	while px < py:
		x += 1
		px += two_ry2
		if p < 0:
			p += ry2 + px
		else:
			y -= 1
			py -= two_rx2
			p += ry2 + px - py
		_plot_ellipse_points(img, cx, cy, x, y, color, img_size)

	# Region 2
	p = int(ry2 * (x + 0.5) * (x + 0.5) + rx2 * (y - 1) * (y - 1) - rx2 * ry2)
	while y > 0:
		y -= 1
		py -= two_rx2
		if p > 0:
			p += rx2 - py
		else:
			x += 1
			px += two_ry2
			p += rx2 - py + px
		_plot_ellipse_points(img, cx, cy, x, y, color, img_size)


func _plot_ellipse_points(img: Image, cx: int, cy: int, x: int, y: int, color: Color, img_size: Vector2i) -> void:
	var points = [
		Vector2i(cx + x, cy + y),
		Vector2i(cx - x, cy + y),
		Vector2i(cx + x, cy - y),
		Vector2i(cx - x, cy - y)
	]
	for p in points:
		if p.x >= 0 and p.x < img_size.x and p.y >= 0 and p.y < img_size.y:
			img.set_pixel(p.x, p.y, color)


func _fill_ellipse(img: Image, center: Vector2, radius_x: float, radius_y: float, color: Color, skip_selection_check: bool = false) -> void:
	if radius_x <= 0 or radius_y <= 0:
		return

	var img_size = img.get_size()
	var start_x = int(max(0, center.x - radius_x))
	var start_y = int(max(0, center.y - radius_y))
	var end_x = int(min(img_size.x, center.x + radius_x + 1))
	var end_y = int(min(img_size.y, center.y + radius_y + 1))

	# Pre-calculate for performance
	var rx_sq = radius_x * radius_x
	var ry_sq = radius_y * radius_y
	var opaque = color.a >= 0.99

	for y in range(start_y, end_y):
		var dy = y - center.y
		var dy_sq_scaled = (dy * dy) / ry_sq
		for x in range(start_x, end_x):
			# Check if point is inside ellipse: (x-cx)^2/rx^2 + (y-cy)^2/ry^2 <= 1
			var dx = x - center.x
			if (dx * dx) / rx_sq + dy_sq_scaled <= 1.0:
				if skip_selection_check or editor.is_pixel_selected(x, y):
					if opaque:
						img.set_pixel(x, y, color)
					else:
						img.set_pixel(x, y, _blend_color(img.get_pixel(x, y), color))


func _stroke_ellipse(img: Image, center: Vector2, radius_x: float, radius_y: float, color: Color, width: int, skip_selection_check: bool = false) -> void:
	if radius_x <= 0 or radius_y <= 0:
		return

	var img_size = img.get_size()
	var start_x = int(max(0, center.x - radius_x - width))
	var start_y = int(max(0, center.y - radius_y - width))
	var end_x = int(min(img_size.x, center.x + radius_x + width + 1))
	var end_y = int(min(img_size.y, center.y + radius_y + width + 1))

	# Inner ellipse radii (for stroke thickness)
	var inner_rx = max(0, radius_x - width)
	var inner_ry = max(0, radius_y - width)

	# Pre-calculate for performance
	var rx_sq = radius_x * radius_x
	var ry_sq = radius_y * radius_y
	var inner_rx_sq = inner_rx * inner_rx
	var inner_ry_sq = inner_ry * inner_ry
	var has_inner = inner_rx > 0 and inner_ry > 0
	var opaque = color.a >= 0.99

	for y in range(start_y, end_y):
		var dy = y - center.y
		var dy_sq = dy * dy
		var outer_dy_scaled = dy_sq / ry_sq
		var inner_dy_scaled = dy_sq / inner_ry_sq if has_inner else 0.0

		for x in range(start_x, end_x):
			var dx = x - center.x
			var dx_sq = dx * dx

			# Check if point is inside outer ellipse
			var outer_dist = dx_sq / rx_sq + outer_dy_scaled
			if outer_dist > 1.0:
				continue

			# Check if point is outside inner ellipse (or inner is zero)
			if has_inner:
				var inner_dist = dx_sq / inner_rx_sq + inner_dy_scaled
				if inner_dist <= 1.0:
					continue

			# Draw the stroke pixel
			if skip_selection_check or editor.is_pixel_selected(x, y):
				if opaque:
					img.set_pixel(x, y, color)
				else:
					img.set_pixel(x, y, _blend_color(img.get_pixel(x, y), color))


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
