class_name Layer
extends TextureRect

const _scene = preload("res://Scenes/Layer.tscn")
var image: Image

var left
var right
var top
var bottom
var topLeft
var bottomLeft
var topRight
var bottomRight

var dragging:bool
static func create(image_: Image, name_:String) -> Layer:
	var layer: Layer = _scene.instantiate()
	layer.image = image_
	layer.name = name_
	return layer


func _ready():
	%EditButton1.connect("button_up",self.cancleDragging)
	%EditButton2.connect("button_up",self.cancleDragging)
	custom_minimum_size = image.get_size()
	update()

func update():
	texture = ImageTexture.create_from_image(image)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and dragging:
		if topLeft:
			%EditButton1.position.x += event.relative.x
		elif top:
			%EditButton2.position.y += event.relative.y

func _on_edit_button_1_button_down() -> void:
	dragging = true
	
	topLeft = true
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = false
	
	
func _on_edit_button_2_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = false
	top = true
	bottom = false
	topRight = false
	right = false
	bottomRight = false


func cancleDragging():
	dragging = false


func _on_edit_button_3_button_down() -> void:
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = true
	right = false
	bottomRight = false


func _on_edit_button_4_button_down() -> void:
	topLeft = false
	left = true
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_5_button_down() -> void:
	topLeft = false
	left = false
	bottomLeft = true
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_6_button_down() -> void:
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = true
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_7_button_down() -> void:
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = true


func _on_edit_button_8_button_down() -> void:
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = true
	bottomRight = false
