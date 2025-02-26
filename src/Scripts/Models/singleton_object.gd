extends Node

#region global variables
#	Suported video format MIME types by GoogleAI see: https://ai.google.dev/gemini-api/docs/vision?lang=python
var google_supported_video_formats: = { 
	"mp4": "video/mp4", 
	"mpeg": "video/mpeg", 
	"mov": "video/mov",
	"avi": "video/avi", 
	"x-flv": "video/x-flv", 
	"mpg":  "video/mpg",
	"webm": "video/webm",
	"wmv": "video/wmv",
	"3gpp": "video/3gpp"
}
# Suported audio format MIME types by GoogleAI see: https://ai.google.dev/gemini-api/docs/audio?lang=python
var google_supported_audio_formats: = { 
	"wav": "audio/wav",
	"mp3": "audio/mp3",
	"aiff": "audio/aiff",
	"aac": "audio/aac",
	"ogg": "audio/ogg",
	"flac": "audio/flac"
}

# this are the formats that we support in this app
var supported_image_formats: PackedStringArray = ["png", "jpg", "jpeg", "bmp", "svg", "webp"] # "gif", "tiff"
var supported_text_formats: PackedStringArray = ["txt", "rs", "toml", "md", "json", "xml", "csv", "log", "py", "cs", "minproj", "gd", "tscn", "godot", "go", "java"]
var supported_video_formats: PackedStringArray = ["mp4", "mov", "avi", "mkv", "webm", "ogv"]
var supported_audio_formats: PackedStringArray = ["mp3", "wav", "ogg"]

var experimental_enabled: bool = false
signal toggle_experimental(enabled)

var is_graph:bool = false
var is_masking:bool
var is_picture:bool = false
#this is where we save the last path used to save a file or project
var last_saved_path: String

var CloudType

var is_brush
var is_square
var is_crayon
var is_marker
#endregion global variables

#region Config File
var config_file_name: String = "user://config_file.cfg"
var config_file = ConfigFile.new()

func load_config_file() -> ConfigFile:
	var err = config_file.load(config_file_name)
	if err != OK:
		return null
	else: 
		return config_file

# use this method to save any settings to the file
func save_to_config_file(section: String, field: String, value):
	#config_file.get_sections()
	config_file = load_config_file()
	config_file.set_value(section, field, value)
	config_file.save(config_file_name)

func config_has_saved_section(section: String) -> bool:
	if !section: return false
	config_file = load_config_file()
	return config_file.has_section(section)


func config_clear_section(section: String)-> void:
	if !section: return
	config_file = load_config_file()
	config_file.erase_section(section)
	config_file.save(config_file_name)


#method for checking if the user has saved files
func has_recent_projects() -> bool:
	config_file = load_config_file()
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
	config_file = load_config_file()
	if has_recent_projects():
		#print(config_file.get_section_keys("OpenRecent"))
		return config_file.get_section_keys("OpenRecent")
	return ["no recent projects"]

# method for getting the p0ath on disk of the specified project file
func get_project_path(project_name: String) -> String:
	config_file = load_config_file()
	return config_file.get_value("OpenRecent", project_name)

# method for erasing all the recently opened projects
func clear_recent_projects() -> void:
	config_file.erase_section("OpenRecent")
	config_file.save(config_file_name)

func remove_recent_project(project_name: String) -> void:
	if !has_recent_projects():
		return

	if !config_file.has_section_key("OpenRecent", project_name):
		printerr("Project '" + project_name + "' not found in recent projects.")
		return

	config_file.erase_section_key("OpenRecent", project_name)
	config_file.save(config_file_name)
	

#endregion Config File


#region Notes
enum note_type {
	TEXT,
	AUDIO, 
	IMAGE,
	VIDEO
}

enum NotesDrawState {
	UNSET,
	DRAWING,
}

# this signals get used in memoryTabs.gd and new_thread_popup.gd 
# for creating and updating notes tabs names
@warning_ignore("unused_signal")
signal create_notes_tab(name: String)
@warning_ignore("unused_signal")
signal associated_notes_tab(tab_name, tab: Control)
@warning_ignore("unused_signal")
signal pop_up_new_tab

@warning_ignore("unused_signal")
signal notes_draw_state_changed(state: int)

var notes_draw_state: int


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

## Emitted by `vboxMemoryList` when a note is toggled on/off.[br]
@warning_ignore("unused_signal")
signal note_toggled(note: Note, on: bool)
## Emitted by `vboxMemoryList` when a note has been changed.[br]
@warning_ignore("unused_signal")
signal note_changed(note: Note)

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
#Add undo to use it through the singleton
var undo: undoMain = undoMain.new()
#Add AtT to use it through the singleton
var AtT: AudioToTexts = AudioToTexts.new()

#region UI Scaling
var initial_ui_scale: float = 1
var min_ui_scale: = 0.8
var max_ui_scale: = 1.5
var scaling_factor: = 0.04

func increment_scale_ui() -> void:
	var ui_scale = get_tree().root.content_scale_factor
	if ui_scale < max_ui_scale:
		get_tree().root.content_scale_factor = ui_scale + scaling_factor
		main_scene.queue_redraw()


func decrement_ui_scale() -> void:
	var ui_scale = get_tree().root.content_scale_factor
	if ui_scale > min_ui_scale:
		get_tree().root.content_scale_factor = ui_scale - scaling_factor
		main_scene.queue_redraw()


func reset_ui_scale() -> void:
	get_tree().root.content_scale_factor = 1.0
	main_scene.queue_redraw()


func set_ui_scale(new_scale: float) -> void:
	if new_scale > min_ui_scale and new_scale < max_ui_scale:
		get_tree().root.content_scale_factor = new_scale
		main_scene.queue_redraw()

#endregion UI Scaling

func _ready():
	
	SingletonObject.notes_draw_state_changed.connect(
		func(state: int):
			notes_draw_state = state
	)
	
	add_child(AtT)
	add_child(undo)
	#TODO add ui scale to the config file and retrieve it on app load
	load_config_file()
	
	if config_has_saved_section("LastSavedPath"):
		last_saved_path = config_file.get_section_keys("LastSavedPath")[0]
	else:
		last_saved_path = "/"
	
	var theme_enum = get_theme_enum()
	if theme_enum > -1:
		set_theme(theme_enum)
	
	var mic_selected = get_microphone()
	if mic_selected:
		set_microphone(mic_selected)
	
	# this is for when you toggle experimental features
	toggle_experimental.connect(toggle_experimental_actions)
	terminal_input_event = InputMap.action_get_events("ui_terminal")
	
	# Here we create, load and add the audioPlayer for the notification sound on bot response
	chat_notification_player = AudioStreamPlayer.new()
	chat_notification_player.stream = load("res://assets/Audio/notification-2-269292.mp3")
	chat_notification_player.bus = "AudioNotesBus"
	chat_notification_player.volume_db = 11
	get_tree().root.call_deferred("add_child", chat_notification_player)

var chat_notification_player: AudioStreamPlayer

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
var Is_code_completed:bool = true
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
	HUMAN,
	CHAT_GPT_4O,
	CHAT_GPT_O1,
	CHAT_GPT_O1_MINI,
	CHAT_GPT_O1_PREVIEW,
	CHAT_GPT_O3_MINI_MEDIUM,
	CHAT_GPT_O3_MINI_HIGH,
	CHAT_GPT_35_TURBO,
	GOOGLE_VERTEX,
	GOOGLE_VERTEX_PRO,
	DALLE,
	CLAUDE_SONNET,
}

## Dictionary of all model providers and scripts that implement their functionality
var API_MODEL_PROVIDER_SCRIPTS = {
	API_MODEL_PROVIDERS.HUMAN: HumanProvider,
	API_MODEL_PROVIDERS.CHAT_GPT_O1: ChatGPTo1,
	API_MODEL_PROVIDERS.CHAT_GPT_O3_MINI_MEDIUM: ChatGPTo3.MiniMedium,
	API_MODEL_PROVIDERS.CHAT_GPT_O3_MINI_HIGH: ChatGPTo3.MiniHigh,
	# API_MODEL_PROVIDERS.CHAT_GPT_O1_MINI: ChatGPTo1.Mini,
	# API_MODEL_PROVIDERS.CHAT_GPT_O1_PREVIEW: ChatGPTo1.Preview,
	API_MODEL_PROVIDERS.DALLE: DallE,
	API_MODEL_PROVIDERS.CLAUDE_SONNET: ClaudeSonnet,
	API_MODEL_PROVIDERS.GOOGLE_VERTEX: GoogleAi,
	# API_MODEL_PROVIDERS.CHAT_GPT_4O: ChatGPT4o,
	# API_MODEL_PROVIDERS.CHAT_GPT_35_TURBO: ChatGPT35Turbo,
	API_MODEL_PROVIDERS.GOOGLE_VERTEX_PRO: GoogleAi_PRO,
}

## This function will return the `API_MODEL_PROVIDERS` enum value
## for the provider currently in use by passed tab or the active one
func get_active_provider(tab: int = SingletonObject.Chats.current_tab) -> API_MODEL_PROVIDERS:
	
	# get currently used provider script or the chats default one
	var provider_script = Chats.default_provider_script if ChatList.is_empty() else ChatList[tab].provider.get_script()

	for key: API_MODEL_PROVIDERS in API_MODEL_PROVIDER_SCRIPTS:
		if API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
			return key

	# fallback to first provider shown in the chat dropdown
	return Chats._provider_option_button.get_item_id(0) as API_MODEL_PROVIDERS

@onready var preferences_popup: PreferencesPopup = $"/root/RootControl/PreferencesPopup"

#endregion API Consumer

#region Project Management
@warning_ignore("unused_signal")
signal NewProject
@warning_ignore("unused_signal")
signal OpenProject(path: String)
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
##
@warning_ignore("unused_signal")
signal set_icon_size_24
@warning_ignore("unused_signal")
signal set_icon_size_48
@warning_ignore("unused_signal")
signal set_icon_size_68

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
#@onready var root_control: Control = $"/root/RootControl"

#more themes can be added in the future with ease using the enums
enum theme {LIGHT_MODE, DARK_MODE, WINDOWS_MODE}
@warning_ignore("unused_signal")
signal theme_changed(theme_enum)


func get_theme_enum() -> int:
	return config_file.get_value("theme", "theme_enum",0)


func set_theme(themeID: int) -> void:
	var root_control: Control = get_tree().current_scene
	if get_theme_enum() != themeID:
		match themeID:
			theme.LIGHT_MODE:
				var _light_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/light_mode.theme")
				var light_theme: = ResourceLoader.load_threaded_get("res://assets/themes/light_mode.theme")
				root_control.theme = light_theme
				save_to_config_file("theme", "theme_enum", theme.LIGHT_MODE)
			theme.DARK_MODE:
				var _dark_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/blue_dark_mode.theme")
				var dark_theme: = ResourceLoader.load_threaded_get("res://assets/themes/blue_dark_mode.theme")
				root_control.theme = dark_theme
				save_to_config_file("theme", "theme_enum", theme.DARK_MODE)
			theme.WINDOWS_MODE:
				var _windows_theme_request: = ResourceLoader.load_threaded_request("res://assets/themes/windows_mode.theme")
				var windows_theme: = ResourceLoader.load_threaded_get("res://assets/themes/windows_mode.theme")
				root_control.theme = windows_theme
				save_to_config_file("theme", "theme_enum", theme.WINDOWS_MODE)
		theme_changed.emit(themeID)

#endregion Theme change


#region Audio Settings
@warning_ignore("unused_signal")
signal mic_changed(microphone)

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

#region Prealoaded static scenes
static var video_player_scene: = preload("res://Scenes/video_player.tscn")
static var audio_contols_scene: = preload("res://Scenes/audio_note_controls.tscn")
static var image_controls_scene: = preload("res://Scenes/image_note_controls.tscn")
static var notes_scene: = preload("res://Scenes/Note.tscn")


#endregion Prealoaded static scenes

	
func reorder_recent_project(firstIndex: int, secondIndex: int) -> void:

	if !has_recent_projects():
		return

	var recent_projects: Array = get_recent_projects()

	if firstIndex < 0 or firstIndex >= recent_projects.size() or secondIndex < 0 or secondIndex >= recent_projects.size():
		printerr("Invalid indices for reordering recent project.")
		return

	# Get the project NAME at the first index
	var project_name_to_move = recent_projects[firstIndex]
	# Get the corresponding PATH
	var project_path_to_move = get_project_path(project_name_to_move)

	# Remove the project from its original position (by name/key)
	config_file.erase_section_key("OpenRecent", project_name_to_move)


	#Create a temporary dictionary to store the reordered projects
	var reordered_projects: Dictionary = {}
	var i := 0
	for project_name in recent_projects:
		if i == secondIndex:
			reordered_projects[project_name_to_move] = project_path_to_move # Insert at the new index
		if i != firstIndex: #Skip the original index of the moved project.
			reordered_projects[project_name] = get_project_path(project_name)
		i += 1

	if secondIndex >= recent_projects.size(): #handle inserting at the end
		reordered_projects[project_name_to_move] = project_path_to_move
		


	# Clear the "OpenRecent" section and add the reordered projects
	config_file.erase_section("OpenRecent")
	for key in reordered_projects:
		config_file.set_value("OpenRecent", key, reordered_projects[key])


	config_file.save(config_file_name)

# generate IDs for items: chat items, memory items and editor
func generate_UUID() -> String:
	var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
	rng.randomize() # Uses the current time to seed the random number generator
	var random_number = rng.randi() # Generates a random integer
	var hash256 = str(random_number).sha256_text()
	return hash256

var terminal_input_event: Array[InputEvent]
var view_menu: PopupMenu
var add_graphics_button: Button
func toggle_experimental_actions(enable: bool) -> void:
	if !enable:
		if InputMap.has_action("ui_terminal"):
			InputMap.action_erase_events("ui_terminal")
	else:
		for i in terminal_input_event:
			InputMap.action_add_event("ui_terminal", i)
	SingletonObject.save_to_config_file("Experimental", "enabled", enable)
