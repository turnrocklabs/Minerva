extends Tree


## Used for package management window

func _get_drag_data(_at_position: Vector2) -> Variant:
	var item: TreeItem = get_next_selected(null)
	
	var label = Label.new()
	label.text = item.get_text(0)

	set_drag_preview(label)
	return item


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is TreeItem: return false

	drop_mode_flags = Tree.DROP_MODE_INBETWEEN
	
	var drop_section:= get_drop_section_at_position(at_position)
	
	if drop_section == -100: return false
	
	var item:= get_item_at_position(at_position)

	# we can drop on item if it's a dir
	if item.get_meta("type") == "dir":
		drop_mode_flags |= Tree.DROP_MODE_ON_ITEM

	return item != data and item.get_parent()


func _drop_data(at_position: Vector2, data: Variant) -> void:
	data = data as TreeItem
	var drop_section:= get_drop_section_at_position(at_position)
	var target_item:= get_item_at_position(at_position)


	match drop_section:
		-1:
			data.move_before(target_item)
		0:
			data.get_parent().remove_child(data)
			target_item.add_child(data)
		1:
			data.move_after(target_item)





