extends Button

func _get_drag_data(at_position: Vector2) -> Variant:
	# Get the parent node you want to duplicate (in this case, "../..")
	var parent = $"../.."
	if not parent:
		print("Parent node not found!")
		return null
	
	# Duplicate the entire parent node and its children
	var preview_parent = parent.duplicate()

	# Create a container for the drag preview
	var preview = Control.new()
	preview.add_child(preview_parent)
	

	# Optional: Adjust the size of the preview to match the original node
#	preview.custom_minimum_size = parent.rect_size
	preview_parent.position = -at_position  # Center the preview under the cursor

	# Optional: Add visual feedback like transparency
	var tween = get_tree().create_tween()
	tween.tween_property(preview, "modulate:a", 0.5, 0.2)

	# Set the drag preview so it follows the mouse
	set_drag_preview(preview)
	
	#parent.get_parent().remove_child(parent)

	# Return the duplicated node for the drag
	return preview_parent
