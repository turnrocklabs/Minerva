extends Node

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

#endregion Notes

#region Chats
var ChatList: Array[ChatHistory]:
	set(value):
		# save_state(false)
		ChatList = value

var last_tab_index: int
# var active_chatindex: int just use Chats.current_tab
var Provider
var Chats: ChatPane

func initialize_chats(provider, _chats: ChatPane, chat_histories: Array[ChatHistory] = []):
	ChatList = chat_histories
	Provider = provider
	
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
signal SaveProject
signal SaveProjectAs
signal CloseProject
signal RedrawAll

var saved_state = true

func save_state(state: bool): saved_state = state

#endregion Project Management

#region Theme change

# get the root control node and apply the theme to it, all its children inherit the theme
@onready var root_control: Control = $"/root/RootControl"

#more themes can be added in the future with ease using the enums
enum theme {LIGHT_MODE, DARK_MODE}

func change_theme(themeID: int) -> void:
	match themeID:
		theme.LIGHT_MODE:
			var light_theme = ResourceLoader.load("res://assets/themes/light_mode.theme")
			root_control.theme = light_theme
		theme.DARK_MODE:
			var dark_theme = ResourceLoader.load("res://assets/themes/dark_mode.theme")
			root_control.theme = dark_theme
	

#endregion Theme change


