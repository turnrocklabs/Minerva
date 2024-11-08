extends PersistentWindow

@onready var text_note_check_box: CheckBox = %TextNoteCheckBox
@onready var audio_check_box: CheckBox = %AudioCheckBox
@onready var image_check_box: CheckBox = %ImageCheckBox

var note_enum = SingletonObject.note_type.TEXT

var effect: AudioEffect
var audio_recording: AudioStreamWAV = null
var image_original_res: Image = null

func _ready() -> void:
	#this connects the note type radio buttons 
	#so that only only one can be pressed at the time
	text_note_check_box.button_group.pressed.connect(change_note_type)
	
	self.files_dropped.connect(_on_image_files_dropped)# signal for drop image file on image note
	
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		%DropImageLabel.text = "Drop or Paste \nImage File Here"
	#setting up audio things
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)
	
	#changes the separation of the buttons on the file dialog window
	var hbox: HBoxContainer = %ImageNoteFileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 14)

#region Window signal handler functions
#this get called when the CREATE NOTE WINDOW is about to pop up
func _on_about_to_popup() -> void:
	%NoteHead.grab_focus()
	text_note_check_box.button_pressed = true
	%CreateNewNote.exclusive = true
	#should_add_note_be_disabled()
	%AddNotePopUp.disabled = true


func _on_close_requested() -> void:
	call_deferred("hide")
	%NoteHead.text = ""
	%NoteDescription.text = ""
	%ImagePreview.texture = null
	image_original_res = null
	audio_recording = null
	%ImageDropPanel.visible = true
	%CreateNewNote.exclusive = false

#endregion Window signal handler functions

#region voice buttons signal handler functions

func _on_btn_voice_for_header_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteHead
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForHeader
	#%btnVoiceForHeader.icon = icActive
	%btnVoiceForHeader.modulate = Color.LIME_GREEN
	%AddNotePopUp.disabled = false


func _on_btn_voice_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteDescription
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoice
	#%btnVoiceForNoteTab.icon = icActive
	%btnVoice.modulate = Color.LIME_GREEN

#endregion voice buttons signal handler functions

# toggles the visibility of inputs based en note type selection
func change_note_type(button: CheckBox): 
	if button.text == "Text Note":
		note_enum = SingletonObject.note_type.TEXT
		%TextNoteControl.visible = true
		%AudioControl.visible = false
		%ImageControl.visible = false
		%btnVoice.visible = true
		if %NoteDescription.text == "":
			%AddNotePopUp.disabled = true
		else: 
			%AddNotePopUp.disabled = false
	if button.text == "Audio Note":
		note_enum = SingletonObject.note_type.AUDIO
		%TextNoteControl.visible = false
		%AudioControl.visible = true
		%ImageControl.visible = false
		%btnVoice.visible = false
		if audio_recording == null:
			%AddNotePopUp.disabled = true
		else: 
			%AddNotePopUp.disabled = false
	if button.text == "Image Note":
		note_enum = SingletonObject.note_type.IMAGE
		%TextNoteControl.visible = false
		%AudioControl.visible = false
		%ImageControl.visible = true
		%btnVoice.visible = false
		if image_original_res == null:
			%AddNotePopUp.disabled = true
		else: 
			%AddNotePopUp.disabled = false


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
	should_add_note_be_disabled()

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
	should_add_note_be_disabled()

#TODO change this tom use mouse entered mouse exited signals
func mouse_over_control(node: Control) -> bool:
	var mouse_pos = get_tree().get_local_mouse_position()
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
	should_add_note_be_disabled()


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
	should_add_note_be_disabled()

func get_image_from_clipboard():
	var image = DisplayServer.clipboard_get_image()
	image_original_res = image
	var image_texture = ImageTexture.new()
	image_texture.set_image(image)
	%ImagePreview.texture = image_texture
	%ImageDropPanel.visible = false
	%ImagePreview.visible = true
	should_add_note_be_disabled()

#endregion Image Note region

#region Audio Note

# gets called when record button is pressed
func _on_record_audio_button_pressed() -> void:
	if effect.is_recording_active():
		audio_recording = effect.get_recording() # type -> AudioStreamWAV
		%RecordAudioButton.text = "Press To Record Note"
		effect.set_recording_active(false)
		%PlayAudioButton.disabled = false
		%AddNotePopUp.disabled = false
	else:
		effect.set_recording_active(true)
		%PlayAudioButton.disabled = true
		%AddNotePopUp.disabled = true
		%RecordAudioButton.text = "recording audio..."
	
	should_add_note_be_disabled()

# plays the recorded audio note
func _on_play_audio_button_pressed() -> void:
	%AudioNoteStreamPlayer.stream = audio_recording
	%AudioNoteStreamPlayer.play()

#endregion Audio Note

func should_add_note_be_disabled() -> void:
	var text_fields_filled = %NoteHead.text != "" and %NoteDescription.text != ""
	var image_field_and_title = %NoteHead.text != "" and image_original_res != null
	var audio_field_and_title = %NoteHead.text != "" and audio_recording != null
	
	if text_fields_filled or image_field_and_title or audio_field_and_title:
		%AddNotePopUp.disabled = false
	else:
		%AddNotePopUp.disabled = true

func _on_note_head_text_changed() -> void:
	should_add_note_be_disabled()


func _on_note_description_text_changed() -> void:
	should_add_note_be_disabled()
