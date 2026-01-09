class_name RenderViewRect
extends Control

@export var subviewport_container: SubViewportContainer
@export var render_viewport: SubViewport
@onready var get_texture_button: Button = %GetTextureButton

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
	
	draw_rect(visual_rect, Color.ORANGE, false, 3.0)
	get_texture_button.position = visual_rect.end + Vector2(12,  - get_texture_button.size.y)
	# Draw resize handles at corners and midpoinpositionts
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
