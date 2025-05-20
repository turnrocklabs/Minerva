extends Panel

@onready var note = preload("res://Scenes/Note.tscn")
@onready var containerShelf = get_owner().get_node("%tcThreadsDrawer")



func _on_add_shelf_pressed() -> void:
	SingletonObject.pop_up_new_drawer_tab.emit()
	SingletonObject.DrawerTab.isDrawer = true
	
func _on_add_note_pressed() -> void:
	$"../CreateNewNote".isDrawer = true
	$"../CreateNewNote".popup_centered()
