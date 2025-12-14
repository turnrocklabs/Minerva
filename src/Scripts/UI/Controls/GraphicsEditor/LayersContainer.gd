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
	if editor and editor.selection_visible and editor.has_selection():
		_draw_marching_ants()


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
