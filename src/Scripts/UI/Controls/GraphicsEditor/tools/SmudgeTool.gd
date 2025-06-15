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

var smudging: bool = false
var _last_smudge_position: Vector2
var _smudge_buffer: Array[Color] = []
var _buffer_positions: Array[Vector2] = []
var _max_buffer_size: int = 50
var _last_pressure: float = 1.0
var _smoothed_pressure: float = -1.0
var _pressure_smoothing_factor: float = 0.3

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
				_end_smudge()

	elif event is InputEventMouseMotion and smudging:
		_perform_smudge(event)

func _start_smudge(event: InputEvent) -> void:
	smudging = true
	_last_smudge_position = event.position
	_smoothed_pressure = -1.0
	_smudge_buffer.clear()
	_buffer_positions.clear()
	
	# Sample initial colors from the canvas
	_sample_colors_at_position(event.position)

func _perform_smudge(event: InputEvent) -> void:
	var pos = event.position
	var pressure = event.pressure if event is InputEventMouseMotion else 1.0
	
	# Smooth pressure
	pressure = clamp(pressure, 0.0, 1.0)
	if _smoothed_pressure < 0.0:
		_smoothed_pressure = pressure
	else:
		_smoothed_pressure = lerp(_smoothed_pressure, pressure, _pressure_smoothing_factor)
	
	# Calculate movement distance
	var distance = _last_smudge_position.distance_to(pos)
	
	# If moving too fast, add intermediate points
	if distance > brush_size * 0.3:
		var steps = ceil(distance / (brush_size * 0.2))
		for i in range(1, steps + 1):
			var t = float(i) / steps
			var lerp_pos = _last_smudge_position.lerp(pos, t)
			_apply_smudge_at_position(lerp_pos, _smoothed_pressure)
	else:
		_apply_smudge_at_position(pos, _smoothed_pressure)
	
	_last_smudge_position = pos
	editor.queue_redraw()

func _end_smudge() -> void:
	smudging = false
	_smoothed_pressure = -1.0
	_smudge_buffer.clear()
	_buffer_positions.clear()

func _sample_colors_at_position(pos: Vector2) -> void:
	var target_image = editor.active_layer.image
	
	# Convert position to image coordinates
	var layer_scale_x = editor.active_layer.size.x / float(target_image.get_width())
	var layer_scale_y = editor.active_layer.size.y / float(target_image.get_height())
	
	var image_pos = pos / editor.active_layer.image_zoom_factor
	var sample_radius = max(1, int(brush_size * 0.3 / editor.active_layer.image_zoom_factor))
	
	# Sample colors in a circular pattern around the position
	var pixels = _get_cached_circle_pixels(sample_radius)
	var center_x = int(image_pos.x)
	var center_y = int(image_pos.y)
	
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			var color = target_image.get_pixel(x, y)
			if color.a > 0.01:  # Only sample non-transparent pixels
				_add_to_smudge_buffer(color, Vector2(x, y))

func _add_to_smudge_buffer(color: Color, buffer_pos: Vector2) -> void:
	_smudge_buffer.append(color)
	_buffer_positions.append(buffer_pos)
	
	# Keep buffer size manageable
	if _smudge_buffer.size() > _max_buffer_size:
		_smudge_buffer.pop_front()
		_buffer_positions.pop_front()

func _apply_smudge_at_position(pos: Vector2, pressure: float) -> void:
	var target_image = editor.active_layer.image
	
	# Sample new colors at current position
	_sample_colors_at_position(pos)
	
	if _smudge_buffer.is_empty():
		return
	
	# Calculate effective brush size based on pressure
	var effective_size = brush_size * pressure
	
	# Apply smudge effect
	_apply_smudge_stamp(target_image, pos, effective_size)

func _apply_smudge_stamp(target_image: Image, center: Vector2, diameter: float) -> void:
	# Convert to image coordinates
	var layer_scale_x = editor.active_layer.size.x / float(target_image.get_width())
	var layer_scale_y = editor.active_layer.size.y / float(target_image.get_height())
	
	var actual_diameter = diameter / editor.active_layer.image_zoom_factor
	actual_diameter *= max(layer_scale_x, layer_scale_y)
	
	center /= editor.active_layer.image_zoom_factor
	
	var radius = int(ceil(actual_diameter * 0.5))
	if radius < 1:
		radius = 1
	
	var pixels = _get_cached_circle_pixels(radius)
	var center_x = int(center.x)
	var center_y = int(center.y)
	
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			var alpha_factor = offset.z
			var existing_color = target_image.get_pixel(x, y)
			
			# Get smudged color based on buffer
			var smudged_color = _get_smudged_color_for_position(Vector2(x, y), existing_color)
			
			# Apply smudge strength and alpha factor
			var blend_factor = smudge_strength * alpha_factor
			var final_color = existing_color.lerp(smudged_color, blend_factor)
			
			target_image.set_pixel(x, y, final_color)

func _get_smudged_color_for_position(pos: Vector2, current_color: Color) -> Color:
	if _smudge_buffer.is_empty():
		return current_color
	
	# Weight colors by distance from buffer positions
	var total_weight = 0.0
	var weighted_color = Color(0, 0, 0, 0)
	
	var max_samples = min(_smudge_buffer.size(), 10)  # Limit for performance
	
	for i in range(max_samples):
		var buffer_color = _smudge_buffer[i]
		var buffer_pos = _buffer_positions[i]
		
		# Calculate distance weight (closer colors have more influence)
		var distance = pos.distance_to(buffer_pos)
		var weight = 1.0 / (1.0 + distance * 0.1)  # Adjust multiplier for influence range
		
		weighted_color += buffer_color * weight
		total_weight += weight
	
	if total_weight > 0.0:
		weighted_color /= total_weight
		# Blend with current color for more natural smudging
		return current_color.lerp(weighted_color, 0.7)
	else:
		return current_color

# Cached circle pixel generation (same as drawing tool)
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

func create_contrast_circle_cursor(radius: int) -> Image:
	var size = radius * 2 + 3
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	var center = size / 2
	
	# Draw black outline (larger circle)
	draw_circle_outline(image, center, radius + 1, Color.BLACK)
	# Draw white outline (smaller circle)  
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
