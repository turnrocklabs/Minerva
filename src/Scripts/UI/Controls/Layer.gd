class_name Layer
extends TextureRect

const _scene = preload("res://Scenes/Layer.tscn")
var image: Image:
	set(new_image):
		image = new_image
		update()
var layer_name: String
var left: bool
var right: bool
var top: bool
var bottom: bool
var topLeft: bool
var bottomLeft: bool
var topRight: bool
var bottomRight: bool

var dragging:bool
static func create(image_: Image, name_:String) -> Layer:
	var layer: Layer = _scene.instantiate()
	layer.image = image_
	layer.layer_name = name_
	return layer


func _ready():
	%EditButton1.connect("button_up",self.cancelDragging)
	%EditButton2.connect("button_up",self.cancelDragging)
	%EditButton3.connect("button_up",self.cancelDragging)
	%EditButton4.connect("button_up",self.cancelDragging)
	%EditButton5.connect("button_up",self.cancelDragging)
	%EditButton6.connect("button_up",self.cancelDragging)
	%EditButton7.connect("button_up",self.cancelDragging)
	%EditButton8.connect("button_up",self.cancelDragging)
	custom_minimum_size = image.get_size()


func update(image_: Image = null):# this method get called every time a stroke is done on a layer
	if image_ != null and !image_.is_empty():
		texture = ImageTexture.create_from_image(image_)
	else:
		if self.image:
			texture = ImageTexture.create_from_image(self.image)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and dragging:
		var delta_x = event.relative.x
		var delta_y = event.relative.y

		# Corner Dragging - Adjust All Sides
		if topLeft:
			%EditButton1.position.x += delta_x
			%EditButton1.position.y += delta_y
			
			%EditButton2.position.y += delta_y  # Move top-right (vertically only)
			%EditButton4.position.x += delta_x  # Move bottom-left (horizontally only)
			
			%EditButton5.position.x += delta_x
			%EditButton3.position.y += delta_y
			
			position.x += delta_x
			position.y += delta_y
			size.x -= delta_x
			size.y -= delta_y
			
		if topRight:
			%EditButton3.position.x += delta_x
			%EditButton3.position.y += delta_y
			%EditButton2.position.y += delta_y  # Move top-left
			%EditButton8.position.x += delta_x  # Move bottom-right
			%EditButton1.position.y += delta_y  # Move top-left (for consistent width)
			%EditButton7.position.x += delta_x  # Move bottom-right (for consistent height) 
			
			position.y += delta_y
			size.x += delta_x
			size.y -= delta_y

		if bottomLeft:
			%EditButton5.position.x += delta_x
			%EditButton5.position.y += delta_y
			%EditButton6.position.y += delta_y  # Move bottom-right
			%EditButton4.position.x += delta_x  # Move top-left 
			%EditButton7.position.y += delta_y  # Move bottom-right (for consistent width)
			%EditButton1.position.x += delta_x  # Move top-left (for consistent height) 
			
			position.x += delta_x
			size.x -= delta_x
			size.y += delta_y

		if bottomRight:
			%EditButton7.position.x += delta_x
			%EditButton7.position.y += delta_y
			
			%EditButton5.position.y += delta_y  # Move bottom-left (horizontally only) 
			%EditButton6.position.y += delta_y  # Move top-right (vertically only) 
			
			%EditButton8.position.x += delta_x  # Move top-right (vertically only) 
			%EditButton3.position.x += delta_x  # Move top-right (vertically only) 
			
			size.x += delta_x
			size.y += delta_y


		# Side Dragging - Maintain Opposite Side (same as before)
		if top:
			%EditButton1.position.y += delta_y
			%EditButton2.position.y += delta_y
			%EditButton3.position.y += delta_y 

			position.y += delta_y
			size.y -= delta_y

		if bottom:
			%EditButton6.position.y += delta_y
			%EditButton5.position.y += delta_y
			%EditButton7.position.y += delta_y
			
			size.y += delta_y
			

		if left:
			%EditButton4.position.x += delta_x
			%EditButton1.position.x += delta_x
			%EditButton5.position.x += delta_x
			
			position.x += delta_x
			size.x -= delta_x

		if right:
			%EditButton8.position.x += delta_x
			%EditButton3.position.x += delta_x
			%EditButton7.position.x += delta_x
			
			size.x += delta_x

		_update_edit_button_positions()
		
func _update_edit_button_positions():
	# Directly position using normalized values (0.0 to 1.0) within the Layer
	$EditButton1.position = Vector2.ZERO
	$EditButton2.position = Vector2(0.5, 0) * size 
	$EditButton3.position = Vector2(1, 0) * size  # Right edge
	$EditButton4.position = Vector2(0, 0.5) * size  # Left edge, middle
	$EditButton5.position = Vector2(0, 1) * size  # Bottom left
	$EditButton6.position = Vector2(0.5, 1) * size  # Bottom edge, middle
	$EditButton7.position = Vector2(1, 1) * size  # Right edge, middle
	$EditButton8.position = Vector2(1, 0.5) * size  # Top edge, middle
	
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


func cancelDragging():
	dragging = false


func _on_edit_button_3_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = true
	right = false
	bottomRight = false


func _on_edit_button_4_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = true
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_5_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = true
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_6_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = true
	topRight = false
	right = false
	bottomRight = false


func _on_edit_button_7_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = false
	bottomRight = true


func _on_edit_button_8_button_down() -> void:
	dragging = true
	
	topLeft = false
	left = false
	bottomLeft = false
	top = false
	bottom = false
	topRight = false
	right = true
	bottomRight = false
