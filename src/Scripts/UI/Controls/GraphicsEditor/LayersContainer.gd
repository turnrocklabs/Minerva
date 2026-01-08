class_name LayersContainer
extends Control

## Reference to the parent GraphicsEditorV2 for accessing selection state
var editor: GraphicsEditorV2

func _ready() -> void:
	# Find the GraphicsEditorV2 parent
	var parent = get_parent()
	while parent:
		if parent is GraphicsEditorV2:
			editor = parent
			break
		parent = parent.get_parent()


func _draw() -> void:
	# Selection-related drawing (marching ants, selection previews) is now handled
	# by SelectionOverlay, which is a sibling Control that draws on top of layers.
	pass


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

	# Draw solid polyline for clear visibility
	if screen_points.size() >= 2:
		draw_polyline(screen_points, Color.WHITE, 2.0, true)

	# Draw closing line back to start with lower opacity
	if points.size() >= 3:
		var from = points[-1] + layer_pos
		var to = points[0] + layer_pos
		draw_line(from, to, Color(1, 1, 1, 0.5), 1.0, true)


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

	# Draw the four sides clockwise from top-left
	_draw_dashed_line(top_left, top_right, dash_length, gap_length, color)        # Top edge
	_draw_dashed_line(top_right, bottom_right, dash_length, gap_length, color)    # Right edge
	_draw_dashed_line(bottom_right, bottom_left, dash_length, gap_length, color)  # Bottom edge
	_draw_dashed_line(bottom_left, top_left, dash_length, gap_length, color)      # Left edge


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
			draw_line(start_point, end_point, color, 1.0)

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

	for edge_pixel in edges:
		# Transform to layer screen coordinates
		var screen_pos = Vector2(edge_pixel) + layer_pos
		# Draw alternating black/white pixels for visibility
		var phase = (int(edge_pixel.x + edge_pixel.y) + offset) % (dash_length * 2)
		var color = Color.WHITE if phase < dash_length else Color.BLACK
		draw_rect(Rect2(screen_pos, Vector2(1, 1)), color)


func center_view() -> void:
	# First calculate the bounding rectangle
	var rect := Rect2()
	var first_child := true
	
	# Iterate to find the bounds of all children
	for child in get_children():
		if child is LayerV2:
			if first_child:
				rect = Rect2(child.position, Vector2.ZERO)
				first_child = false
			else:
				rect = rect.expand(child.position)
			
			# Include the child's size if available
			if child.has_method("get_size") or child.has_property("size"):
				rect = rect.expand(child.position + child.size)
	
	# If no valid children were found, exit early
	if first_child:
		return
		
	# Calculate center of the bounding rectangle
	var bounds_center = rect.position + rect.size / 2
	
	# Calculate the offset needed to center the elements
	# This assumes you want to center relative to the viewport or container
	var view_center = get_viewport_rect().size / 2
	var offset = view_center - bounds_center
	
	# Move all children by the offset to center them
	for child in get_children():
		if child is LayerV2:
			child.position += offset
