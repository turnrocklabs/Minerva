class_name MultiMessageContainer extends Control




func _on_child_entered_tree(node: Node) -> void:
	node.reparent(%SliderContainer)


func _on_prev_button_pressed() -> void:
	%SliderContainer.previous_child()


func _on_next_button_pressed() -> void:
	%SliderContainer.next_child()
