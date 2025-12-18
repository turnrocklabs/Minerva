class_name SelectionOverlay
extends Control

## Overlay control for drawing selection-related graphics on top of layers.
## This control should be a sibling of LayersContainer, added after it in the scene tree,
## so it draws on top of all layer content.

## Reference to the parent GraphicsEditorV2 for accessing selection state
var editor: GraphicsEditorV2

func _ready() -> void:
	# Get the GraphicsEditorV2 via owner (root node of the scene)
	editor = owner as GraphicsEditorV2

	# Disable mouse input so it doesn't block layer interactions
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	# Draw marching ants for active selection
	if editor and editor.selection_visible and editor.has_selection():
		_draw_marching_ants()

	# Draw rectangle selection preview if rectangle select tool is active and dragging
	if editor and editor.rectangle_select_tool:
		if editor.rectangle_select_tool.is_selecting():
			_draw_rectangle_selection_preview()

	# Draw lasso selection preview if lasso select tool is active and dragging
	if editor and editor.lasso_select_tool:
		if editor.lasso_select_tool.is_selecting():
			_draw_lasso_selection_preview()


func _draw_lasso_selection_preview() -> void:
	if not editor or not editor.active_layer:
		return

	var points = editor.lasso_select_tool.get_preview_points()
	if points.size() < 2:
		return

	var layer_pos = editor.active_layer.position

	# Build transformed points array for polyline
	var screen_points = PackedVector2Array()
	for point in points:
		screen_points.append(point + layer_pos)

	# Draw polyline with black outline and white foreground for visibility
	if screen_points.size() >= 2:
		draw_polyline(screen_points, Color.BLACK, 3.0, true)
		draw_polyline(screen_points, Color.WHITE, 1.0, true)

	# Draw closing line back to start
	if points.size() >= 3:
		var from = points[-1] + layer_pos
		var to = points[0] + layer_pos
		draw_line(from, to, Color.BLACK, 3.0, true)
		draw_line(from, to, Color.WHITE, 1.0, true)


func _draw_rectangle_selection_preview() -> void:
	if not editor or not editor.active_layer:
		return

	var rect = editor.rectangle_select_tool.get_preview_rect()
	var layer_pos = editor.active_layer.position

	# Transform rect to screen coordinates
	var screen_rect = Rect2(rect.position + layer_pos, rect.size)

	# Draw dashed rectangle outline
	var dash_length = 6.0
	var gap_length = 3.0
	var color = Color.WHITE

	# Define the four corners
	var top_left = screen_rect.position
	var top_right = screen_rect.position + Vector2(screen_rect.size.x, 0)
	var bottom_right = screen_rect.end
	var bottom_left = screen_rect.position + Vector2(0, screen_rect.size.y)

	# Draw rectangle outline - black background with white foreground for visibility on any color
	draw_rect(screen_rect, Color.BLACK, false, 3.0)
	draw_rect(screen_rect, Color.WHITE, false, 1.0)


func _draw_dashed_line(from: Vector2, to: Vector2, dash: float, gap: float, color: Color) -> void:
	var total_length = from.distance_to(to)
	if total_length < 0.01:
		return

	var direction = (to - from).normalized()
	var pos = 0.0
	var drawing = true

	while pos < total_length:
		var segment_length = dash if drawing else gap
		var end_pos = min(pos + segment_length, total_length)

		if drawing:
			var start_point = from + direction * pos
			var end_point = from + direction * end_pos
			draw_line(start_point, end_point, color, 2.0)

		pos = end_pos
		drawing = not drawing


func _draw_marching_ants() -> void:
	if not editor or not editor.selection_mask or not editor.active_layer:
		return

	# Get cached selection boundary pixels
	var edges = editor.get_selection_edges()

	# Draw dashed line with animated offset
	var dash_length = 4
	var offset = int(editor._marching_ants_offset)

	# Get the active layer's position for coordinate transformation
	var layer_pos = editor.active_layer.position

	# Draw marching ants with contrasting colors for visibility on any background
	for edge_pixel in edges:
		var screen_pos = Vector2(edge_pixel) + layer_pos
		var phase = (edge_pixel.x + edge_pixel.y + offset) % (dash_length * 2)
		# Use white and dark gray (not pure black) for better visibility
		var color = Color.WHITE if phase < dash_length else Color(0.2, 0.2, 0.2)
		draw_rect(Rect2(screen_pos, Vector2(2, 2)), color)
