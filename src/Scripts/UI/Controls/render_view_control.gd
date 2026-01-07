class_name RenderViewRect
extends Control

@export var subviewport_container: SubViewportContainer
@export var render_viewport: SubViewport

var draw_render_view: = false
var _rect: Rect2 = Rect2(100, 100, 200, 200)

# Drawing constants
const HANDLE_SIZE: float = 8.0 # Size of the handle squares
const HANDLE_COLOR: Color = Color.BLUE
const RECT_COLOR: Color = Color.WHITE
const RECT_LINE_WIDTH: float = 2.0
const RECT_DASH_LENGTH: float = 8.0 # For dashed line


func _draw() -> void:
	if not draw_render_view:
		return
	
	# Ensure rect has positive dimensions for drawing
	var visual_rect = _rect.abs()
	
	if visual_rect.size.x <= 0 or visual_rect.size.y <= 0:
		return
	
	# Draw the main rectangle outline using a dashed line pattern
	var p1 = visual_rect.position
	var p2 = Vector2(visual_rect.end.x, visual_rect.position.y)
	var p3 = visual_rect.end
	var p4 = Vector2(visual_rect.position.x, visual_rect.end.y)
	
	_draw_dashed_line(p1, p2, RECT_COLOR, RECT_LINE_WIDTH, RECT_DASH_LENGTH)
	_draw_dashed_line(p2, p3, RECT_COLOR, RECT_LINE_WIDTH, RECT_DASH_LENGTH)
	_draw_dashed_line(p3, p4, RECT_COLOR, RECT_LINE_WIDTH, RECT_DASH_LENGTH)
	_draw_dashed_line(p4, p1, RECT_COLOR, RECT_LINE_WIDTH, RECT_DASH_LENGTH)

	# Draw resize handles at corners and midpoints
	var tl = visual_rect.position
	var top_right = Vector2(visual_rect.end.x, visual_rect.position.y)
	var bl = Vector2(visual_rect.position.x, visual_rect.end.y)
	var br = visual_rect.end
	var tc = Vector2(visual_rect.position.x + visual_rect.size.x / 2, visual_rect.position.y)
	var bc = Vector2(visual_rect.position.x + visual_rect.size.x / 2, visual_rect.end.y)
	var ml = Vector2(visual_rect.position.x, visual_rect.position.y + visual_rect.size.y / 2)
	var mr = Vector2(visual_rect.end.x, visual_rect.position.y + visual_rect.size.y / 2)

	var handles = [tl, top_right, bl, br, tc, bc, ml, mr]
	for handle_pos in handles:
		draw_rect(Rect2(handle_pos - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE)), HANDLE_COLOR, true)

func _draw_dashed_line(p_from: Vector2, p_to: Vector2, p_color: Color, p_width: float = 1.0, p_dash_length: float = 5.0) -> void:
	var length = p_from.distance_to(p_to)
	var direction = (p_to - p_from).normalized()
	var current_pos = p_from
	var draw_segment = true

	while current_pos.distance_to(p_from) < length:
		var next_pos_segment = current_pos + direction * p_dash_length
		next_pos_segment = p_from + direction * min(current_pos.distance_to(p_from) + p_dash_length, length)

		if draw_segment:
			draw_line(current_pos, next_pos_segment, p_color, p_width)
		
		current_pos = next_pos_segment
		draw_segment = not draw_segment
