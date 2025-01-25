extends ColorRect

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is String: return true
	return false

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	data = data as String
	SingletonObject.NotesTab.add_note("Drag Note", data)
