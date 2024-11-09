extends Control

@export  var terminal_container: TerminalTabContainer
#variables where writing out notes Head and description

#these variables are for changing only the font size of the UI
var _default_zoom: int
var min_font_size:int 
var max_font_size: int
var current_font_size: int
# these are for setting upper and lower limits to the font size
var min_diff_font_size: = 4
var max_diff_font_size: = 8

func _ready() -> void:
	if theme.has_default_font_size():
		min_font_size = theme.default_font_size - min_diff_font_size
		max_font_size = theme.default_font_size + max_diff_font_size
		current_font_size = theme.default_font_size
	else:
		min_font_size = ThemeDB.fallback_font_size - min_diff_font_size
		max_font_size = ThemeDB.fallback_font_size + max_diff_font_size
		current_font_size =ThemeDB.fallback_font_size
	
	_default_zoom = current_font_size

	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %fdgOpenFile.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 14)


var MAX: = 20


func _recursive_theme_change(node: Control, callback: Callable) -> void:
	var _to_process: Array[Node] = [node]

	var counter: = 1

	while not _to_process.is_empty():

		for n in _to_process.duplicate():
			if counter > MAX:
				await get_tree().process_frame
				counter = 0
			
			if n is Control:
				callback.call(n)
				counter += 1
			
			_to_process.erase(n)

			_to_process.append_array(n.get_children())


func _set_node_font_size(node: Node, new_size: int) -> void:
	if node is MarkdownLabel:
		node.add_theme_font_size_override("bold_italics_font_size", new_size)
		node.add_theme_font_size_override("italics_font_size", new_size)
		node.add_theme_font_size_override("mono_font_size", new_size)
		node.add_theme_font_size_override("normal_font_size", new_size)
		node.add_theme_font_size_override("bold_font_size", new_size)

	elif node is Control:
		node.add_theme_font_size_override("font_size", new_size)

func _reset_node_font_size(node: Node) -> void:
	if node is MarkdownLabel:
		node.remove_theme_font_size_override("bold_italics_font_size")
		node.remove_theme_font_size_override("italics_font_size")
		node.remove_theme_font_size_override("mono_font_size")
		node.remove_theme_font_size_override("normal_font_size")
		node.remove_theme_font_size_override("bold_font_size")

	elif node is Control:
		node.remove_theme_font_size_override("font_size")


func zoom_ui(factor: int):
	# print("min_fontsize: " + str(min_font_size))
	# print("max_fontsize: " + str(max_font_size))
	# print("current_fontsize: " + str(current_font_size))

	current_font_size = clamp(current_font_size + factor, min_font_size, max_font_size)
	
	_recursive_theme_change(self, _set_node_font_size.bind(current_font_size))


	# if current_font_size + factor >= min_font_size and current_font_size + factor <= max_font_size:
	# 	if theme.has_default_font_size():
	# 		_recursive_theme_change(self, "add_theme_font_size_override", ["font_size", current_font_size + factor])
	# 		# theme.default_font_size += factor
	# 		current_font_size = current_font_size + factor
	# 	else:
	# 		_recursive_theme_change(self, "add_theme_font_size_override", ["font_size", ThemeDB.fallback_font_size + factor])
	# 		# theme.default_font_size = ThemeDB.fallback_font_size + factor
	# 		current_font_size = ThemeDB.fallback_font_size + factor


func reset_zoom():
	current_font_size = _default_zoom

	_recursive_theme_change(self, _set_node_font_size.bind(current_font_size))

	# _recursive_theme_change(self, _reset_node_font_size)


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

# this method pops up the preferences window
func _on_button_pressed() -> void:
	%PreferencesPopup.popup_centered()

#btn attachment for notes
func _on_btn_add_attachment_pressed():
	SingletonObject.Chats._on_btn_attach_file_pressed()


func _on_btn_voice_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteDescription
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoice
	%btnVoice.modulate = Color.LIME_GREEN
	%AddNotePopUp.disabled = false
	SingletonObject.AtT.btnStop = %StopButton4
	
func _on_btn_voice_for_header_pressed():
	SingletonObject.AtT.FieldForFilling = %NoteHead
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForHeader
	#%btnVoiceForHeader.icon = icActive
	%btnVoiceForHeader.modulate = Color.LIME_GREEN
	%AddNotePopUp.disabled = false
	SingletonObject.AtT.btnStop = %StopButton3

func _on_btn_voice_for_note_tab_pressed():
	SingletonObject.AtT.FieldForFilling = %txtNewTabName
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnVoiceForNoteTab
	#%btnVoiceForNoteTab.icon = icActive
	%btnVoiceForNoteTab.modulate = Color.LIME_GREEN
	%AudioStopButton2.visible = true
	SingletonObject.AtT.btnStop = %AudioStopButton2

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

#region help menu

var license_agreement_status: = ResourceLoader.load_threaded_request("res://Scenes/windows/license_agreement_panel.tscn")
var license_scene: = ResourceLoader.load_threaded_get("res://Scenes/windows/license_agreement_panel.tscn")

var about_status: = ResourceLoader.load_threaded_request("res://Scenes/windows/about_popup.tscn")
var about_scene: = ResourceLoader.load_threaded_get("res://Scenes/windows/about_popup.tscn")
func _on_help_id_pressed(id: int) -> void:
	match id:
		0:# id for the About option
			var about_scene_inst = about_scene.instantiate()
			call_deferred("add_child", about_scene_inst)
		1:# id for the license Agreement 
			var license_scene_inst = license_scene.instantiate()
			call_deferred("add_child", license_scene_inst)

#endregion help menu


func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()


func _on_audio_stop_button_2_pressed() -> void:
	SingletonObject.AtT._StopConverting()


func _on_stop_button_3_pressed() -> void:
	SingletonObject.AtT._StopConverting()


func _on_stop_button_4_pressed() -> void:
	SingletonObject.AtT._StopConverting()
