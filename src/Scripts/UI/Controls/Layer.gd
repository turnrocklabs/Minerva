class_name Layer
extends TextureRect

const _scene = preload("res://Scenes/Layer.tscn")
var image: Image


static func create(image_: Image,name:String) -> Layer:
	var layer: Layer = _scene.instantiate()
	layer.image = image_
	layer.name = name
	return layer


func _ready():
	stretch_mode = TextureRect.STRETCH_TILE
	expand_mode = TextureRect.EXPAND_FIT_WIDTH
	custom_minimum_size = image.get_size()
	update()

func update():
	texture = ImageTexture.create_from_image(image)
