class_name MultiMessageContainer extends VBoxContainer

signal message_updated(message_index: int)

var current_index: int = 0


func _update_children_index(new_index: int) -> void:
	print("got here")
	for i in get_children():
		if i is SliderContainer:
			i.active_child_index = new_index
	current_index = new_index


func _on_child_entered_tree(node: Node) -> void:
	if node is SliderContainer:
		print("connected %s to update children function" % node.name)
		node.active_child_changed.connect(_update_children_index)
		


func _on_child_exiting_tree(node: Node) -> void:
	if node is SliderContainer:
		node.active_child_changed.disconnect(_update_children_index)
