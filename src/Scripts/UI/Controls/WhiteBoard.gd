extends Panel

var color_picker
@onready var _lines: Node = %WhiteBoard
@onready var _BrushSizes = %BrushSize
var current_line: Line2D = null
var is_drawing: bool = false
var BrushSize = 1
var is_opened = false

var r = 0
var g = 0
var b = 0

func _ready():
	_BrushSizes.add_item("1",0)
	_BrushSizes.add_item("2",1)
	_BrushSizes.add_item("3",2)
	_BrushSizes.add_item("4",3)
	_BrushSizes.add_item("4",4)
	_BrushSizes.add_item("5",5)
	_BrushSizes.add_item("6",6)
	_BrushSizes.add_item("7",7)
	_BrushSizes.add_item("8",8)


func _input(event: InputEvent):
	var mouse_position = get_local_mouse_position() # Get mouse position relative to the Panel

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				is_drawing = true
				current_line = Line2D.new()
				current_line.default_color = Color(r,g,b)
				current_line.width = BrushSize # Adjust width as needed
				_lines.add_child(current_line)
				current_line.add_point(mouse_position)
			else:
				is_drawing = false 
				current_line = null 

func _process(delta):
	if is_drawing:
		var mouse_position = get_local_mouse_position() # Get mouse position relative to the Panel
		current_line.add_point(mouse_position)

func _on_clear_pressed():
	# Clear only lines, NOT the Clear button
	for child in _lines.get_children():
		if child is Line2D: # Check if the child is a Line2D
			child.queue_free()


func _on_brush_size_item_selected(index):
	BrushSize = int(_BrushSizes.get_item_text(index))
	print(BrushSize)

func _on_button_pressed():
	if not is_opened:
		# Create a new ColorPicker node
		color_picker = ColorPicker.new()
		# Connect the "color_changed" signal to a function
		color_picker.connect("color_changed", self._on_color_changed)
		# Add the ColorPicker to the scene tree
		get_tree().get_root().add_child(color_picker)
		# Set the flag to indicate that the ColorPicker is open
		is_opened = true
	else:
		color_picker.queue_free()
		# Set the flag to indicate that the ColorPicker is closed
		is_opened = false

func _on_color_changed(new_color):
	r = new_color.r
	g = new_color.g
	b = new_color.b
