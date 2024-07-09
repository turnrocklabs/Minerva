class_name GraphicsEditor
extends PanelContainer

var image: Image
var should_update_canvas = false
var drawing = false


@onready var _layers_container: Control = %LayersContainer
@onready var tex: TextureRect = %TextureRect



# Called when the node enters the scene tree for the first time.
func _ready():

	create_image()
	update_texture()


func create_image():
	image = Image.create(1000, 1000, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	
func update_texture():
	var texture = ImageTexture.create_from_image(image)
	tex.set_texture(texture)

	should_update_canvas = false

func _input(event):
	var l_event = _layers_container.make_input_local(event)

	if l_event is InputEventMouseButton:
		drawing = l_event.pressed
		
	if l_event is InputEventMouseMotion and drawing:

		image.set_pixel(l_event.position.x, l_event.position.y, Color.BLACK)
		should_update_canvas = true

func _process(delta):	
	if should_update_canvas:
		update_texture()	
