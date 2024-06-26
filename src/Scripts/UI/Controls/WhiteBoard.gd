extends Panel

var color_picker
@onready var _lines: Node = %WhiteBoard
@onready var _BrushSizes = %BrushSize
var current_line: Line2D = null
var is_drawing: bool = false
var BrushSize = 1
var erase_radius = 1
var is_opened = false
var is_eraser_active = false
var is_erasing = false

var r = 0
var g = 0
var b = 0

func _ready():
	_BrushSizes.add_item("1", 0)
	_BrushSizes.add_item("2", 1)
	_BrushSizes.add_item("3", 2)
	_BrushSizes.add_item("4", 3)
	_BrushSizes.add_item("4", 4)
	_BrushSizes.add_item("5", 5)
	_BrushSizes.add_item("6", 6)
	_BrushSizes.add_item("7", 7)
	_BrushSizes.add_item("8", 8)
	_BrushSizes.add_item("20", 9)

func _input(event: InputEvent):
	var mouse_position = get_local_mouse_position() # Get mouse position relative to the Panel

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if is_eraser_active:
					is_erasing = true
					erase_line_at(mouse_position)
				else:
					is_drawing = true
					current_line = Line2D.new()
					current_line.default_color = Color(r, g, b)
					current_line.width = BrushSize # Adjust width as needed
					_lines.add_child(current_line)
					current_line.add_point(mouse_position)
			else:
				is_drawing = false 
				is_erasing = false
				current_line = null

	if event is InputEventMouseMotion:
		if is_erasing:
			erase_line_at(mouse_position)

func _process(delta):
	if is_drawing and not is_eraser_active:
		var mouse_position = get_local_mouse_position() # Get mouse position relative to the Panel
		current_line.add_point(mouse_position)

func _on_clear_pressed():
	# Clear only lines, NOT the Clear button
	for child in _lines.get_children():
		if child is Line2D: # Check if the child is a Line2D
			child.queue_free()

func _on_brush_size_item_selected(index):
	BrushSize = int(_BrushSizes.get_item_text(index))
	erase_radius = int(_BrushSizes.get_item_text(index))
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

func _on_eraser_pressed():
	is_eraser_active = !is_eraser_active

func erase_line_at(position):
	for line in _lines.get_children():
		if line is Line2D:
			erase_segments_from_line(line, position)

func erase_segments_from_line(line: Line2D, point: Vector2):
	var new_lines = []
	var current_segment = []
	var point_count = line.get_point_count()

	for i in range(point_count):
		var line_point = line.get_point_position(i)
		if line_point != null:
			if line_point.distance_to(point) > erase_radius:
				current_segment.append(line_point)
			else:
				if current_segment.size() > 0:
					new_lines.append(current_segment)
					current_segment = []
	if current_segment.size() > 0:
		new_lines.append(current_segment)

	# Remove the old line
	line.queue_free()

	# Create new lines from segments
	for segment in new_lines:
		var new_line = Line2D.new()
		new_line.default_color = line.default_color
		new_line.width = line.width
		for segment_point in segment:
			new_line.add_point(segment_point)
		_lines.add_child(new_line)
