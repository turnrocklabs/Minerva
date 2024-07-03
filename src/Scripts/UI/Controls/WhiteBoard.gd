extends Panel

@onready var _BrushSizes: OptionButton = %BrushSize
@onready var _ColorPalette: Control = %Colors
@onready var _ColorButton: Button = %ColorButton
@onready var _ColorRect: ColorRect = %White

var is_drawing: bool = false
var BrushSize = 1
var erase_radius = 1
var is_eraser_active = false
var is_erasing = false
var color = Color(0, 0, 0)
var mouse_over_color_palette = false 
var mouse_over_buttons_panel = false
var drawing_enabled = true 
var last_position: Vector2 = Vector2.ZERO
var last_pressure: float = 0.0

# Smoothing parameters (adjust for desired effect)
const SMOOTHING_FACTOR = 0.1
const MIN_DISTANCE = 0.1 # Minimum distance between points

func _input(event: InputEvent):
	var mouse_position = get_local_mouse_position()
	if event is InputEventMouseMotion:
		if event.pressure > 0:
			if is_eraser_active:
				is_erasing = true
				erase_line_at(mouse_position)
			elif drawing_enabled:
				if not mouse_over_color_palette and not mouse_over_buttons_panel:
					if not is_drawing:
						is_drawing = true
						last_position = mouse_position
						last_pressure = event.pressure
					else:
						# Apply smoothing
						smooth_line(last_position, last_pressure, mouse_position, event.pressure)
		else:
			is_drawing = false
			is_erasing = false 

func smooth_line(start: Vector2, start_pressure: float, end: Vector2, end_pressure: float):
	var distance = start.distance_to(end)
	if distance > MIN_DISTANCE:
		var smoothed_position = start.lerp(end, SMOOTHING_FACTOR)
		var smoothed_pressure = lerp(start_pressure, end_pressure, SMOOTHING_FACTOR)
		create_line_segment(last_position, last_pressure, smoothed_position, smoothed_pressure)
		last_position = smoothed_position
		last_pressure = smoothed_pressure
	else:
		create_line_segment(last_position, last_pressure, end, end_pressure)
		last_position = end
		last_pressure = end_pressure

func create_line_segment(start: Vector2, start_pressure: float, end: Vector2, end_pressure: float):
	var line_segment = Line2D.new()
	line_segment.default_color = color
	line_segment.width = BrushSize * (start_pressure + end_pressure) / 2.0 
	line_segment.add_point(start)
	line_segment.add_point(end)
	_ColorRect.add_child(line_segment)

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
	for i in range(line.get_point_count() - 1):
		var start = line.get_point_position(i)
		var end = line.get_point_position(i + 1)
		if start.distance_to(point) <= erase_radius or end.distance_to(point) <= erase_radius:
			line.queue_free()

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
