class_name EditorCodeEdit
extends CodeEdit

var starting_version: int

func _ready():
	starting_version = get_saved_version()

func _on_text_changed():
	tag_saved_version()



	
