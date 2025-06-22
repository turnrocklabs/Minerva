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
var _brush_buffer: PackedByteArray  # Single buffer for brush data
var _brush_buffer_size: int = 0
var _last_pressure: float = 1.0
var _smoothed_pressure: float = -1.0
var _pressure_smoothing_factor: float = 0.3

# Performance optimizations
var _circle_cache = {}
var _max_cached_radius = 100
var _spacing_accumulator: float = 0.0

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				_update_cursor()
	)

	_brush_size_slider.value_changed.connect(
		func(value: float):
			_update_cursor()
	)
	
	# Pre-cache common brush sizes
	for r in range(1, min(30, _max_cached_radius)):
		_get_cached_circle_pixels(r)

func _update_cursor() -> void:
	var cursor_radius = roundi(brush_size / 2.0)
	var cursor_image = create_contrast_circle_cursor(cursor_radius)
	var hotspot = Vector2(cursor_image.get_width(), cursor_image.get_height()) / 2
	editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, hotspot)

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
	_spacing_accumulator = 0.0
	
	# Initialize brush buffer from starting position
	_pickup_brush_data(event.position)

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
	_spacing_accumulator += distance
	
	# Use 1-pixel spacing like the original algorithm suggests
	var spacing = 1.0
	
	if _spacing_accumulator >= spacing:
		var steps = int(_spacing_accumulator / spacing)
		var step_vector = (pos - _last_smudge_position).normalized() * spacing
		
		for i in range(steps):
			var stamp_pos = _last_smudge_position + step_vector * (i + 1)
			_apply_smudge_stamp(stamp_pos, _smoothed_pressure)
		
		_spacing_accumulator = fmod(_spacing_accumulator, spacing)
		_last_smudge_position = pos
		editor.queue_redraw()

func _end_smudge() -> void:
	smudging = false
	_smoothed_pressure = -1.0
	_brush_buffer.clear()
	_brush_buffer_size = 0
	_spacing_accumulator = 0.0

func _pickup_brush_data(pos: Vector2) -> void:
	var target_image = editor.active_layer.image
	var image_pos = pos / editor.active_layer.image_zoom_factor
	var pickup_radius = max(1, int(brush_size * 0.5 / editor.active_layer.image_zoom_factor))
	
	var pixels = _get_cached_circle_pixels(pickup_radius)
	var center_x = int(image_pos.x)
	var center_y = int(image_pos.y)
	
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

func _apply_smudge_stamp(pos: Vector2, pressure: float) -> void:
	var target_image = editor.active_layer.image
	
	# Convert to image coordinates
	var image_pos = pos / editor.active_layer.image_zoom_factor
	var actual_diameter = brush_size / editor.active_layer.image_zoom_factor
	var radius = max(1, int(ceil(actual_diameter * 0.5)))
	
	var pixels = _get_cached_circle_pixels(radius)
	var center_x = int(image_pos.x)
	var center_y = int(image_pos.y)
	
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
			var brush_r = float(_brush_buffer[buffer_index]) / 255.0
			var brush_g = float(_brush_buffer[buffer_index + 1]) / 255.0
			var brush_b = float(_brush_buffer[buffer_index + 2]) / 255.0
			var brush_a = float(_brush_buffer[buffer_index + 3]) / 255.0
			var brush_color = Color(brush_r, brush_g, brush_b, brush_a)
			
			if brush_color.a > 0.01:  # Only apply if brush has content
				var existing_color = target_image.get_pixel(x, y)
				var brush_alpha = offset.z  # Brush shape falloff
				
				# Calculate blend factor
				var blend_factor = smudge_strength * pressure * brush_alpha
				blend_factor = clamp(blend_factor, 0.0, 1.0)
				
				# Blend the colors
				var final_color = existing_color.lerp(brush_color, blend_factor)
				target_image.set_pixel(x, y, final_color)
		
		buffer_index += 4
	
	# Update brush data for next stamp (pickup from current position)
	_pickup_brush_data(pos)

# Cached circle pixel generation
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
				
				# Smooth falloff at edges
				if radius > 1:
					var dist = sqrt(dist_squared)
					var falloff_start = max(0.0, radius - 1.0)
					if dist > falloff_start:
						alpha_factor = max(0.0, 1.0 - (dist - falloff_start))
				
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
