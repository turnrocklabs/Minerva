class_name Layer
extends TextureRect

const _scene = preload("res://Scenes/Layer.tscn")
var image: Image


static func create(image_: Image, name_:String) -> Layer:
	var layer: Layer = _scene.instantiate()
	layer.image = image_
	layer.name = name_
	return layer


func _ready():
	#comented for now need aditional testing to find if we still nedd this two lines of code
	#for now it's bothering for inctiasing height of layers
	 
	#stretch_mode = TextureRect.STRETCH_TILE
	#expand_mode = TextureRect.EXPAND_FIT_WIDTH
	custom_minimum_size = image.get_size()
	update()

func update():
	texture = ImageTexture.create_from_image(image)
