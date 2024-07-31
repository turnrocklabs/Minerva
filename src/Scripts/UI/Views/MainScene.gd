extends Control

#varibles where weadding out notes Head and descriptionn

@onready var _default_zoom = theme.default_font_size
@onready var text_note_check_box: CheckBox = %TextNoteCheckBox
@onready var audio_check_box: CheckBox = %AudioCheckBox
@onready var image_check_box: CheckBox = %ImageCheckBox
@export  var terminal_container: TerminalTabContainer

var note_enum = SingletonObject.note_type.TEXT

var icActive = preload("res://assets/icons/Microphone_active.png")


var effect: AudioEffect
var audio_recording: AudioStreamWAV
var image_original_res: Image

func _ready() -> void:
	# we connect the signals when the project runs
	text_note_check_box.button_group.pressed.connect(change_note_type)# signal for the note type checkbtn group
	%CreateNewNote.files_dropped.connect(_on_image_files_dropped)# sinnal for drop image file on image note
	
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		%DropImageLabel.text = "Drop or Paste \nImage File Here"
	
	#setting up audio things
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)
	
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %fdgOpenFile.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)

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


func _input(event):
	if event.is_action_released("ui_terminal", true):
		terminal_container.visible = not terminal_container.visible


#Show the window where we can add note
func _on_btn_create_note_pressed():
	%CreateNewNote.popup_centered()
	
#Creating new note
func _on_add_note_pressed():
	
	var Head = %NoteHead
	var Description = %NoteDescription
	
	#SingletonObject.NotesTab.add_note(Head.text, Description.text)
	if note_enum == SingletonObject.note_type.TEXT:
		SingletonObject.NotesTab.add_note(Head.text, Description.text)
	if note_enum == SingletonObject.note_type.IMAGE:
		SingletonObject.NotesTab.add_image_note(Head.text, image_original_res)
	if note_enum == SingletonObject.note_type.AUDIO:
		SingletonObject.NotesTab.add_audio_note(Head.text, audio_recording)
	Head.clear()
	Description.clear()
	%ImagePreview.texture = null
	%ImageDropPanel.visible = true
	audio_recording = null
	%CreateNewNote.hide()
	%AddNotePopUp.disabled = true

#btn attachment for notes
func _on_btn_add_attachement_pressed():
	SingletonObject.Chats._on_btn_attach_file_pressed()


func _on_btn_voice_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteDescription
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoice
	%btnVoice.modulate = Color.LIME_GREEN
	%AddNotePopUp.disabled = false


func _on_btn_voice_for_header_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteHead
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForHeader
	#%btnVoiceForHeader.icon = icActive
	%btnVoiceForHeader.modulate = Color.LIME_GREEN
	%AddNotePopUp.disabled = false


func _on_btn_voice_for_note_tab_pressed():
	SingletonObject.AtT.FieldForFilling = %txtNewTabName
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForNoteTab
	#%btnVoiceForNoteTab.icon = icActive
	%btnVoiceForNoteTab.modulate = Color.LIME_GREEN


# this method calls the singleton object to toggle the enable/disable all notes in all tabs
var notes_enabled = true
func _on_disable_notes_button_pressed() -> void:
	if !notes_enabled:
		%DisableNotesButton.text = "Disable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	if notes_enabled:
		%DisableNotesButton.text = "Enable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	
	notes_enabled = !notes_enabled


#region Create New note Window

# the exclusive flag get  changed a lot in these methods 
#because there can only be one exclusive window at the time
#so you give up the exclusivity when closed (errors come up otherwise)

#this get called when the CREATE NOTE WINDOW is about to pop up
func _on_create_new_note_about_to_popup() -> void:
	%NoteHead.grab_focus()
	text_note_check_box.button_pressed = true
	%CreateNewNote.exclusive = true

# method for handling close button pressed
func _on_creat_new_note_close_requested() -> void:
	%CreateNewNote.hide()
	%ImagePreview.texture = null
	%ImageDropPanel.visible = true
	%CreateNewNote.exclusive = false


#this method gets called when there is a change in the 
#title text and toggles the enabled feature on add note button
func _on_note_head_text_changed() -> void:
	var text: String = %NoteHead.text
	if text.length() > 0:
		%AddNotePopUp.disabled = false
	else: 
		%AddNotePopUp.disabled = true

# toggles the visibility of inputs based en note type selection
func change_note_type(button: CheckBox): 
	if button.text == "Text Note":
		note_enum = SingletonObject.note_type.TEXT
		%TextNoteControl.visible = true
		%AudioControl.visible = false
		%ImageControl.visible = false
	if button.text == "Audio Note":
		note_enum = SingletonObject.note_type.AUDIO
		%TextNoteControl.visible = false
		%AudioControl.visible = true
		%ImageControl.visible = false
	if button.text == "Image Note":
		note_enum = SingletonObject.note_type.IMAGE
		%TextNoteControl.visible = false
		%AudioControl.visible = false
		%ImageControl.visible = true


#region Image Note region

#region Image fileDialog

# open dialog for loading image file and changes window exclusivity
func _on_open_image_file_button_pressed() -> void:
	%ImageNoteFileDialog.popup_centered()
	%CreateNewNote.exclusive = false
	%ImageNoteFileDialog.exclusive = true

#when image file is selected we give up exclusivity and load the image
func _on_image_note_file_dialog_file_selected(path: String) -> void:
	%ImageNoteFileDialog.exclusive = false
	%CreateNewNote.exclusive = true
	set_image_preview(path)

#give up exclusivity on cancel clicked
func _on_image_note_file_dialog_canceled() -> void:
	%ImageNoteFileDialog.exclusive = false
	%CreateNewNote.exclusive = true
#endregion Image fileDialog

#method for loading image file to note preview textureRect
func set_image_preview(path: String) -> void:
	var image = Image.new()
	image.load(path)
	image_original_res = image
	var image_size = image.get_size()
	if image_size.y > 200:
		var image_ratio = image_size.y/ 200.0
		image_size.y = image_size.y / image_ratio
		image_size.x = image_size.x / image_ratio
		image.resize(image_size.x, image_size.y, Image.INTERPOLATE_LANCZOS)
	var image_texture = ImageTexture.new()
	image_texture.set_image(image)
	%ImagePreview.texture = image_texture
	%ImageDropPanel.visible = false
	%ImagePreview.visible = true


func _on_image_files_dropped(files):
	if %DropImageControl.visible:
		var path: String = files[0]# get the first file to be dropped
		var file_format = get_file_format(path)# get the file format
		
		# check if file format is supported
		if file_format in SingletonObject.supported_image_formats:
			set_image_preview(path)
		else:
			#TODO implement error pop up or something
			print_rich("[b]image format not supported :c \n Maybe one day c:[/b]")

#TODO change this tom use mouse entered mouse exited signals
func mouse_over_control(node: Control) -> bool:
	var mouse_pos = get_local_mouse_position()
	if mouse_pos.x < node.global_position.x \
			or mouse_pos.x > node.global_position.x + node.size.x \
			or mouse_pos.y < node.global_position.y \
			or mouse_pos.y > node.global_position.y + node.size.y:
		return false
	return true

#check for right click on drop image control node
func _on_drop_image_control_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				pass
			MOUSE_BUTTON_RIGHT:
				print("right click")
				paste_image_from_clipboard()


func get_file_format(path: String) -> String:
	return path.split(".")[path.split(".").size() -1]


# check if display server can paste image from clipboard and does so
func paste_image_from_clipboard():
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		
		if OS.get_name() == "Linux":
			if DisplayServer.clipboard_has_image():
				get_image_from_clipboard()
			if DisplayServer.clipboard_has():
				get_image_file_from_clipboard()
		
		if OS.get_name() == "Windows":
			if DisplayServer.clipboard_has_image():
				get_image_from_clipboard()
			
	else: 
		print("Display Server does not support clipboard feature")


func get_image_file_from_clipboard():
	var path = DisplayServer.clipboard_get().split("\n")[0]
	var file_format = get_file_format(path)
	print("path file: " + path)
	if file_format in SingletonObject.supported_image_formats:
		set_image_preview(path)
		%ImageDropPanel.visible = false
		%ImagePreview.visible = true
	else:
		print_rich("[b]file format not supported :c[/b]")

func get_image_from_clipboard():
	var image = DisplayServer.clipboard_get_image()
	image_original_res = image
	var image_texture = ImageTexture.new()
	image_texture.set_image(image)
	%ImagePreview.texture = image_texture
	%ImageDropPanel.visible = false
	%ImagePreview.visible = true

#endregion Image Note region

#region Audio Note

# gets called when redord button is pressed
func _on_record_audio_button_pressed() -> void:
	if effect.is_recording_active():
		audio_recording = effect.get_recording() # type -> AudioStreamWAV
		%RecordAudioButton.text = "Press To Record Note"
		effect.set_recording_active(false)
		%PlayAudioButton.disabled = false
	else:
		effect.set_recording_active(true)
		%PlayAudioButton.disabled = true
		%RecordAudioButton.text = "recording audio..."
	

# plays the recorded audio note
func _on_play_audio_button_pressed() -> void:
	%AudioNoteStreamPlayer.stream = audio_recording
	%AudioNoteStreamPlayer.play()

#endregion Audio Note
#endregion Create New note Window


#region new tab popup
func _on_new_thread_popup_about_to_popup() -> void:
	%txtNewTabName.grab_focus()

#endregion new tab popup

func _on_button_pressed() -> void:
	%PreferencesPopup.popup_centered()
