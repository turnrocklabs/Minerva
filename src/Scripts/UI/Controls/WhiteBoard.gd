extends Panel

@onready var _BrushSizes: OptionButton = %BrushSize
@onready var _ColorPalette: Control = %Colors
@onready var _ColorButton: Button = %ColorButton
@onready var _ColorRect: ColorRect = %White

var current_line: Line2D = null
var is_drawing: bool = false
var BrushSize = 1
var erase_radius = 1
var is_eraser_active = false
var is_erasing = false
var color = Color(0,0,0)
var mouse_over_color_palette = false # Flag to track if mouse is over _ColorPalette
var mouse_over_buttons_panel = false
var drawing_enabled = true # Flag to control drawing

func _input(event: InputEvent):
	var mouse_position = get_local_mouse_position()

	# Check if mouse is within _ColorRect's bounds using get_rect()
	if _ColorRect.get_rect().has_point(mouse_position):
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					if is_eraser_active:
						is_erasing = true
						erase_line_at(mouse_position)
					elif drawing_enabled: # Only draw if drawing is enabled and mouse is not over prohibited areas
						if not mouse_over_color_palette and not mouse_over_buttons_panel:
							is_drawing = true
							current_line = Line2D.new()
							current_line.default_color = color
							current_line.width = BrushSize
							_ColorRect.add_child(current_line)
							current_line.add_point(mouse_position)
				else:
					is_drawing = false
					is_erasing = false
					current_line = null

		if event is InputEventMouseMotion:
			if is_drawing and not is_eraser_active:
				if not mouse_over_color_palette and not mouse_over_buttons_panel:
					current_line.add_point(mouse_position)
			elif is_erasing:
				erase_line_at(mouse_position)

func _on_clear_pressed():
	for child in _ColorRect.get_children():
		if child is Line2D:
			child.queue_free()

func _on_brush_size_item_selected(index):
	BrushSize = int(_BrushSizes.get_item_text(index))
	erase_radius = int(_BrushSizes.get_item_text(index))
	print(BrushSize)

func _on_button_pressed():
	_ColorPalette.visible = !_ColorPalette.visible

func _on_colors_color_changed(new_color):
	color = new_color

func _on_eraser_pressed():
	is_eraser_active = !is_eraser_active

func erase_line_at(position):
	for line in _ColorRect.get_children():
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
		_ColorRect.add_child(new_line)

func _on_colors_mouse_entered():
	mouse_over_color_palette = true
	drawing_enabled = false

func _on_colors_mouse_exited():
	mouse_over_color_palette = false
	drawing_enabled = true

func _on_buttons_mouse_entered():
	mouse_over_buttons_panel = true
	drawing_enabled = false

func _on_buttons_mouse_exited():
	mouse_over_buttons_panel = false
	drawing_enabled = true
