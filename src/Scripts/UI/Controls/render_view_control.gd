class_name RenderViewRect
extends Control


@export var _circle_radius: = 10
@export var _circle_width: = 5
@export var _rect_filled_color : = Color(255, 255, 255, 0.3)
@export var _rect_line_color: = Color.ORANGE
@export var _rect: Rect2
@export var subviewport_container: SubViewportContainer
@export var render_viewport: SubViewport
#@export var rect_start: Vector2:
	#set(value):
		#if value <= rect_start:
			#rect_start = value + Vector2.ONE
		#else:
			#rect_start = value
#@export var rect_end: Vector2:
	#set(value):
		#if value <= rect_end:
			#rect_end = value + Vector2.ONE
		#else:
			#rect_end = value
		
@export var draw_render_view: = false


enum TransformPoint {
	TOP_LEFT,
	TOP,
	TOP_RIGHT,
	RIGHT,
	BOTTOM_RIGHT,
	BOTTOM,
	BOTTOM_LEFT,
	LEFT,
	MOVE,
	ROTATE,
	NONE,
}

func _get_transform_rect_positions() -> Dictionary:
	var positions = {
		TransformPoint.TOP_LEFT: Vector2.ZERO,
		TransformPoint.TOP: Vector2(size.x/2, 0),
		TransformPoint.TOP_RIGHT: Vector2(size.x, 0),
		TransformPoint.RIGHT: Vector2(size.x, size.y/2),
		TransformPoint.BOTTOM_RIGHT: Vector2(size.x, size.y),
		TransformPoint.BOTTOM: Vector2(size.x/2, size.y),
		TransformPoint.BOTTOM_LEFT: Vector2(0, size.y),
		TransformPoint.LEFT: Vector2(0, size.y/2),
		# Add rotation handle position
		TransformPoint.ROTATE: Vector2(size.x/2, -30)
	}
	return positions

var dots_offset: Vector2 = Vector2(_circle_radius * 0.5, _circle_radius * 0.5)

func _draw():
	if draw_render_view:
		var rect = _rect
		draw_rect(rect, _rect_filled_color, 2)
		draw_rect(rect, _rect_line_color, false, 4)
		
		draw_circle(rect.position + dots_offset, _circle_radius, Color.CORAL)
		draw_circle(rect.position + dots_offset, _circle_radius, Color.WHITE_SMOKE, false, _circle_width)
		
		draw_circle(Vector2(rect.position.x, rect.end.y) + dots_offset, _circle_radius, Color.CORAL)
		draw_circle(Vector2(rect.position.x, rect.end.y) + dots_offset, _circle_radius, Color.WHITE_SMOKE, false, _circle_width)
		
		draw_circle(Vector2(rect.end.x, rect.position.y) + dots_offset, _circle_radius, Color.CORAL)
		draw_circle(Vector2(rect.end.x, rect.position.y) + dots_offset, _circle_radius, Color.WHITE_SMOKE, false, _circle_width)
		
		draw_circle(rect.end + dots_offset, _circle_radius, Color.CORAL)
		draw_circle(rect.end + dots_offset, _circle_radius, Color.WHITE_SMOKE, false, _circle_width)
		subviewport_container.position = rect.position
		subviewport_container.size = rect.size


func get_render_viewport_texture() -> ViewportTexture:
	return render_viewport.get_texture()
