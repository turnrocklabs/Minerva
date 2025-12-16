class_name DrawingTool
extends BaseTool

# Signals
signal pen_inverted_changed(is_inverted: bool)

# Minimum pressure for feather-light touches
const MIN_PRESSURE := 0.01

@export var _color_picker_button: ColorPickerButton
@export var _brush_size_slider: Slider

var brush_color: Color:
	set(value):
		brush_color = value
		if not _color_picker_button.is_node_ready():
			await _color_picker_button.ready
		_color_picker_button.color = value
	get:
		return _color_picker_button.color

var brush_size: int:
	set(value):
		brush_size = value
		if not _brush_size_slider.is_node_ready():
			await _brush_size_slider.ready
		_brush_size_slider.value = value
	get:
		return int(_brush_size_slider.value)

var auto_expand: = true

var drawing: = false
var _last_drawing_position: Vector2
var _last_pressure: float = 1.0
var _smoothed_pressure: float = 1.0
var _pressure_smoothing_factor: float = 0.3
var _single_click: bool = false
var _waiting_for_motion: bool = false
var _saw_motion: bool = false
var _use_pressure: bool = true  # false = treat as mouse/no-pressure this stroke
var _pen_inverted: bool = false  # Track current pen inverted state

# Performance optimizations
var _circle_cache = {}
var _max_cached_radius = 100

var current_stroke_command: GraphicsEditorUndo.DrawStrokeCommand

# Stroke buffer for preventing alpha accumulation within a single stroke
var _stroke_buffer: Image = null
var _stroke_brush_color: Color  # Store brush color at stroke start
var _layer_backup: Image = null  # Backup of layer for visual feedback during stroke

# Performance optimization: dirty rectangle tracking
var _stroke_dirty_rect: Rect2i = Rect2i()
var _last_preview_msec: int = 0
const PREVIEW_INTERVAL_MS: int = 16  # ~60fps throttle

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				var cursor_radius = roundi(brush_size / 2.0)
				var cursor_image = create_contrast_circle_cursor(cursor_radius)
				var hotspot = Vector2(cursor_image.get_width(), cursor_image.get_height()) / 2
				editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, hotspot)
	)

	_brush_size_slider.value_changed.connect(
		func(value: float):
			var cursor_radius = roundi(value / 2.0)
			var cursor_image = create_contrast_circle_cursor(cursor_radius)
			var hotspot = Vector2(cursor_image.get_width(), cursor_image.get_height()) / 2
			editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, hotspot)
	)
	
	# Pre-cache common brush sizes
	for r in range(1, min(30, _max_cached_radius)):
		_get_cached_circle_pixels(r)

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer: return false
	
	# Check for pen inverted state on any motion event (even when not drawing)
	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		var is_inverted = _is_pen_inverted(event)
		
		# Emit signal if pen inverted state changed
		if is_inverted != _pen_inverted:
			_pen_inverted = is_inverted
			pen_inverted_changed.emit(is_inverted)
			# Don't handle the event if we're switching to eraser
			if is_inverted:
				return false

	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				_start_stroke(event)
			elif event.is_released():
				_end_stroke(event)
			
			return true
	
	elif event is InputEventMouseMotion and drawing:
		_single_click = false
		_add_stroke_point(event)
		return true
	
	return false


func get_bounds_point_for_expansion(center: Vector2, radius: int) -> Vector2:
	var layer_size = editor.active_layer.image.get_size()
	var bounds_point = center
	
	if center.x > layer_size.x * 0.5:
		bounds_point.x += radius
	else:
		bounds_point.x -= radius
	
	if center.y > layer_size.y * 0.5:
		bounds_point.y += radius
	else:
		bounds_point.y -= radius
	
	return bounds_point

func get_actual_brush_radius(pressure: float) -> int:
	var camera_zoom = editor.input_area_camera.zoom.x
	# Divide by camera zoom to keep brush visually constant in screen pixels
	var actual_diameter = (brush_size * pressure) / camera_zoom
	var radius = int(ceil(actual_diameter * 0.5))
	return max(radius, 1)

func _pressure_from_event(ev: InputEvent) -> float:
	if ev is InputEventScreenDrag:
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	elif ev is InputEventMouseMotion:
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	elif ev is InputEventScreenTouch:
		# Some devices provide pressure on press/release
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	return 1.0  # Default to full pressure for unknown event types (mouse)

func _is_pen_inverted(event: InputEvent) -> bool:
	# Check if the pen is inverted (eraser end)
	if event is InputEventMouseMotion:
		return event.pen_inverted
	elif event is InputEventScreenDrag:
		return event.pen_inverted
	return false

func _start_stroke(event: InputEvent) -> void:
	drawing = true
	_single_click = true
	_last_drawing_position = event.position
	
	# Seed with a safe low default, or real pressure if this event has it (e.g., touch).
	var start_pressure := 0.1
	if event is InputEventScreenTouch: # touch has pressure on press
		start_pressure = clamp(event.pressure, MIN_PRESSURE, 1.0)
	
	_smoothed_pressure = start_pressure
	_last_pressure = start_pressure
	_waiting_for_motion = true
	_saw_motion = false
	_use_pressure = true
	
	# Handle layer expansion first (if needed)
	#var max_radius = get_actual_brush_radius(1.0)
	#var bounds_point = get_bounds_point_for_expansion(event.position, max_radius)
	#var offset = editor.active_layer.expand_to_point(bounds_point)
	#
	#if offset != Vector2.ZERO:
		## Create resize command for layer expansion
		#var resize_command = GraphicsEditorUndo.ResizeCommand.new(
			#editor.active_layer, 
			#editor.active_layer.position - offset
		#)
		#resize_command.set_new_image(editor.active_layer.image)  # After expansion
		#editor.execute_command(resize_command)
		#editor.active_layer.position -= offset
	
	# Update event after potential layer changes
	event = editor.active_layer.localize_input(event)
	_last_drawing_position = event.position
	
	# this needs to be calculated after the stroke has been finished
	# Create drawing command - captures "before" state
	# var stroke_bounds = _calculate_stroke_bounds(event.position)

	current_stroke_command = GraphicsEditorUndo.DrawStrokeCommand.new(editor.active_layer)

	# Initialize stroke buffer for preventing alpha accumulation
	var layer_size = editor.active_layer.image.get_size()
	_stroke_buffer = Image.create(layer_size.x, layer_size.y, false, Image.FORMAT_RGBA8)
	_stroke_buffer.fill(Color.TRANSPARENT)
	_stroke_brush_color = brush_color
	_layer_backup = editor.active_layer.image.duplicate()
	_stroke_dirty_rect = Rect2i()  # Reset dirty rect for new stroke
	_last_preview_msec = 0  # Reset throttle timer


func _add_stroke_point(event: InputEvent) -> void:
	var pos: Vector2 = event.position
	var p := _pressure_from_event(event)
	
	if _waiting_for_motion:
		_waiting_for_motion = false
		_saw_motion = true
		
		# Heuristic: a mouse "looks" like constant full pressure with zero tilt.
		var looks_like_mouse: bool = (event is InputEventMouseMotion 
									   and is_equal_approx(p, 1.0) 
									   and (event.tilt == Vector2.ZERO))
		_use_pressure = not looks_like_mouse
		
		# Use the first real sample as-is (no ramp from 0.1)
		_smoothed_pressure = p
		_last_pressure = p
		
		# Expand & localize before optional "touchdown" stamp
		#var _radius := get_actual_brush_radius(_smoothed_pressure)
		#var _bounds_point := get_bounds_point_for_expansion(pos, _radius)
		#var _offset := editor.active_layer.expand_to_point(_bounds_point)
		#editor.active_layer.position -= _offset
		#event = editor.active_layer.localize_input(event)
		#pos = event.position
		
		# Optional: stamp once at touchdown using the true first pressure
		_draw_brush_stamp(
			editor.active_layer.image,
			pos,
			brush_color,
			brush_size * (p if _use_pressure else 1.0)
		)
		# Always update on first point of stroke
		_update_visual_preview()
		_last_preview_msec = Time.get_ticks_msec()
		editor.queue_redraw()
		
		_last_drawing_position = pos
		_single_click = false   # Important: clear this flag to prevent double stamping
		return
	
	# Subsequent motion: smooth only if we're actually using pressure
	if _use_pressure:
		_smoothed_pressure = lerp(_smoothed_pressure, p, _pressure_smoothing_factor)
	else:
		_smoothed_pressure = 1.0
	
	# Expand layer if needed
	#var radius = get_actual_brush_radius(_smoothed_pressure)
	#var bounds_point = get_bounds_point_for_expansion(pos, radius)
	#var offset = editor.active_layer.expand_to_point(bounds_point)
	#editor.active_layer.position -= offset
	#event = editor.active_layer.localize_input(event)
	#pos = event.position
	
	# Draw continuous line between last and current position
	_draw_continuous_line(
		_last_drawing_position, 
		pos, 
		_last_pressure if _use_pressure else 1.0,
		_smoothed_pressure if _use_pressure else 1.0
	)
	
	_last_drawing_position = pos
	_last_pressure = _smoothed_pressure
	# Throttle preview updates for performance
	if _should_update_preview():
		_update_visual_preview()
		editor.queue_redraw()

func _end_stroke(event: InputEvent) -> void:
	# Handle single click - draw one dot
	if _single_click:
		# Clicks/taps with no motion: use full pressure for mouse, touch pressure if available
		var p := 1.0
		if event is InputEventScreenTouch:
			p = clamp(event.pressure, MIN_PRESSURE, 1.0)  # touch reports pressure on press/release
		_draw_brush_stamp(
			editor.active_layer.image,
			_last_drawing_position,
			brush_color,
			brush_size * p
		)

	# Final composite: restore backup and composite stroke buffer
	if _stroke_buffer and _layer_backup:
		editor.active_layer.image.blit_rect(_layer_backup, Rect2i(Vector2i.ZERO, _layer_backup.get_size()), Vector2i.ZERO)
		_composite_stroke_buffer_to(editor.active_layer.image, _layer_backup)
	_stroke_buffer = null
	_layer_backup = null
	_stroke_dirty_rect = Rect2i()  # Reset dirty rect
	editor.queue_redraw()

	# Finalize and execute the drawing command
	if current_stroke_command:
		current_stroke_command.finalize_stroke()  # Captures "after" state
		editor.execute_command(current_stroke_command)
		current_stroke_command = null

	drawing = false
	_single_click = false
	_waiting_for_motion = false
	_saw_motion = false

## Helper function to calculate the bounds of the stroke
func _calculate_stroke_bounds(center_pos: Vector2) -> Rect2i:
	var max_radius = get_actual_brush_radius(1.0)
	var top_left = Vector2i(
		int(center_pos.x - max_radius),
		int(center_pos.y - max_radius)
	)
	var size = Vector2i(max_radius * 2, max_radius * 2)
	
	# Clamp to layer bounds
	var layer_size = editor.active_layer.image.get_size()
	top_left.x = max(0, top_left.x)
	top_left.y = max(0, top_left.y)
	size.x = min(size.x, layer_size.x - top_left.x)
	size.y = min(size.y, layer_size.y - top_left.y)
	
	return Rect2i(top_left, size)

func _draw_continuous_line(start_pos: Vector2, end_pos: Vector2, start_pressure: float, end_pressure: float) -> void:
	var distance = start_pos.distance_to(end_pos)
	var effective_brush_size = brush_size * max(start_pressure, end_pressure)
	
	# Calculate step size based on brush size for smooth lines
	var step_size = max(1.0, effective_brush_size * 0.15)
	var steps = max(1, int(ceil(distance / step_size)))
	
	for i in range(steps + 1):
		var t = float(i) / steps if steps > 0 else 0.0
		var lerp_pos = start_pos.lerp(end_pos, t)
		var lerp_pressure = lerp(start_pressure, end_pressure, t)
		
		_draw_brush_stamp(
			editor.active_layer.image,
			lerp_pos,
			brush_color,
			brush_size * lerp_pressure
		)

func _draw_brush_stamp(target_image: Image, center: Vector2, color: Color, diameter: float) -> void:
	var camera_zoom = editor.input_area_camera.zoom.x
	# Divide by camera zoom to keep brush visually constant in screen pixels
	var actual_diameter = diameter / camera_zoom
	var radius = max(1, int(ceil(actual_diameter * 0.5)))

	var pixels = _get_cached_circle_pixels(radius)
	var center_x = int(center.x)
	var center_y = int(center.y)

	# Use stroke buffer if available, otherwise draw directly
	var draw_target: Image = _stroke_buffer if _stroke_buffer else target_image
	var use_max_alpha: bool = _stroke_buffer != null

	# Track dirty region for optimized compositing
	if use_max_alpha:
		_expand_dirty_rect(Vector2i(center_x, center_y), radius)

	var img_width = draw_target.get_width()
	var img_height = draw_target.get_height()

	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y

		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			# Skip pixels outside of selection
			if not editor.is_pixel_selected(x, y):
				continue

			var alpha_factor = offset.z
			var stamp_alpha = color.a * alpha_factor

			if stamp_alpha <= 0.01:
				continue

			if use_max_alpha:
				# Stroke buffer mode: use MAX alpha to prevent accumulation
				var existing = draw_target.get_pixel(x, y)
				if stamp_alpha > existing.a:
					# Store coverage alpha in the buffer (use white as placeholder)
					draw_target.set_pixel(x, y, Color(1.0, 1.0, 1.0, stamp_alpha))
			else:
				# Direct mode (fallback): original blending behavior
				if alpha_factor >= 0.99:
					draw_target.set_pixel(x, y, color)
				else:
					var new_color = color
					new_color.a = stamp_alpha
					var existing_color = draw_target.get_pixel(x, y)
					var blended_color = _blend_colors(existing_color, new_color)
					draw_target.set_pixel(x, y, blended_color)

func _get_cached_circle_pixels(radius: int) -> Array:
	radius = min(radius, _max_cached_radius)
	
	if _circle_cache.has(radius):
		return _circle_cache[radius]
	
	var pixels = []
	var r_squared = radius * radius
	
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			var dist_squared = x*x + y*y
			if dist_squared <= r_squared:
				var alpha_factor = 1.0
				
				if dist_squared > (radius-1) * (radius-1):
					var dist = sqrt(dist_squared)
					alpha_factor = max(0.0, 1.0 - (dist - (radius-1)))
				
				pixels.append(Vector3(x, y, alpha_factor))
	
	_circle_cache[radius] = pixels
	return pixels

func _composite_stroke_buffer_to(target_image: Image, source_backup: Image) -> void:
	# Use dirty rect for optimized compositing
	_composite_stroke_buffer_region(target_image, source_backup, _stroke_dirty_rect)


func _composite_stroke_buffer_region(target_image: Image, source_backup: Image, region: Rect2i) -> void:
	if not _stroke_buffer:
		return
	if region.size == Vector2i.ZERO:
		return

	# Clamp region to buffer bounds
	var buffer_size = _stroke_buffer.get_size()
	region = region.intersection(Rect2i(Vector2i.ZERO, buffer_size))

	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var buffer_pixel = _stroke_buffer.get_pixel(x, y)
			if buffer_pixel.a > 0.01:
				# Apply brush color with the stored alpha
				var stroke_color = _stroke_brush_color
				stroke_color.a *= buffer_pixel.a

				var existing_color = source_backup.get_pixel(x, y)
				var blended_color = _blend_colors(existing_color, stroke_color)
				target_image.set_pixel(x, y, blended_color)


func _update_visual_preview() -> void:
	# Restore layer from backup and composite current stroke buffer for display
	# Uses dirty rect for optimized region-only operations
	if _stroke_buffer and _layer_backup and _stroke_dirty_rect.size != Vector2i.ZERO:
		# Only blit and composite the dirty region
		editor.active_layer.image.blit_rect(_layer_backup, _stroke_dirty_rect, _stroke_dirty_rect.position)
		_composite_stroke_buffer_region(editor.active_layer.image, _layer_backup, _stroke_dirty_rect)


func _expand_dirty_rect(center: Vector2i, radius: int) -> void:
	var stamp_rect = Rect2i(center - Vector2i(radius, radius), Vector2i(radius * 2 + 1, radius * 2 + 1))
	# Clamp to image bounds
	var img_size = _stroke_buffer.get_size() if _stroke_buffer else Vector2i.ZERO
	stamp_rect = stamp_rect.intersection(Rect2i(Vector2i.ZERO, img_size))
	if stamp_rect.size == Vector2i.ZERO:
		return
	if _stroke_dirty_rect.size == Vector2i.ZERO:
		_stroke_dirty_rect = stamp_rect
	else:
		_stroke_dirty_rect = _stroke_dirty_rect.merge(stamp_rect)


func _should_update_preview() -> bool:
	var now = Time.get_ticks_msec()
	if now - _last_preview_msec >= PREVIEW_INTERVAL_MS:
		_last_preview_msec = now
		return true
	return false


func _blend_colors(bottom: Color, top: Color) -> Color:
	if editor.is_active_layer_mask and top.r == bottom.r and top.g == bottom.g and top.b == bottom.b:
		return bottom
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

func create_contrast_circle_cursor(radius: int) -> Image:
	var size = radius * 2 + 3
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	var center: int = int(size / 2.0)
	draw_circle_outline(image, center, radius + 1, Color.BLACK)
	draw_circle_outline(image, center, radius, Color.WHITE)
	
	return image

func draw_circle_outline(image: Image, center: int, radius: int, color: Color):
	var x = radius
	var y = 0
	var decision = 1 - radius
	
	while x >= y:
		plot_circle_points(image, center, x, y, color)
		plot_circle_points(image, center, y, x, color)
		
		y += 1
		if decision <= 0:
			decision += 2 * y + 1
		else:
			x -= 1
			decision += 2 * (y - x) + 1

func plot_circle_points(image: Image, center: int, x: int, y: int, color: Color):
	var points = [
		Vector2i(center + x, center + y),
		Vector2i(center - x, center + y),
		Vector2i(center + x, center - y),
		Vector2i(center - x, center - y),
		Vector2i(center + y, center + x),
		Vector2i(center - y, center + x),
		Vector2i(center + y, center - x),
		Vector2i(center - y, center - x)
	]
	
	for point in points:
		if point.x >= 0 and point.x < image.get_width() and point.y >= 0 and point.y < image.get_height():
			image.set_pixel(point.x, point.y, color)
