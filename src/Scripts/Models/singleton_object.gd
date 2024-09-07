extends Node

#region global variables
var supported_image_formats: PackedStringArray = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "svg"]
var supported_text_fortmats: PackedStringArray = ["txt", "rs", "toml", "md", "json", "xml", "csv", "log", "py", "cs", "minproj", "gd", "tscn", "godot", "go"]
var supported_video_formats: PackedStringArray = ["mp4", "mov", "avi", "mkv", "webm"]
var supported_audio_formats: PackedStringArray = ["mp3", "wav", "ogg"]
var is_graph:bool
var is_masking:bool
var CloudType
#endregion global variables

#region Config File
var config_file_name: String = "user://config_file.cfg"
var config_file = ConfigFile.new()

# use this method to save any settings to the file
func save_to_config_file(section: String, field: String, value):
	#config_file.get_sections()
	config_file.set_value(section, field, value)
	config_file.save(config_file_name)

#method for checking if the user has saved files
func has_recent_projects() -> bool:
	return config_file.has_section("OpenRecent")

#method for adding the project to the open recent list
func save_recent_project(path: String):
	var path_split = path.split("/")
	var project_name_index: int = path_split.size() - 1
	var project_name = path_split[project_name_index]
	
	save_to_config_file("OpenRecent",project_name, path)

# this function returns an array with the files 
# names of the recent project saved in config file
func get_recent_projects() -> Array:
	if has_recent_projects():
		#print(config_file.get_section_keys("OpenRecent"))
		return config_file.get_section_keys("OpenRecent")
	return ["no recent projects"]

# method for getting the p0ath on disk of the specified project file
func get_project_path(project_name: String) -> String:
	return config_file.get_value("OpenRecent", project_name)

# method for erasing all the recently opened projects
func clear_recent_projects() -> void:
	config_file.erase_section("OpenRecent")
	config_file.save(config_file_name)


#endregion Config File


#region Notes
enum note_type {
	TEXT,
	AUDIO, 
	IMAGE,
	VIDEO
}

# this signals get used in memoryTabs.gd and new_thread_popup.gd 
# for creating and updating notes tabs names
@warning_ignore("unused_signal")
signal create_notes_tab(name: String)
@warning_ignore("unused_signal")
signal associated_notes_tab(tab_name, tab: Control)
@warning_ignore("unused_signal")
signal pop_up_new_tab


var ThreadList: Array[MemoryThread]#:  =[]
	#set(value):
		## save_state(false)
		#ThreadList = value

## Notes that don't reside inside any thread. eg. Editor and terminal notes
var DetachedNotes: Array[MemoryItem]

var NotesTab: MemoryTabs
##reorder array
func initialize_notes(threads: Array[MemoryThread] = []):
	ThreadList = threads
	
	NotesTab.render_threads()
	pass

@warning_ignore("unused_signal")
signal AttachNoteFile(file_path:String)


func toggle_all_notes(notes_enabled: bool):
	if notes_enabled:
		NotesTab.Disable_All()
	if !notes_enabled:
		NotesTab.enable_all()

## Returns `MemoryThread` with the given `ThreadId` or null if none are found
func get_thread(thread_id: String) -> MemoryThread:
	var r_arr = ThreadList.filter(func(thread: MemoryThread): return thread.ThreadId == thread_id)
	return r_arr.pop_front()

#endregion Notes

#region Chats
@warning_ignore("unused_signal")
signal chat_completed(response: BotResponse)

var ChatList: Array[ChatHistory]:
	set(value):
		# save_state(false)
		ChatList = value

var last_thread_index: int
var last_tab_index: int
# var active_chatindex: int just use Chats.current_tab
# var Provider: BaseProvider
var Chats: ChatPane
#Add undo to use it throught the singleton
var undo: undoMain = undoMain.new()
#Add AtT to use it throught the singleton
var AtT: AudioToTexts = AudioToTexts.new()

##region Buttons/Icons scaling
#var buttons_array: Array = []
#
#func get_all_children(in_node, array := []) -> Array:
	#array.push_back(in_node)
	#for child in in_node.get_children():
		#array = get_all_children(child, array)
	#return array
#
#
#func fill_buttons_array() -> void:
	#for element in get_all_children(get_tree().get_root()):
		#if element is BaseButton:
			#buttons_array.append(element)
#
#var buttons_scale: float = 1.0
#var max_buttons_scale: float = 3.0
#var min_buttons_scale: float = 1.0
#
#func change_buttons_zoom(factor: float) -> void:
	#for button: Button in buttons_array:
		#if button.icon:
			#if factor == 0.5:
				#button.custom_minimum_size.x = button.size.x + 24
			#else:
				#button.custom_minimum_size.x = button.size.x - 24
			##buttons_scale += factor
			##button.scale = Vector2(buttons_scale, buttons_scale)
#
##endregion Buttons/Icons scaling

func _ready():
	#we call this function to get all the buttons in the scene tree
	#fill_buttons_array()
	#change_buttons_zoom(0.5)
	#print(buttons_array.size())
	#for button in buttons_array:
		#print(button.name)
	
	
	#var screen_size = DisplayServer.screen_get_size()
	#var dpi = DisplayServer.screen_get_dpi()
	#print("screen size: " + str(screen_size))
	#print("dpi: "+ str(dpi))
	#var new_scale: float = screen_size.y / 1080
	#
	#print("scale: " + str(new_scale))
	#if dpi > 140:
		#get_window().content_scale_factor = new_scale
		#print("dpi is above 140, new scale factor is now: " + str(new_scale))
	#
	#if screen_size.y > 1200:
		#get_window().content_scale_factor = 1.3
		#print("scale factor: 1.3")
	#if screen_size.y < 900:
		#get_window().content_scale_factor = 0.7
		#print("scale factor: 0.7")
	
	
	add_child(AtT)
	add_child(undo)
	
	var err = config_file.load(config_file_name)
	if err != OK:
		return
	
	
	var theme_enum = get_theme_enum()
	if theme_enum > -1:
		set_theme(theme_enum)
	
	var mic_selected = get_microphone()
	if mic_selected:
		set_microphone(mic_selected)


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

@onready var editor_container: EditorContainer = $"/root/RootControl/VBoxRoot/VSplitContainer/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain"
@onready var editor_pane: EditorPane = editor_container.editor_pane if editor_container else null
var editors: Array[Editor]
#endregion

#region Common UI Tasks

@onready var main_ui = $"/root/RootControl/VBoxRoot/VSplitContainer/MainUI"

###
# Create a common error display system that will popup an error and show
# and show the message
var errorPopup: PersistentWindow
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
	GOOGLE_VERTEX_PRO,
	DALLE,
	CLAUDE_SONNET,
}

## Dictionary of all model providers and scripts that implement their functionality
var API_MODEL_PROVIDER_SCRIPTS = {
	API_MODEL_PROVIDERS.CHAT_GPT_4O: ChatGPT4o,
	API_MODEL_PROVIDERS.CHAT_GPT_35_TURBO: ChatGPT35Turbo,
	API_MODEL_PROVIDERS.GOOGLE_VERTEX: GoogleAi,
	API_MODEL_PROVIDERS.GOOGLE_VERTEX_PRO: GoogleAi_PRO,
	API_MODEL_PROVIDERS.DALLE: DallE,
	API_MODEL_PROVIDERS.CLAUDE_SONNET: ClaudeSonnet,
}

## This function will return the `API_MODEL_PROVIDERS` enum value
## for the provider currently in use by passed tab or the active one
func get_active_provider(tab: int = SingletonObject.Chats.current_tab) -> API_MODEL_PROVIDERS:
	
	# get currently used provider script or the chats default one
	var provider_script = Chats.default_provider_script if ChatList.is_empty() else ChatList[tab].provider.get_script()

	for key: API_MODEL_PROVIDERS in API_MODEL_PROVIDER_SCRIPTS:
		if API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
			return key

	# fallback value
	return API_MODEL_PROVIDERS.CHAT_GPT_4O

@onready var preferences_popup: PreferencesPopup = $"/root/RootControl/PreferencesPopup"

#endregion API Consumer

#region Project Management
@warning_ignore("unused_signal")
signal NewProject
@warning_ignore("unused_signal")
signal OpenProject
@warning_ignore("unused_signal")
signal OpenRecentProject(recent_project_name: String)
@warning_ignore("unused_signal")
signal SaveProject
@warning_ignore("unused_signal")
signal SaveProjectAs
@warning_ignore("unused_signal")
signal PackageProject
@warning_ignore("unused_signal")
signal UnpackageProject
@warning_ignore("unused_signal")
signal CloseProject
@warning_ignore("unused_signal")
signal RedrawAll
@warning_ignore("unused_signal")
signal SaveOpenEditorTabs
@warning_ignore("unused_signal")
signal UpdateLastSavePath(new_path: String)
@warning_ignore("unused_signal")
signal UpdateUnsavedTabIcon

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
@warning_ignore("unused_signal")
signal theme_changed(theme_enum)


func get_theme_enum() -> int:
	return config_file.get_value("theme", "theme_enum",0)


func set_theme(themeID: int) -> void:
	if get_theme_enum() != themeID:
		print("theme enum:" + str(themeID))
		match themeID:
			theme.LIGHT_MODE:
				var _light_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/light_mode.theme")
				var light_theme = ResourceLoader.load_threaded_get("res://assets/themes/light_mode.theme")
				root_control.theme = light_theme
				save_to_config_file("theme", "theme_enum", theme.LIGHT_MODE)
			theme.DARK_MODE:
				var _dark_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/blue_dark_mode.theme")
				var dark_theme = ResourceLoader.load_threaded_get("res://assets/themes/blue_dark_mode.theme")
				root_control.theme = dark_theme
				save_to_config_file("theme", "theme_enum", theme.DARK_MODE)
		theme_changed.emit(themeID)

#endregion Theme change


#region Audio Settings
@warning_ignore("unused_signal")
signal mic_changed(micrphone)

func get_microphone():
	return config_file.get_value("AudioSettings", "SelectedMic",  "Default")


func set_microphone(mic: String) -> void:
	AudioServer.set_input_device(mic)
	save_to_config_file("AudioSettings", "SelectedMic", mic)
	mic_changed.emit(mic)

#endregion Audio Settings


#region Loading screen stuff
@warning_ignore("unused_signal")
signal Loading(state, label_text)

func show_loading_screen(_label_text: String = ""):
	Loading.emit(true, _label_text)

func hide_loading_screen():
	Loading.emit(false, "")

#endregion Loading screen stuff
