class_name GraphicsEditor
extends PanelContainer

@onready var tex: TextureRect = %TextureRect

@onready var _layers_container: Control = %LayersContainer
@onready var _brush_slider: HSlider = %BrushHSlider

@export var _color_picker: ColorPickerButton

var _transparency_texture: CompressedTexture2D = preload("res://assets/generated/transparency.bmp")

var image: Image
var drawing = false

var brush_size: int = 5:
	set(value):
		brush_size = value
		_brush_slider.value = value

var brush_color: Color:
	get: return _color_picker.color


var _last_pos: Vector2
var _draw_begin: = false

# Pixels that await to be drawn
var _draw_pixels: = PackedVector2Array()

# Called when the node enters the scene tree for the first time.
func _ready():

	create_image()
	update_texture()

	var transparency_node = TextureRect.new()
	transparency_node.stretch_mode = TextureRect.STRETCH_TILE
	transparency_node.texture = _transparency_texture
	transparency_node.custom_minimum_size = image.get_size()
	_layers_container.add_child(transparency_node, false, INTERNAL_MODE_FRONT)


func create_image():
	image = Image.create(1000, 1000, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	
func update_texture():
	var texture = ImageTexture.create_from_image(image)
	tex.set_texture(texture)


func get_circle_pixels(center: Vector2, radius: int) -> PackedVector2Array:
	var pixels = PackedVector2Array()
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			if (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y) <= radius * radius:
				pixels.append(Vector2(x, y))
	return pixels


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


## Checks if given pixel is within the image and draws it using `set_pixelv`
func image_draw(pos: Vector2, color: Color, point_size: int):
	for pixel in get_circle_pixels(pos, point_size):
		if pixel.x >= 0 and pixel.x < image.get_width() and pixel.y >= 0 and pixel.y < image.get_height():
			image.set_pixelv(pixel, color)
			_draw_pixels.append(pixel)

func _input(event: InputEvent):
	if event is InputEventMouseButton and event.is_action("draw"):
		drawing = event.pressed
		_draw_begin = drawing


func _process(_delta):

	if drawing:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		var mouse_pos = _layers_container.get_local_mouse_position()

		var offset = (_layers_container.size.x - image.get_width()) / 2
		var current_pos = Vector2(mouse_pos.x - offset, mouse_pos.y)

		if _draw_begin:
			_last_pos = current_pos

			image_draw(current_pos, brush_color, brush_size)

		for line_pixel in bresenham_line(_last_pos, current_pos):
			image_draw(line_pixel, brush_color, brush_size)

		_last_pos = current_pos
		
		_draw_begin = false

		update_texture()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_h_slider_value_changed(value):
	brush_size = value

