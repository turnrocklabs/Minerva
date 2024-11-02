class_name LayerV2
extends Control

enum Type {
	IMAGE,
	DRAWING,
}

@onready var texture_rect: TextureRect = %TextureRect
@onready var center_container: CenterContainer = %CenterContainer


const _scene = preload("res://Scenes/LayerV2.tscn")

enum TransformPoint {
	TOP_LEFT,
	TOP,
	TOP_RIGHT,
	RIGHT,
	BOTTOM_RIGHT,
	BOTTOM,
	BOTTOM_LEFT,
	LEFT,
	NONE,
}

var _transform_rect_size: = Vector2(50, 50)

var transform_rect_visible: = false

var zoom_factor: float:
	get: return (Vector2(image.get_size()).length() / size.length())

var type: Type

var image: Image:
	set(value):
		image = value
		if not image or image.is_empty(): return
		
		if not is_node_ready():
			await ready
		
		var img = ImageTexture.create_from_image(image)
		texture_rect.texture = img
		size = img.get_size()



static func create_image_layer(name_: String, image_: Image) -> LayerV2:

	var layer: LayerV2 = _scene.instantiate()	

	layer.image = image_
	layer.name = name_
	layer.type = Type.IMAGE

	return layer

static func create_drawing_layer(name_: String, size_: Vector2i, background_color: = Color.TRANSPARENT) -> LayerV2:

	var layer: LayerV2 = _scene.instantiate()	

	var img = Image.create(size_.x, size_.y, false, Image.Format.FORMAT_RGBA8)
	img.fill(background_color)
	
	layer.image = img
	layer.name = name_
	layer.type = Type.DRAWING

	return layer

## Return the [enum TransformPoint] type of the rect thats under the given [parameter mouse_position]
func get_rect_by_mouse_position(mouse_position: Vector2) -> TransformPoint:
	var _transform_rect_positions: = _get_transform_rect_positions()
	
	for key: TransformPoint in _transform_rect_positions:
		var drag_square: = Rect2(_transform_rect_positions[key] - _transform_rect_size/2, _transform_rect_size)	
		if drag_square.has_point(mouse_position):
			return key
	
	return TransformPoint.NONE

func _draw() -> void:
	var img = ImageTexture.create_from_image(image)
	texture_rect.texture = img

	if not transform_rect_visible: return
	
	# draw 8 control squares
	var drag_square_positions: = PackedVector2Array([
		Vector2.ZERO,
		Vector2(size.x/2, 0),
		Vector2(size.x, 0),
		Vector2(size.x, size.y/2),
		Vector2(size.x, size.y),
		Vector2(size.x/2, size.y),
		Vector2(0, size.y),
		Vector2(0, size.y/2),
	])

	draw_line(Vector2.ZERO, size, Color.BLACK)
	draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color.BLACK)

	draw_line(Vector2.ZERO, Vector2(size.x, 0), Color.BLACK)
	draw_line(Vector2(size.x, 0), Vector2(size.x, size.y), Color.BLACK)
	draw_line(Vector2(size.x, size.y), Vector2(0, size.y), Color.BLACK)
	draw_line(Vector2(0, size.y), Vector2.ZERO, Color.BLACK)

	for pos in drag_square_positions:
		var drag_square: = Rect2(pos - _transform_rect_size/2, _transform_rect_size)
		
		draw_rect(drag_square.grow(2), Color.BLACK)
		draw_rect(drag_square, Color.WHITE)


func _get_transform_rect_positions() -> Dictionary:
	return {
		TransformPoint.TOP_LEFT: Vector2.ZERO,
		TransformPoint.TOP: Vector2(size.x/2, 0),
		TransformPoint.TOP_RIGHT: Vector2(size.x, 0),
		TransformPoint.RIGHT: Vector2(size.x, size.y/2),
		TransformPoint.BOTTOM_RIGHT: Vector2(size.x, size.y),
		TransformPoint.BOTTOM: Vector2(size.x/2, size.y),
		TransformPoint.BOTTOM_LEFT: Vector2(0, size.y),
		TransformPoint.LEFT: Vector2(0, size.y/2)
	}


func localize_input(event: InputEvent):
	match type:
		Type.IMAGE, Type.DRAWING:
			var ev: = make_input_local(event)
			if ev.position: ev.position *= zoom_factor
			return ev


func _on_resized() -> void:
	if not is_node_ready(): return

	texture_rect.custom_minimum_size = size
