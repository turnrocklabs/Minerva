extends Panel

@onready var note = preload("res://Scenes/Note.tscn")
@onready var containerShelf = %ShelfContainer



func _on_add_shelv_pressed() -> void:
	SingletonObject.DrawerTab.open_threads_popup()
	
func _on_add_note_pressed() -> void:
	$"../CreateNewNote".isDrawer = true
	$"../CreateNewNote".popup_centered()
