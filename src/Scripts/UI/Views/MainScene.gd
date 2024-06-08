extends Control

#varibles where weadding out notes Head and descriptionn

@onready var _default_zoom = theme.default_font_size

func zoom_ui(factor: int):
	if theme.has_default_font_size():
		theme.default_font_size += factor
	else:
		theme.default_font_size = ThemeDB.fallback_font_size + factor

func reset_zoom():
	theme.default_font_size = _default_zoom

func _gui_input(event):

	if event.is_action_released("zoom_in", true):
		zoom_ui(1)
		
		accept_event()

	if event.is_action_released("zoom_out", true):
		zoom_ui(-1)
		
		accept_event()

#Show the window where we can add note
func _on_btn_create_note_pressed():
	#set up windows size
	var target_size = %VBoxRoot.size - Vector2(200, 200)
	%CreatNewNote.borderless = false
	%CreatNewNote.size = target_size
	%CreatNewNote.popup_centered()
	
#Creating new note
func _on_add_note_pressed():
	
	var Head = %CreatNewNote/VBoxContainer/NoteHead
	var Description = $CreatNewNote/VBoxContainer/NoteDescription
	
	if  Head.text == "" or Description.text == "":
		SingletonObject.ErrorDisplay("Error","You left empty field")
	else:
		SingletonObject.NotesTab.add_note(Head.text, Description.text)
		Head.clear()
		Description.clear()
		%CreatNewNote.hide()


func _on_btn_add_attachement_pressed():
	%VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/LeftPane/ChatPane/AttachFileDialog.popup_centered(Vector2i(700, 500))
