extends Control

#varibles where weadding out notes Head and descriptionn

@onready var _default_zoom = theme.default_font_size
@onready var text_note_check_box: CheckBox = $CreatNewNote/Panel/VBoxContainer/NoteTypeButtonGroupVBox/TextNoteCheckBox
@onready var audio_check_box: CheckBox = $CreatNewNote/Panel/VBoxContainer/NoteTypeButtonGroupVBox/AudioCheckBox
@onready var image_check_box: CheckBox = $CreatNewNote/Panel/VBoxContainer/NoteTypeButtonGroupVBox/ImageCheckBox

var note_enum = SingletonObject.note_type.TEXT

var icActive = preload("res://assets/icons/Microphone_active.png")

func _ready() -> void:
	text_note_check_box.button_group.pressed.connect(change_note_type)
	
	

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
	var target_size = %VBoxRoot.size - Vector2(1450, 280)
	%CreatNewNote.borderless = false
	%CreatNewNote.size = Vector2(400, 700)
	%CreatNewNote.popup_centered()
	
#Creating new note
func _on_add_note_pressed():
	
	var Head = %NoteHead
	var Description = %NoteDescription
	
	
	
	SingletonObject.NotesTab.add_note(Head.text, Description.text)
	Head.clear()
	Description.clear()
	%CreatNewNote.hide()
	%AddNotePopUp.disabled = true

#btn attachment for notes
func _on_btn_add_attachement_pressed():
	SingletonObject.Chats._on_btn_attach_file_pressed()


func _on_btn_voice_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteDescription
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoice
	%btnVoice.icon = icActive
	%AddNotePopUp.disabled = false


func _on_btn_voice_for_header_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteHead
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForHeader
	%btnVoiceForHeader.icon = icActive
	%AddNotePopUp.disabled = false


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


func _on_note_head_text_changed() -> void:
	var text: String = %NoteHead.text
	if text.length() > 0:
		%AddNotePopUp.disabled = false
	else: 
		%AddNotePopUp.disabled = true


func change_note_type(button: CheckBox): 
	if button.text == "Text Note":
		print("text note selected")
		note_enum = SingletonObject.note_type.TEXT
	if button.text == "Audio Note":
		print("Image note selected")
		note_enum = SingletonObject.note_type.AUDIO
	if button.text == "Image Note":
		print("Image note selected")
		print_rich("[b]bold text ehere[/b]")
		note_enum = SingletonObject.note_type.IMAGE
	
	print(note_enum)
	



