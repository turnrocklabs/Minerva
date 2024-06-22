extends Node

#region Config File
var config_file_name: String = "user://config_file.cfg"
var config_file = ConfigFile.new()

func save_to_config_file(section: String, field: String, value):
	
	config_file.get_sections()
	config_file.set_value(section, field, value)
	config_file.save(config_file_name)


func has_recent_projects() -> bool:
	return config_file.has_section("OpenRecent")


func save_recent_project(path: String):
	var path_split = path.split("/")
	print(path_split)
	var project_name_index: int = path_split.size() - 1
	var project_name = path_split[project_name_index]
	
	var recent_projects_array = get_recent_projects()
	
	if recent_projects_array:
		if recent_projects_array.size() > 5:
			recent_projects_array.remove_at(0)
			config_file.erase_section("OpenRecent")
			for project_name_saved in recent_projects_array:
				var saved_path = get_project_path(project_name_saved)
				save_to_config_file("OpenRecent", project_name_saved, saved_path)
	save_to_config_file("OpenRecent",project_name, path)
	

# this function returns an array with the files 
# names of the recent project saved in config file
func get_recent_projects() -> Array:
	if has_recent_projects():
		#print(config_file.get_section_keys("OpenRecent"))
		return config_file.get_section_keys("OpenRecent")
	return ["no recent projects"]

func get_project_path(project_name: String) -> String:
	return config_file.get_value("OpenRecent", project_name)
#endregion Config File

#region Notes
var ThreadList: Array[MemoryThread]:
	set(value):
		# save_state(false)
		ThreadList = value

var NotesTab: MemoryTabs

func initialize_notes(threads: Array[MemoryThread] = []):
	ThreadList = threads
	
	NotesTab.render_threads()
	pass

signal AttachNoteFile(file_path:String)


func toggle_all_notes(notes_enabled: bool):
	if notes_enabled:
		NotesTab.Disable_All()
	if !notes_enabled:
		NotesTab.enable_all()

#TODO implement function for disabling all notes in single tab
func toggle_single_tab(_enable: bool):
	pass

#endregion Notes

#region Chats

signal chat_completed(response: BotResponse)

var ChatList: Array[ChatHistory]:
	set(value):
		# save_state(false)
		ChatList = value

var last_tab_index: int
# var active_chatindex: int just use Chats.current_tab
# var Provider: BaseProvider
var Chats: ChatPane

#Add AtT to use it throught the singleton
var AtT: AudioToTexts = AudioToTexts.new()
func _ready():
	add_child(AtT)
	
	
	var err = config_file.load(config_file_name)
	if err != OK:
		return
	
	
	var theme_enum = config_file.get_value("theme", "theme_enum")
	set_theme(theme_enum)


func initialize_chats(_chats: ChatPane, chat_histories: Array[ChatHistory] = []):
	ChatList = chat_histories
	Chats = _chats
	Chats.clear_all_chats()
	
	# last_tab_index = 0
	# active_chatindex = 0

	for ch in chat_histories:
		Chats.render_history(ch)

#endregion Chats

#region Editor

@onready var editor_container: EditorContainer = $"/root/RootControl/VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain"

#endregion

#region Common UI Tasks

@onready var main_ui = $"/root/RootControl/VBoxRoot/MainUI"

###
# Create a common error display system that will popup an error and show
# and show the message
var errorPopup: PopupPanel
var errorTitle: Label
var errorText: Label
func ErrorDisplay(error_title:String, error_message: String):
	errorTitle.text = error_title
	errorText.text = error_message
	errorPopup.popup_centered()
	pass

@onready var main_scene = $"/root/RootControl"

#endregion Common UI Tasks

#region API Consumer
enum API_PROVIDER { GOOGLE, OPENAI, ANTHROPIC }

# changing the order here will probably result in having wrong provider selected
# in AISettings, as it relies on this enum to load the provider script, but not a big deal
enum API_MODEL_PROVIDERS {
	CHAT_GPT_4O,
	CHAT_GPT_35_TURBO,
	GOOGLE_VERTEX,
}

## Dictionary of all model providers and scripts that implement their functionality
var API_MODEL_PROVIDER_SCRIPTS = {
	API_MODEL_PROVIDERS.CHAT_GPT_4O: ChatGPT4o,
	API_MODEL_PROVIDERS.CHAT_GPT_35_TURBO: ChatGPT35Turbo,
	API_MODEL_PROVIDERS.GOOGLE_VERTEX: GoogleVertex,
}

## This function will return the `API_MODEL_PROVIDERS` enum value
## for the provider currently in use by the `SingletonObject.Chats`
func get_active_provider() -> API_MODEL_PROVIDERS:
	
	# get currently used provider script
	var provider_script = Chats.provider.get_script()

	for key: API_MODEL_PROVIDERS in API_MODEL_PROVIDER_SCRIPTS:
		if API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
			return key

	# fallback value
	return API_MODEL_PROVIDERS.CHAT_GPT_4O

@onready var preferences_popup: PreferencesPopup = $"/root/RootControl/PreferencesPopup"

#endregion API Consumer

#region Project Management
signal NewProject
signal OpenProject
signal OpenRecentProject(recent_project_name: String)
signal SaveProject
signal SaveProjectAs
signal CloseProject
signal RedrawAll

var saved_state = true

func save_state(state: bool): saved_state = state

#endregion Project Management

#region Check if features are open

#checks if the editor pane has a current tab
func is_editor_file_open() -> bool:
	if editor_container.editor_pane.Tabs.get_current_tab_control():
		return true
	return false


func is_notes_open() -> bool:# checks if a notes list exists
	if ThreadList:
		return true
	return false


func is_chat_open() -> bool: #checks if a chat lists exists
	if ChatList:
		return true
	return false

#checks if ANY project features are open
func any_project_features_open() -> bool:
	if is_chat_open() or is_notes_open() or is_editor_file_open():
		return true
	return false

#checks if ALL project features are open
func all_project_features_open() -> bool:
	if is_chat_open() and is_notes_open() and is_editor_file_open():
		return true
	return false

#endregion Check if features are open

#region Theme change

# get the root control node and apply the theme to it, all its children inherit the theme
@onready var root_control: Control = $"/root/RootControl"

#more themes can be added in the future with ease using the enums
enum theme {LIGHT_MODE, DARK_MODE}
signal theme_changed(theme_enum)

func get_theme() -> int:
	return config_file.get_value("theme", "theme_enum",0)


func set_theme(themeID: int) -> void:
	match themeID:
		theme.LIGHT_MODE:
			var light_theme = ResourceLoader.load("res://assets/themes/light_mode.theme")
			root_control.theme = light_theme
			save_to_config_file("theme", "theme_enum", theme.LIGHT_MODE)
		theme.DARK_MODE:
			var dark_theme = ResourceLoader.load("res://assets/themes/dark_mode.theme")
			root_control.theme = dark_theme
			save_to_config_file("theme", "theme_enum", theme.DARK_MODE)
	theme_changed.emit(themeID)


#endregion Theme change


