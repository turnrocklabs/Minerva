class_name LayersContainer
extends Control


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

