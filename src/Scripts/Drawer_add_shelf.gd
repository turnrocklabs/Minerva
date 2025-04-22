extends Panel

@onready var note = preload("res://Scenes/Note.tscn")
@onready var containerShelf = %ShelfContainer

var active_tab: VBoxContainer = null

func _ready() -> void:
	var a = %new_shelf_popup.find_child("Panel")
	a.connect("passAdasdsa", aloha)


func _on_add_shelv_pressed() -> void:
	%new_shelf_popup.popup_centered()
	
func aloha(ah):
	%tcThreads2.create_new_notes_tab(ah)
	pass
func _on_add_note_pressed() -> void:
	$"../CreateNewNote".isDrawer = true
	$"../CreateNewNote".popup_centered()
