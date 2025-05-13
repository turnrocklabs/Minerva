extends Panel

@onready var note = preload("res://Scenes/Note.tscn")
@onready var containerShelf = get_owner().get_node("%tcThreadsDrawer")



func _on_add_shelv_pressed() -> void:
	$"../DrawerThreadPopup".show()
	SingletonObject.DrawerTab.isDrawer = true
	
func _on_add_note_pressed() -> void:
	$"../CreateNewNote".isDrawer = true
	$"../CreateNewNote".popup_centered()
