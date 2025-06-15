class_name MultiSliderContainer extends VBoxContainer

signal message_updated(message_index: int)

var current_index: int = 0

func _ready() -> void:
	# Connect to existing children
	for child in get_children():
		if child is SliderContainer:
			_connect_slider(child)

func _connect_slider(slider: SliderContainer) -> void:
	# Disconnect first to prevent duplicate connections
	if slider.active_child_changed.is_connected(_update_children_index):
		slider.active_child_changed.disconnect(_update_children_index)
	
	# Connect the signal
	slider.active_child_changed.connect(_update_children_index)
	#print("Connected %s to update children function" % slider.name)

func _update_children_index(new_index: int) -> void:
	for child in get_children():
		if child is SliderContainer and child.active_child_index != new_index:
			# Temporarily disconnect to prevent recursive signal emission
			child = child as SliderContainer
			if child.active_child_changed.is_connected(_update_children_index):
				child.active_child_changed.disconnect(_update_children_index)
			child.active_child_index = new_index
			_connect_slider(child)
	
	current_index = new_index
	message_updated.emit(new_index)

func _on_child_entered_tree(node: Node) -> void:
	if node is SliderContainer:
		_connect_slider(node)

func _on_child_exiting_tree(node: Node) -> void:
	if node is SliderContainer and node.active_child_changed.is_connected(_update_children_index):
		node.active_child_changed.disconnect(_update_children_index)
