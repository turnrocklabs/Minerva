extends Control

#varibles where weadding out notes Head and descriptionn

@onready var _default_zoom = theme.default_font_size

@export  var terminal_container: TerminalTabContainer

var icActive = preload("res://assets/icons/Microphone_active.png")


func _ready() -> void:
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %fdgOpenFile.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 14)

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

# this method pops up the preferences window
func _on_button_pressed() -> void:
	%PreferencesPopup.popup_centered()

#btn attachment for notes
func _on_btn_add_attachement_pressed():
	SingletonObject.Chats._on_btn_attach_file_pressed()


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

var license_agreement_status: = ResourceLoader.load_threaded_request("res://Scenes/license_agreement_panel.tscn")
var license_scene: = ResourceLoader.load_threaded_get("res://Scenes/license_agreement_panel.tscn")

var about_status: = ResourceLoader.load_threaded_request("res://Scenes/about_popup.tscn")
var about_scene: = ResourceLoader.load_threaded_get("res://Scenes/about_popup.tscn")
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
