class_name GraphicsEditor
extends PanelContainer

signal masking_ended()


@onready var _layers_container: Control = %LayersContainer
@onready var _brush_slider: HSlider = %BrushHSlider

@export var _color_picker: ColorPickerButton
@export var _mask_check_button: CheckButton
@export var _apply_mask_button: Button
@export var masking_color: Color

var _transparency_texture: CompressedTexture2D = preload("res://assets/generated/transparency.bmp")

var image: Image:
	get: return _draw_layer.image if _draw_layer else null

var drawing = false

var brush_size: int = 5:
	set(value):
		brush_size = value
		_brush_slider.value = value

var brush_color: Color:
	get: return _color_picker.color if not _masking else Color.TRANSPARENT


var _last_pos: Vector2
var _draw_begin: = false

var _draw_layer: Layer
var _mask_layer: Layer

## Is masking active. Active masking prevents any color, except for tranparency to be active
var _masking: bool:
	set(value):
		_masking = value
		_mask_check_button.button_pressed = value
		_apply_mask_button.visible = value
		if not value: masking_ended.emit()
	
	get: return _mask_check_button.button_pressed


# Called when the node enters the scene tree for the first time.
func _ready():
	
	setup(Vector2(1000, 1000), Color.WHITE)

	


func setup_from_image(image_: Image):
	for ch in _layers_container.get_children(true): ch.queue_free()
	_draw_layer = _create_layer(image_)

	var transparency_node = TextureRect.new()
	transparency_node.stretch_mode = TextureRect.STRETCH_TILE
	transparency_node.texture = _transparency_texture
	transparency_node.custom_minimum_size = _draw_layer.image.get_size()
	_layers_container.add_child(transparency_node, false, INTERNAL_MODE_FRONT)

	image = image_


func setup(canvas_size: Vector2, background_color: Color):
	var img = Image.create(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	img.fill(background_color)

	setup_from_image(img)


func create_image():
	var img = Image.create(1000, 1000, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)

	_draw_layer = _create_layer(img)


func _create_layer(from: Image, internal: InternalMode = INTERNAL_MODE_DISABLED) -> Layer:
	var layer = Layer.create(from)

	_layers_container.add_child(layer, false, internal)

	return layer


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
func image_draw(image: Image, pos: Vector2, color: Color, point_size: int):
	for pixel in get_circle_pixels(pos, point_size):
		if pixel.x >= 0 and pixel.x < image.get_width() and pixel.y >= 0 and pixel.y < image.get_height():
			image.set_pixelv(pixel, color if not _masking else Color.TRANSPARENT)

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.is_action("draw"):
		drawing = event.pressed
		_draw_begin = drawing


func _process(_delta):

	if drawing:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		var mouse_pos = _layers_container.get_local_mouse_position()

		var offset_x = (_layers_container.size.x - _draw_layer.image.get_width()) / 2
		var offset_y = (_layers_container.size.y - _draw_layer.image.get_height()) / 2
		var current_pos = Vector2(mouse_pos.x - offset_x, mouse_pos.y - offset_y)

		var active_layer = _mask_layer if _masking else _draw_layer

		if _draw_begin:
			_last_pos = current_pos

			image_draw(active_layer.image, current_pos, brush_color, brush_size)

		for line_pixel in bresenham_line(_last_pos, current_pos):
			image_draw(active_layer.image, line_pixel, brush_color, brush_size)

		_last_pos = current_pos
		
		_draw_begin = false
		
		active_layer.update()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_h_slider_value_changed(value):
	brush_size = value


func _on_mask_check_button_toggled(toggled_on: bool):
	_masking = toggled_on

	_draw_layer.visible = not _masking

	if toggled_on:
		var bgd_img = Image.new()
		bgd_img.fill(masking_color)

		var background_mask_layer = _create_layer(bgd_img, INTERNAL_MODE_FRONT)

		var img = Image.new()
		img.copy_from(_draw_layer.image)
		img.convert(Image.FORMAT_RGBA8)
		_mask_layer = _create_layer(img, INTERNAL_MODE_BACK)

		await masking_ended

		background_mask_layer.queue_free()
		_mask_layer.queue_free()
	else:
		_mask_layer = null


func _on_apply_mask_button_pressed():

	image.set_meta("mask", _mask_layer.image)

	_masking = false