extends Button

@onready var recentList = $"../../..".get_parent().find_child("RecentList")

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	
	if data == self: return false

	if at_position.y < size.y / 2:
		%DropTop.visible = true
		%DropBottom.visible = false
	else:
		%DropBottom.visible = true
		%DropTop.visible = false

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
	
	

# Helper function to determine correct insertion index
func get_insertion_index(container: Container, local_position: Vector2) -> int:
	for i in range(container.get_child_count()):
		var child = container.get_child(i)
		if child is Control:  # Check if it's a Control node
			var child_rect = Rect2(child.position, child.size)
			if local_position.y < child_rect.position.y + child_rect.size.y / 2: # Check the half height to determine where to insert
				return i # Insert before
	return container.get_child_count() # Insert at the end if no suitable position is found
