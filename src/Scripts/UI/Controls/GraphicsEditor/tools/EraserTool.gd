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

func _ready() -> void:
	# each time the tool is changed to this one, update the custom cursor
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				editor.set_custom_cursor(
					create_fast_circle_image(brush_size),
					Input.CursorShape.CURSOR_ARROW,
					Vector2.ONE * brush_size
				)
	)

	# when the brush size changed update the cursor
	_brush_size_slider.value_changed.connect(
		func(value: float):
			editor.set_custom_cursor(create_fast_circle_image(int(value)), Input.CursorShape.CURSOR_ARROW, Vector2.ONE * value)
	)

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				drawing = true
				_last_drawing_position = event.position
				image_draw(editor.active_layer.image, event.position, brush_color, brush_size)
				editor.queue_redraw()
			else:
				drawing = false

	if event is InputEventMouseMotion and drawing:

		for line_pixel in bresenham_line(_last_drawing_position, event.position):
			image_draw(editor.active_layer.image, line_pixel, brush_color, int(brush_size))
		
		_last_drawing_position = event.position
		editor.queue_redraw()



## Checks if given pixel is within the image and draws it using `set_pixelv`
func image_draw(target_image: Image, pos: Vector2, color: Color, point_size: int):

	for pixel in get_circle_pixels(pos, point_size):
		if pixel.x >= 0 and pixel.x < target_image.get_width() and pixel.y >= 0 and pixel.y < target_image.get_height():
			target_image.set_pixelv(pixel, color) 


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

func get_circle_pixels(center: Vector2, radius: int) -> PackedVector2Array:
	var pixels = PackedVector2Array()
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			if (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y) <= radius * radius:
				pixels.append(Vector2(x, y))
	return pixels


func create_fast_circle_image(radius: int, line_color: Color = Color(1, 1, 1, 1)) -> Image:
	var size = radius * 2 + 1
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	
	# Make the image transparent
	image.fill(Color(0, 0, 0, 0))
	
	# Main circle pixels
	var x = radius
	var y = 0
	var decision = 1 - radius
	
	# Slightly transparent color for anti-aliasing
	var aa_color = line_color
	aa_color.a = 0.5
	
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

