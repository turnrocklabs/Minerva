extends TextureRect

@onready var recentList = $"../../..".get_parent()

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if data == self: return false

	%DropTop.visible = true
	%DropBottom.visible = false
	
	return true

func _drop_data(at_position: Vector2, data: Variant) -> void:
	var indexOne = 0
	for i in recentList.get_children():
		var DroppedData = data.name.split("_")
		var FromList = i.name.split("_")
		if FromList == DroppedData:
			indexOne = recentList.get_children().find(i)
			recentList.get_child(indexOne).queue_free()
			break
			
	if recentList == null:
		printerr("RecentList not found!")
		return

	if data is Control:
		var new_button = data.duplicate()

		var local_position = recentList.get_global_transform().affine_inverse() * get_global_transform() * at_position
		var index = get_insertion_index(recentList, local_position)
		recentList.add_child(new_button)
		recentList.move_child(new_button, index)
		SingletonObject.reorder_recent_project(indexOne,index)
		
	else:
		printerr("Dropped data is not a Control node.")

# RecentDropData.gd
func get_insertion_index(container: Container, local_position: Vector2) -> int:
	for i in range(container.get_child_count()):
		var child = container.get_child(i)
		if child is Control:
			var child_rect = Rect2(child.position, child.size)
			if local_position.y < child_rect.position.y + child_rect.size.y:  # Anywhere over the child
				return i
	return container.get_child_count()
	

func _get_drag_data(at_position: Vector2) -> Variant:
	# Get the parent node you want to duplicate (in this case, "../..")
	var parent = $"../../.."
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


func _on_recent_btn_pressed() -> void:
	SingletonObject.OpenRecentProject.emit($"../..".get_meta("project_path"))
