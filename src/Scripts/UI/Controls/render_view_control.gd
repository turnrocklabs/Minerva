class_name RenderViewRect
extends Control

@export var subviewport_container: SubViewportContainer
@export var render_viewport: SubViewport

var draw_render_view: = false
var _rect: Rect2 = Rect2()

# Drawing constants
const HANDLE_SIZE: float = 8.0
const HANDLE_COLOR: Color = Color.BLUE
const RECT_COLOR: Color = Color.ORANGE
const RECT_LINE_WIDTH: float = 3.0


func _draw() -> void:
	if not draw_render_view:
		return

	# Ensure rect has positive dimensions for drawing
	var visual_rect = _rect.abs()

	if visual_rect.size.x <= 0 or visual_rect.size.y <= 0:
		return

	# Draw selection rectangle
	draw_rect(visual_rect, RECT_COLOR, false, RECT_LINE_WIDTH)

	# Draw corner handles
	var corners = [
		visual_rect.position,  # Top-left
		Vector2(visual_rect.end.x, visual_rect.position.y),  # Top-right
		Vector2(visual_rect.position.x, visual_rect.end.y),  # Bottom-left
		visual_rect.end  # Bottom-right
	]

	for corner in corners:
		var handle_rect = Rect2(corner - Vector2(HANDLE_SIZE/2, HANDLE_SIZE/2), Vector2(HANDLE_SIZE, HANDLE_SIZE))
		draw_rect(handle_rect, HANDLE_COLOR, true)
