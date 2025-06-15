class_name EraserTool
extends BaseTool

@export var _brush_size_slider: Slider

var brush_color: = Color.TRANSPARENT

var brush_size: int:
	set(value):
		brush_size = value
		if not _brush_size_slider.is_node_ready():
			await _brush_size_slider.ready
		_brush_size_slider.value = value
	get:
		return int(_brush_size_slider.value)

var _last_drawing_position: Vector2
var drawing: = false

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
				drawing = true
				_last_drawing_position = event.position
				_erase_stamp(editor.active_layer.image, event.position, brush_size)
				editor.queue_redraw()
			else:
				drawing = false

	if event is InputEventMouseMotion and drawing:
		# If moving too fast, add intermediate points to ensure a continuous line
		var distance = _last_drawing_position.distance_to(event.position)
		if distance > brush_size * 0.5:  # Add more points if moving faster than half the brush size
			var steps = ceil(distance / (brush_size * 0.25))  # Adjust divisor to control density
			for i in range(1, steps):
				var t = float(i) / steps
				var lerp_pos = _last_drawing_position.lerp(event.position, t)
				_erase_stamp(editor.active_layer.image, lerp_pos, brush_size)
		
		_erase_stamp(editor.active_layer.image, event.position, brush_size)
		_last_drawing_position = event.position
		editor.queue_redraw()

# Optimized eraser stamp
func _erase_stamp(target_image: Image, center: Vector2, diameter: int) -> void:
	# Get cached pixel pattern for this radius
	var radius = diameter / 2
	if radius < 1: radius = 1
	
	var pixels = _get_cached_circle_pixels(radius)
	
	# Calculate integer center position
	var center_x = int(center.x)
	var center_y = int(center.y)
	
	# Apply the stamp pattern to the image
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			target_image.set_pixel(x, y, Color.TRANSPARENT)

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
				# Store x, y offset in Vector3 (z unused for eraser)
				pixels.append(Vector3(x, y, 1.0))
	
	# Cache the pattern
	_circle_cache[radius] = pixels
	return pixels

# Legacy method (for reference)
func bresenham_line(start: Vector2, end: Vector2) -> PackedVector2Array:
	var pixels = PackedVector2Array()

	var x1 = int(start.x)
	var y1 = int(start.y)
	var x2 = int(end.x)
	var y2 = int(end.y)

	var dx = abs(x2 - x1)
	var dy = abs(y2 - y1)
	var sx = 1 if x1 < x2 else -1
	var sy = 1 if y1 < y2 else -1
	var err = dx - dy

	while true:
		pixels.append(Vector2(x1, y1))
		if x1 == x2 and y1 == y2:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x1 += sx
		if e2 < dx:
			err += dx
			y1 += sy

	return pixels

# Legacy method (for reference)
func get_circle_pixels(center: Vector2, radius: int) -> PackedVector2Array:
	var pixels = PackedVector2Array()
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			if (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y) <= radius * radius:
				pixels.append(Vector2(x, y))
	return pixels

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