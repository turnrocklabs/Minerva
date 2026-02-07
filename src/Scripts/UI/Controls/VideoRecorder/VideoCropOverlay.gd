class_name VideoCropOverlay
extends Control
## Semi-transparent overlay showing the 9:16 vertical crop region.
## Dimmed sides with a bright center strip that is draggable left/right.

signal crop_position_changed(x: float)

## Normalized center X position of the crop (0.0 = left, 1.0 = right, 0.5 = center)
var crop_x: float = 0.5:
	set(value):
		crop_x = clampf(value, _min_x(), _max_x())
		queue_redraw()

## Dimming color for the masked regions
var dim_color := Color(0, 0, 0, 0.5)

## Whether dragging is active
var _dragging := false

## The aspect ratio of the vertical crop (9:16 width relative to 16:9 frame)
## 9/16 / (16/9) = 9*9 / (16*16) = 81/256 ≈ 0.316
const CROP_WIDTH_RATIO: float = 9.0 / 16.0 * (9.0 / 16.0)
# More accurately: In a 16:9 frame, a 9:16 crop at full height means
# width = height * 9/16, and since frame_width = height * 16/9,
# ratio = (height * 9/16) / (height * 16/9) = (9/16) / (16/9) = 81/256


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_PASS
	mouse_default_cursor_shape = CURSOR_HSIZE


func _min_x() -> float:
	return CROP_WIDTH_RATIO / 2.0


func _max_x() -> float:
	return 1.0 - CROP_WIDTH_RATIO / 2.0


func _draw() -> void:
	var rect := get_rect()
	var w := rect.size.x
	var h := rect.size.y

	var crop_pixel_width := w * CROP_WIDTH_RATIO
	var crop_center_pixel := w * crop_x

	var left_edge := crop_center_pixel - crop_pixel_width / 2.0
	var right_edge := crop_center_pixel + crop_pixel_width / 2.0

	# Draw left dimmed region
	if left_edge > 0:
		draw_rect(Rect2(0, 0, left_edge, h), dim_color)

	# Draw right dimmed region
	if right_edge < w:
		draw_rect(Rect2(right_edge, 0, w - right_edge, h), dim_color)

	# Draw crop boundary lines
	var line_color := Color(1, 1, 1, 0.7)
	var line_width := 2.0
	draw_line(Vector2(left_edge, 0), Vector2(left_edge, h), line_color, line_width)
	draw_line(Vector2(right_edge, 0), Vector2(right_edge, h), line_color, line_width)

	# Draw drag handle indicator at center
	var handle_y := h / 2.0
	var handle_size := 8.0
	draw_circle(Vector2(crop_center_pixel, handle_y), handle_size, Color(1, 1, 1, 0.8))
	draw_circle(Vector2(crop_center_pixel, handle_y), handle_size - 2, Color(0.2, 0.6, 1.0, 0.8))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_update_crop_from_mouse(event.position)
			else:
				_dragging = false
				crop_position_changed.emit(crop_x)

	elif event is InputEventMouseMotion and _dragging:
		_update_crop_from_mouse(event.position)


func _update_crop_from_mouse(pos: Vector2) -> void:
	var normalized_x := pos.x / size.x
	crop_x = normalized_x
	crop_position_changed.emit(crop_x)
