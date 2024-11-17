extends ColorRect

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	print("Can drop: ", data)
	return true

func _drop_data(at_position: Vector2, data: Variant) -> void:
	prints("Drop:", at_position, data)
	SingletonObject.NotesTab.add_note(data, data)
