extends Control

#varibles where weadding out notes Head and descriptionn

@onready var _default_zoom = theme.default_font_size
var icActive = preload("res://assets/icons/Microphone_active.png")

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
	var target_size = %VBoxRoot.size - Vector2(1500, 200)
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

#btn attachment for notes
func _on_btn_add_attachement_pressed():
	SingletonObject.Chats._on_btn_attach_file_pressed()


func _on_btn_voice_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteDescription
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoice
	%btnVoice.icon = icActive

func _on_btn_voice_for_header_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteHead
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForHeader
	%btnVoiceForHeader.icon = icActive


func _on_btn_voice_for_note_tab_pressed():
	SingletonObject.AtT.FieldForFilling = %txtNewTabName
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForNoteTab
	%btnVoiceForNoteTab.icon = icActive

var notes_enabled = true
func _on_disable_notes_button_pressed() -> void:
	if !notes_enabled:
		%DisableNotesButton.text = "Disable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	if notes_enabled:
		%DisableNotesButton.text = "Enable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	
	notes_enabled = !notes_enabled






func _on_disable_notes_button_toggled(toggled_on: bool) -> void:
	pass # Replace with function body.
