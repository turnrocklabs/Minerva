class_name RenderViewRect
extends Control

@export var editor: GraphicsEditorV2
@export var rect_start: Vector2
@export var rect_end: Vector2
@export var draw_render_view: = false

var rect = null
func _draw():
	if draw_render_view:
		var rect = Rect2(rect_start, rect_end - rect_start)
		draw_rect(rect, Color(255, 255, 255, 0.3), 2)
		draw_rect(rect, Color.ORANGE, false, 4)
	
	#draw_rect(Rect2(Vector2(300, 300), Vector2(300, 300)), Color.ORANGE, false , 6)
