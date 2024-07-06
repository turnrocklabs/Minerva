extends Panel

@onready var _BrushSizes: OptionButton = %BrushSize
@onready var _ColorPalette: Control = %Colors
@onready var _ColorRect: ColorRect = %White
@onready var _DrawZone: ColorRect = %DrawZone
@onready var _ButtonsZone: HBoxContainer = %Buttons
@onready var _Pen: Sprite2D = %Pen
@onready var _Eraser: Sprite2D = %Eraser
@onready var eraser: Button = %eraser

var is_drawing: bool = false
var BrushSize = 1
var erase_radius = 1
var is_eraser_active = false
var color = Color(0, 0, 0)
var mouse_over_color_palette = false
var mouse_over_buttons_panel = false
var last_position: Vector2 = Vector2.ZERO
var last_pressure: float = 0.0
var is_mouse_down = false

# Smoothing parameters 
const SMOOTHING_FACTOR = 0.25 
const MIN_DISTANCE = 2  

func _input(event: InputEvent):
	var mouse_position = get_local_mouse_position()
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_mouse_down = event.pressed
			if is_mouse_down and _is_mouse_in_drawing_zone(mouse_position) and not mouse_over_color_palette and not mouse_over_buttons_panel:
				is_drawing = true
				last_position = mouse_position
				last_pressure = 1.0
				if is_eraser_active:
					erase_line_at(mouse_position)
				else:
					create_point(mouse_position, last_pressure)
			else:
				is_drawing = false
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	elif event is InputEventMouseMotion:
		if is_mouse_down and is_drawing and _is_mouse_in_drawing_zone(mouse_position) and not mouse_over_color_palette and not mouse_over_buttons_panel:
			if is_eraser_active:
				erase_line_at(mouse_position)
				_Eraser.visible = true
				_Eraser.position = mouse_position + Vector2(10, -9)
			else:
				_Pen.visible = true
				_Pen.position = mouse_position + Vector2(10, -9)
				smooth_line(last_position, last_pressure, mouse_position, event.pressure)
				last_pressure = event.pressure
				Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		else:
			is_drawing = false
			_Pen.visible = false
			_Eraser.visible = false
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func smooth_line(start: Vector2, start_pressure: float, end: Vector2, end_pressure: float):
	var distance = start.distance_to(end)
	if distance > MIN_DISTANCE:
		var smoothed_position = start.lerp(end, SMOOTHING_FACTOR)
		var smoothed_pressure = lerp(start_pressure, end_pressure, SMOOTHING_FACTOR)
		create_line_segment(last_position, last_pressure, smoothed_position, smoothed_pressure)
		last_position = smoothed_position
		last_pressure = smoothed_pressure

func create_point(position: Vector2, pressure: float):
	var point = Line2D.new()
	var Bsize = BrushSize * pressure
	point.default_color = color
	point.width = Bsize
	point.add_point(position)
	point.add_point(position + Vector2(0.1, 0.1))
	_ColorRect.add_child(point)

func create_line_segment(start: Vector2, start_pressure: float, end: Vector2, end_pressure: float):
	var line_segment = Line2D.new()
	var Bsize = BrushSize * (start_pressure + end_pressure) / 2.0
	line_segment.default_color = color
	line_segment.width = Bsize
	line_segment.add_point(start)
	line_segment.add_point(end)
	_ColorRect.add_child(line_segment)
	_Pen.visible = true

func _on_clear_pressed():
	for child in _ColorRect.get_children():
		if child is Line2D:
			child.queue_free()

func _on_brush_size_item_selected(index):
	BrushSize = int(_BrushSizes.get_item_text(index))
	erase_radius = int(_BrushSizes.get_item_text(index))

func _on_button_pressed():
	_ColorPalette.visible = !_ColorPalette.visible

func _on_colors_color_changed(new_color):
	color = new_color

func _on_eraser_pressed():
	is_eraser_active = !is_eraser_active

func erase_line_at(position: Vector2):
	for line in _ColorRect.get_children():
		if line is Line2D:
			erase_segments_from_line(line, position)

func erase_segments_from_line(line: Line2D, point: Vector2):
	for i in range(line.get_point_count() - 1):
		var start = line.get_point_position(i)
		var end = line.get_point_position(i + 1)
		if start.distance_to(point) <= erase_radius or end.distance_to(point) <= erase_radius:
			line.queue_free()
			break

func _on_colors_mouse_entered():
	mouse_over_color_palette = true
	is_drawing = false

func _on_colors_mouse_exited():
	mouse_over_color_palette = false

func _on_buttons_mouse_entered():
	mouse_over_buttons_panel = true
	is_drawing = false

func _on_buttons_mouse_exited():
	mouse_over_buttons_panel = false

func _is_mouse_in_drawing_zone(mouse_position: Vector2) -> bool:
	var rect_global_pos = _ColorRect.global_position
	var rect_size = _ColorRect.size
	return (rect_global_pos.x <= mouse_position.x and 
			mouse_position.x <= rect_global_pos.x + rect_size.x and
			rect_global_pos.y <= mouse_position.y and 
			mouse_position.y <= rect_global_pos.y + rect_size.y)
