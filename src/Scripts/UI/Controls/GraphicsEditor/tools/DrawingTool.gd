class_name DrawingTool
extends BaseTool

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

var drawing: = false
var _last_drawing_position: Vector2
var _current_stroke_points = []
var _last_pressure: float = 1.0
var _smoothed_pressure: float = -1.0
var _pressure_smoothing_factor: float = 0.3

# Performance optimizations
var _circle_cache = {}  # Cache circular brush patterns
var _max_cached_radius = 100

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				editor.set_custom_cursor(
					create_fast_circle_image(brush_size),
					Input.CursorShape.CURSOR_ARROW,
					Vector2.ONE * brush_size
				)
	)

	_brush_size_slider.value_changed.connect(
		func(value: float):
			editor.set_custom_cursor(create_fast_circle_image(int(value)), Input.CursorShape.CURSOR_ARROW, Vector2.ONE * value)
	)
	
	# Pre-cache common brush sizes
	for r in range(1, min(30, _max_cached_radius)):
		_get_cached_circle_pixels(r)

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				_start_stroke(event)
			else:
				_end_stroke()

	elif event is InputEventMouseMotion and drawing:
		_add_stroke_point(event)

func _start_stroke(event: InputEvent) -> void:
	drawing = true
	_last_drawing_position = event.position
	_smoothed_pressure = -1.0
	_current_stroke_points = []
	
	# Add first point
	_add_stroke_point(event)

func _add_stroke_point(event: InputEvent) -> void:
	var pos = event.position
	var pressure = event.pressure if event is InputEventMouseMotion else 1.0
	
	# Smooth pressure
	pressure = clamp(pressure, 0.0, 1.0)
	if _smoothed_pressure < 0.0:
		_smoothed_pressure = pressure
	else:
		_smoothed_pressure = lerp(_smoothed_pressure, pressure, _pressure_smoothing_factor)
	
	# Record the point
	_current_stroke_points.append({
		"pos": pos,
		"pressure": _smoothed_pressure
	})
	
	# If moving too fast, add intermediate points to ensure a continuous line
	var distance = _last_drawing_position.distance_to(pos)
	if distance > brush_size * 0.5:  # Add more points if moving faster than half the brush size
		var steps = ceil(distance / (brush_size * 0.25))  # Adjust divisor to control density
		for i in range(1, steps):
			var t = float(i) / steps
			var lerp_pos = _last_drawing_position.lerp(pos, t)
			var lerp_pressure = _smoothed_pressure  # Use current pressure for interpolated points
			
			# Draw a single stamp at this position
			_draw_brush_stamp(
				editor.active_layer.image,
				lerp_pos,
				brush_color,
				brush_size * lerp_pressure
			)
	
	# Draw the actual point
	_draw_brush_stamp(
		editor.active_layer.image,
		pos,
		brush_color,
		brush_size * _smoothed_pressure
	)
	
	_last_drawing_position = pos
	editor.queue_redraw()

func _end_stroke() -> void:
	drawing = false
	_smoothed_pressure = -1.0
	_current_stroke_points = []

func _draw_brush_stamp(target_image: Image, center: Vector2, color: Color, diameter: float) -> void:
	# IMPORTANT: Get the complete scaling factors
	# Layer scale (difference between display size and actual image size)
	var layer_scale_x = editor.active_layer.size.x / float(target_image.get_width())
	var layer_scale_y = editor.active_layer.size.y / float(target_image.get_height())
	
	# Apply correct scaling to brush diameter
	# First convert the requested visual diameter to actual image pixels
	var actual_diameter = diameter / editor.active_layer.image_zoom_factor
	
	# Further adjust by the layer's scale to get image pixel coordinates
	actual_diameter *= max(layer_scale_x, layer_scale_y)  # Use the larger scale to ensure brush isn't too small
	
	# Convert center position to actual image coordinates
	center /= editor.active_layer.image_zoom_factor
	
	# Calculate radius
	var radius = int(ceil(actual_diameter * 0.5))
	if radius < 1:
		radius = 1
		
	# Get cached pixel pattern for this radius
	var pixels = _get_cached_circle_pixels(radius)
	
	# Calculate integer center position in image coordinates
	var center_x = int(center.x)
	var center_y = int(center.y)
	
	# Apply the stamp pattern to the image
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			var alpha_factor = offset.z  # Z component stores alpha factor
			
			if alpha_factor >= 0.99:
				# Fast path for solid pixels
				target_image.set_pixel(x, y, color)
			else:
				# Alpha blending for edge pixels
				var new_color = color
				new_color.a *= alpha_factor
				
				if new_color.a > 0.01:
					var existing_color = target_image.get_pixel(x, y)
					var blended_color = _blend_colors(existing_color, new_color)
					target_image.set_pixel(x, y, blended_color)
	

# Get or create cached circle pixel pattern
func _get_cached_circle_pixels(radius: int) -> Array:
	# Clamp radius to reasonable limits
	radius = min(radius, _max_cached_radius)
	
	# Return cached pattern if available
	if _circle_cache.has(radius):
		return _circle_cache[radius]
	
	# Generate new pattern
	var pixels = []
	var r_squared = radius * radius
	
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			var dist_squared = x*x + y*y
			if dist_squared <= r_squared:
				var alpha_factor = 1.0
				
				# Add anti-aliasing at the edges
				if dist_squared > (radius-1) * (radius-1):
					var dist = sqrt(dist_squared)
					alpha_factor = max(0.0, 1.0 - (dist - (radius-1)))
				
				# Store x, y offset and alpha factor in Vector3
				pixels.append(Vector3(x, y, alpha_factor))
	
	# Cache the pattern
	_circle_cache[radius] = pixels
	return pixels

# Fast color blending
func _blend_colors(bottom: Color, top: Color) -> Color:
	if top.a >= 0.99:
		return top
	
	if top.a <= 0.01:
		return bottom
		
	# Pre-calculate alpha values for speed
	var one_minus_top_a = 1.0 - top.a
	var bottom_factor = bottom.a * one_minus_top_a
	
	# Calculate final alpha
	var a = 1.0 - one_minus_top_a * (1.0 - bottom.a)
	if a < 0.01:
		return Color(0, 0, 0, 0)
	
	# Calculate final RGB
	var inv_a = 1.0 / a
	var r = (top.r * top.a + bottom.r * bottom_factor) * inv_a
	var g = (top.g * top.a + bottom.g * bottom_factor) * inv_a
	var b = (top.b * top.a + bottom.b * bottom_factor) * inv_a
	
	return Color(r, g, b, a)

# Circle cursor methods (unchanged)
func create_fast_circle_image(radius: int, line_color: Color = Color(1, 1, 1, 1)) -> Image:
	var size = radius * 2 + 1
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	
	# Make the image transparent
	image.fill(Color(0, 0, 0, 0))
	
	# Main circle pixels
	var x = radius
	var y = 0
	var decision = 1 - radius
	
	while x >= y:
		# Main pixels
		plot_circle_points(image, radius, x, y, line_color)
		plot_circle_points(image, radius, y, x, line_color)
		
		y += 1
		if decision <= 0:
			decision += 2 * y + 1
		else:
			x -= 1
			decision += 2 * (y - x) + 1
	
	return image

func plot_circle_points(image: Image, center: int, x: int, y: int, color: Color):
	# Calculate all 8 symmetric points
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
	
	# Only plot points that are within the image bounds
	for point in points:
		if point.x >= 0 and point.x < image.get_width() and point.y >= 0 and point.y < image.get_height():
			image.set_pixel(point.x, point.y, color)
