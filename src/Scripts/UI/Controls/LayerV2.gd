class_name LayerV2
extends Control

enum Type {
	IMAGE,
}

@onready var texture_rect: TextureRect = %TextureRect
@onready var center_container: CenterContainer = %CenterContainer


const _scene = preload("res://Scenes/LayerV2.tscn")


var type: Type

var image: Image:
	set(value):
		image = value
		if not image or image.is_empty(): return
		
		if not is_node_ready():
			await ready
		
		var img = ImageTexture.create_from_image(image)
		texture_rect.texture = img
		texture_rect.size = img.get_size()


static func create_image_layer(name_: String, image_: Image) -> LayerV2:

	var layer: LayerV2 = _scene.instantiate()	

	layer.image = image_
	layer.name = name_
	layer.type = Type.IMAGE

	return layer

func _draw() -> void:
	image = image


func localize_input(event: InputEvent):
	match type:
		Type.IMAGE:
			return texture_rect.make_input_local(event)
	