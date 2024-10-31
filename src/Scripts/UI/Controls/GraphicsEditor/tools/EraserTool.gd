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


func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				drawing = true
				_last_drawing_position = event.position
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

