extends ColorRect

func _can_drop_data(_at_position: Vector2, _data: Variant) -> bool:
	return true

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	SingletonObject.NotesTab.add_note("Drag Note", data)
