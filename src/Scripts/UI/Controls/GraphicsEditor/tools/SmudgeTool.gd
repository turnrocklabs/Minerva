class_name SmudgeTool
extends BaseTool

@export var _strength_slider: Slider
@export var _brush_size_slider: Slider

var brush_size: int:
	set(value):
		brush_size = value
		if not _brush_size_slider.is_node_ready():
			await _brush_size_slider.ready
		_brush_size_slider.value = value
	get:
		return int(_brush_size_slider.value)

var smudge_strength: float:
	set(value):
		smudge_strength = value
		if not _strength_slider.is_node_ready():
			await _strength_slider.ready
		_strength_slider.value = value
	get:
		return _strength_slider.value

var auto_expand: = true

var smudging: bool = false
var _last_smudge_position: Vector2
var _brush_buffer: PackedByteArray
var _brush_buffer_size: int = 0
var _last_pressure: float = 1.0
var _smoothed_pressure: float = 1.0
var _pressure_smoothing_factor: float = 0.3
var _single_click: bool = false

# Performance optimizations
var _circle_cache = {}
var _max_cached_radius = 100

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

func handle_input_event(event: InputEvent) -> void:
	if not editor.active_layer: return

	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if editor.selected_layers.size() > 1:
				display_tool_error(ToolError.MULTIPLE_LAYERS_SELECTED)
				return

			if event.is_pressed():
				_start_smudge(event)
			else:
				_end_smudge(event)

	elif event is InputEventMouseMotion and smudging:
		_single_click = false
		_perform_smudge(event)

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
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = (brush_size * pressure) / visual_zoom
	var radius = int(ceil(actual_diameter * 0.5))
	return max(radius, 1)

func _start_smudge(event: InputEvent) -> void:
	smudging = true
	_single_click = true
	_last_smudge_position = event.position
	_smoothed_pressure = 1.0
	_last_pressure = 1.0
	
	# Expand for maximum possible brush size
	var max_radius = get_actual_brush_radius(1.0)
	var bounds_point = get_bounds_point_for_expansion(event.position, max_radius)
	var offset = editor.active_layer.expand_to_point(bounds_point)
	editor.active_layer.position -= offset
	event = editor.active_layer.localize_input(event)
	_last_smudge_position = event.position
	
	# Initialize brush buffer from starting position
	_pickup_brush_data(_last_smudge_position)

func _perform_smudge(event: InputEvent) -> void:
	var pos = event.position
	var pressure = clamp(event.pressure if event is InputEventMouseMotion else 1.0, 0.1, 1.0)
	
	# Smooth pressure
	_smoothed_pressure = lerp(_smoothed_pressure, pressure, _pressure_smoothing_factor)
	
	# Expand layer if needed
	var radius = get_actual_brush_radius(_smoothed_pressure)
	var bounds_point = get_bounds_point_for_expansion(pos, radius)
	var offset = editor.active_layer.expand_to_point(bounds_point)
	editor.active_layer.position -= offset
	event = editor.active_layer.localize_input(event)
	pos = event.position
	
	# Apply continuous smudge between last and current position
	_apply_continuous_smudge(_last_smudge_position, pos, _last_pressure, _smoothed_pressure)
	
	_last_smudge_position = pos
	_last_pressure = _smoothed_pressure
	editor.queue_redraw()

func _end_smudge(event: InputEvent) -> void:
	# Handle single click - apply one smudge stamp
	if _single_click:
		_apply_smudge_stamp(
			editor.active_layer.image,
			_last_smudge_position,
			brush_size * _smoothed_pressure
		)
		editor.queue_redraw()
	
	smudging = false
	_single_click = false
	_brush_buffer.clear()
	_brush_buffer_size = 0

func _apply_continuous_smudge(start_pos: Vector2, end_pos: Vector2, start_pressure: float, end_pressure: float) -> void:
	var distance = start_pos.distance_to(end_pos)
	var effective_brush_size = brush_size * max(start_pressure, end_pressure)
	
	# Calculate step size based on brush size for smooth smudging
	var step_size = max(1.0, effective_brush_size * 0.15)
	var steps = max(1, int(ceil(distance / step_size)))
	
	for i in range(steps + 1):
		var t = float(i) / steps if steps > 0 else 0.0
		var lerp_pos = start_pos.lerp(end_pos, t)
		var lerp_pressure = lerp(start_pressure, end_pressure, t)
		
		_apply_smudge_stamp(
			editor.active_layer.image,
			lerp_pos,
			brush_size * lerp_pressure
		)

func _apply_smudge_stamp(target_image: Image, center: Vector2, diameter: float) -> void:
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = diameter / visual_zoom
	var radius = max(1, int(ceil(actual_diameter * 0.5)))
	
	var pixels = _get_cached_circle_pixels(radius)
	var center_x = int(center.x)
	var center_y = int(center.y)
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	# Apply brush data to canvas
	var buffer_index = 0
	for i in range(min(pixels.size(), _brush_buffer_size)):
		var offset = pixels[i]
		var x = center_x + int(offset.x)
		var y = center_y + int(offset.y)
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			# Get brush color from buffer
			if buffer_index + 3 < _brush_buffer.size():
				var brush_r = float(_brush_buffer[buffer_index]) / 255.0
				var brush_g = float(_brush_buffer[buffer_index + 1]) / 255.0
				var brush_b = float(_brush_buffer[buffer_index + 2]) / 255.0
				var brush_a = float(_brush_buffer[buffer_index + 3]) / 255.0
				var brush_color = Color(brush_r, brush_g, brush_b, brush_a)
				
				if brush_color.a > 0.01:  # Only apply if brush has content
					var existing_color = target_image.get_pixel(x, y)
					var alpha_factor = offset.z  # Brush shape falloff
					
					# Calculate blend factor
					var blend_factor = smudge_strength * alpha_factor
					blend_factor = clamp(blend_factor, 0.0, 1.0)
					
					# Blend the colors
					var final_color = _blend_colors(existing_color, brush_color, blend_factor)
					target_image.set_pixel(x, y, final_color)
		
		buffer_index += 4
	
	# Update brush data for next stamp (pickup from current position)
	_pickup_brush_data(center)

func _pickup_brush_data(pos: Vector2) -> void:
	var target_image = editor.active_layer.image
	var visual_zoom = editor.layers_container.scale.x
	var pickup_radius = max(1, int(ceil(brush_size * 0.5 / visual_zoom)))
	
	var pixels = _get_cached_circle_pixels(pickup_radius)
	var center_x = int(pos.x)
	var center_y = int(pos.y)
	
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	# Calculate buffer size needed (4 bytes per pixel: RGBA)
	var buffer_size = pixels.size() * 4
	_brush_buffer.resize(buffer_size)
	_brush_buffer_size = pixels.size()
	
	# Sample pixels into buffer
	var buffer_index = 0
	for offset in pixels:
		var x = center_x + int(offset.x)
		var y = center_y + int(offset.y)
		
		var color = Color.TRANSPARENT
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			color = target_image.get_pixel(x, y)
		
		# Store RGBA in buffer
		_brush_buffer[buffer_index] = int(color.r * 255)
		_brush_buffer[buffer_index + 1] = int(color.g * 255)
		_brush_buffer[buffer_index + 2] = int(color.b * 255)
		_brush_buffer[buffer_index + 3] = int(color.a * 255)
		buffer_index += 4

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

func _blend_colors(bottom: Color, top: Color, blend_factor: float) -> Color:
	if blend_factor >= 0.99:
		return top
	if blend_factor <= 0.01:
		return bottom
	
	# Apply blend factor to top color's alpha
	var blended_top = top
	blended_top.a *= blend_factor
	
	if blended_top.a >= 0.99:
		return blended_top
	if blended_top.a <= 0.01:
		return bottom
	
	var one_minus_top_a = 1.0 - blended_top.a
	var bottom_factor = bottom.a * one_minus_top_a
	var a = 1.0 - one_minus_top_a * (1.0 - bottom.a)
	
	if a < 0.01:
		return Color(0, 0, 0, 0)
	
	var inv_a = 1.0 / a
	var r = (blended_top.r * blended_top.a + bottom.r * bottom_factor) * inv_a
	var g = (blended_top.g * blended_top.a + bottom.g * bottom_factor) * inv_a
	var b = (blended_top.b * blended_top.a + bottom.b * bottom_factor) * inv_a
	
	return Color(r, g, b, a)

func create_contrast_circle_cursor(radius: int) -> Image:
	var size = radius * 2 + 3
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	var center = size / 2
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