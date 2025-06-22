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

var auto_expand: = true

var drawing: = false
var _last_drawing_position: Vector2
var _current_stroke_points = []
var _last_pressure: float = 1.0
var _smoothed_pressure: float = -1.0
var _pressure_smoothing_factor: float = 0.3

var _first_point_drawn: bool = false
var _first_point_position: Vector2
var _first_point_backup_region: Image
var _awaiting_pressure_correction: bool = false

# Performance optimizations
var _circle_cache = {}  # Cache circular brush patterns
var _max_cached_radius = 100

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				var cursor_radius = roundi(brush_size / 2.0)  # Convert diameter to radius
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
				# Expand to accommodate full brush size for mouse button (assume pressure = 1.0)
				var radius = get_actual_brush_radius(1.0)
				var bounds_point = get_bounds_point_for_expansion(event.position, radius)
				var offset = editor.active_layer.expand_to_point(bounds_point)
				editor.active_layer.position -= offset
				event = editor.active_layer.localize_input(event)

				_start_stroke(event)
			else:
				_end_stroke()

	elif event is InputEventMouseMotion and drawing:
		# Expand to accommodate brush size with current pressure
		var radius = get_actual_brush_radius(event.pressure)
		var bounds_point = get_bounds_point_for_expansion(event.position, radius)
		var offset = editor.active_layer.expand_to_point(bounds_point)
		editor.active_layer.position -= offset
		event = editor.active_layer.localize_input(event)

		_add_stroke_point(event)

## Returns the point that should be used for layer expansion.
## For points on right/bottom edges, use bottom-right corner of brush.
## For points on left/top edges, use top-left corner of brush.
func get_bounds_point_for_expansion(center: Vector2, radius: int) -> Vector2:
	var layer_size = editor.active_layer.image.get_size()
	var bounds_point = center
	
	# Check if we're closer to right edge - expand to right
	if center.x > layer_size.x * 0.5:
		bounds_point.x += radius
	else:
		# Closer to left edge - expand to left
		bounds_point.x -= radius
	
	# Check if we're closer to bottom edge - expand to bottom  
	if center.y > layer_size.y * 0.5:
		bounds_point.y += radius
	else:
		# Closer to top edge - expand to top
		bounds_point.y -= radius
	
	return bounds_point

# Returns the actual radius in image pixels that will be drawn.
func get_actual_brush_radius(pressure: float) -> int:
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = (brush_size * pressure) / visual_zoom
	var radius = int(ceil(actual_diameter * 0.5))
	return max(radius, 1)

func _start_stroke(event: InputEvent) -> void:
	drawing = true
	_last_drawing_position = event.position
	_smoothed_pressure = -1.0
	_current_stroke_points = []
	_first_point_drawn = false
	_awaiting_pressure_correction = true
	
	# Use default pressure for first point
	var initial_pressure = 1.0  # Or 0.5, whatever you prefer as default
	_last_pressure = initial_pressure
	
	# Store first point info for potential correction
	_first_point_position = event.position
	
	# Backup the area where we're about to draw (for potential revert)
	_backup_first_point_region(event.position, initial_pressure)
	
	# Draw the first point with default pressure
	_draw_brush_stamp(
		editor.active_layer.image,
		event.position,
		brush_color,
		brush_size * initial_pressure
	)
	
	_first_point_drawn = true
	editor.queue_redraw()

func _add_stroke_point(event: InputEvent) -> void:
	var pos = event.position
	var pressure = event.pressure if event is InputEventMouseMotion else 1.0

	# Check if we need to correct the first point
	if _awaiting_pressure_correction and event is InputEventMouseMotion:
		var actual_pressure = clamp(pressure, 0.0, 1.0)
		
		# If the pressure is significantly different from our assumption, correct the first point
		if abs(actual_pressure - _last_pressure) > 0.1:  # Threshold for correction
			_correct_first_point(actual_pressure)
		
		_awaiting_pressure_correction = false

	# Continue with normal processing
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
	
	# Calculate distance and determine if we need interpolation
	var distance = _last_drawing_position.distance_to(pos)
	var effective_brush_size = brush_size * _smoothed_pressure
	
	if distance > effective_brush_size * 0.5:
		# Add intermediate points to ensure continuous line
		var steps = ceil(distance / (effective_brush_size * 0.25))
		var last_pressure = _last_pressure
		
		for i in range(1, steps + 1):
			var t = float(i) / steps
			var lerp_pos = _last_drawing_position.lerp(pos, t)
			var lerp_pressure = lerp(last_pressure, _smoothed_pressure, t)
			
			_draw_brush_stamp(
				editor.active_layer.image,
				lerp_pos,
				brush_color,
				brush_size * lerp_pressure
			)
	else:
		# Distance is small, just draw the current point
		_draw_brush_stamp(
			editor.active_layer.image,
			pos,
			brush_color,
			brush_size * _smoothed_pressure
		)
	
	# Update for next iteration
	_last_drawing_position = pos
	_last_pressure = _smoothed_pressure
	editor.queue_redraw()

func _backup_first_point_region(center: Vector2, pressure: float) -> void:
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = (brush_size * pressure) / visual_zoom
	var radius = int(ceil(actual_diameter * 0.5)) + 2  # Extra padding
	
	var center_x = int(center.x)
	var center_y = int(center.y)
	
	var backup_size = radius * 2 + 1
	_first_point_backup_region = Image.create(backup_size, backup_size, false, Image.FORMAT_RGBA8)
	
	# Copy the region from the main image
	var img = editor.active_layer.image
	for x in range(backup_size):
		for y in range(backup_size):
			var src_x = center_x - radius + x
			var src_y = center_y - radius + y
			
			if src_x >= 0 and src_x < img.get_width() and src_y >= 0 and src_y < img.get_height():
				var pixel = img.get_pixel(src_x, src_y)
				_first_point_backup_region.set_pixel(x, y, pixel)
			else:
				_first_point_backup_region.set_pixel(x, y, Color(0, 0, 0, 0))

func _correct_first_point(correct_pressure: float) -> void:
	if not _first_point_drawn or not _first_point_backup_region:
		return
	
	# Restore the backed up regions
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = (brush_size * _last_pressure) / visual_zoom
	var radius = int(ceil(actual_diameter * 0.5)) + 2
	
	var center_x = int(_first_point_position.x)
	var center_y = int(_first_point_position.y)
	
	var img = editor.active_layer.image
	var backup_size = _first_point_backup_region.get_width()
	
	# Restore original pixels
	for x in range(backup_size):
		for y in range(backup_size):
			var dst_x = center_x - radius + x
			var dst_y = center_y - radius + y
			
			if dst_x >= 0 and dst_x < img.get_width() and dst_y >= 0 and dst_y < img.get_height():
				var pixel = _first_point_backup_region.get_pixel(x, y)
				img.set_pixel(dst_x, dst_y, pixel)
	
	# Redraw with correct pressure
	_draw_brush_stamp(
		img,
		_first_point_position,
		brush_color,
		brush_size * correct_pressure
	)
	
	# Update the last pressure to the corrected value
	_last_pressure = correct_pressure
	_smoothed_pressure = correct_pressure

func _end_stroke() -> void:
	drawing = false
	_smoothed_pressure = -1.0
	_current_stroke_points = []
	_first_point_drawn = false
	_awaiting_pressure_correction = false
	_first_point_backup_region = null

func _draw_brush_stamp(target_image: Image, center: Vector2, color: Color, diameter: float) -> void:
	# Apply correct scaling to brush diameter
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = diameter / visual_zoom

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

func create_contrast_circle_cursor(radius: int) -> Image:
	var size = radius * 2 + 3  # Extra space for outline
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
