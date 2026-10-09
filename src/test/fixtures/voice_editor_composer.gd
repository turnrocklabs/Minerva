extends "res://Scripts/UI/Controls/Editor.gd"
## Keep the real editor scene and tab identity; skip unrelated document startup.
func _ready() -> void:
	code_edit = EditorCodeEdit.new()
	$VBoxContainer.add_child(code_edit)
