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

@onready var editor_control: EditorContainer = $"/root/RootControl/VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain"

#endregion

#region Common UI Tasks

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

#endregion Common UI Tasks

#region API Consumer
enum API_PROVIDER {GOOGLE, OPENAI, ANTHROPIC}

var config_file: ConfigFile

var API_KEY: Dictionary = {}

func load_api_keys():
	self.API_KEY[API_PROVIDER.GOOGLE] = config_file.get_value("API KEYS", "GOOGLE_VERTEX", "")
	self.API_KEY[API_PROVIDER.ANTHROPIC] = config_file.get_value("API KEYS", "ANTHROPIC", "")
	self.API_KEY[API_PROVIDER.OPENAI] = config_file.get_value("API KEYS", "OPENAI", "")
	pass

func save_api_keys():
	config_file.set_value("API KEYS", "GOOGLE_VERTEX", self.API_KEY.get(API_PROVIDER.GOOGLE, ""))
	config_file.set_value("API KEYS", "ANTHROPIC", self.API_KEY.get(API_PROVIDER.ANTHROPIC, ""))
	config_file.set_value("API KEYS", "OPENAI", self.API_KEY.get(API_PROVIDER.OPENAI, ""))
	config_file.save_encrypted_pass("user://Preferences.agent", OS.get_unique_id())

func _ready():
	self.config_file = ConfigFile.new()
	var res_code = self.config_file.load_encrypted_pass("user://Preferences.agent", OS.get_unique_id())
	match res_code:
		OK:
			load_api_keys()
		ERR_FILE_NOT_FOUND:
			# populare config file with default settings
			config_file.set_value("API KEYS", "GOOGLE_VERTEX", "")
			config_file.set_value("API KEYS", "ANTHROPIC", "")
			config_file.set_value("API KEYS", "OPENAI", "")
			load_api_keys()

#endregion API Consumer

#region Project Management
signal NewProject
signal OpenProject
signal SaveProject
signal SaveProjectAs
signal CloseProject
signal RedrawAll

var saved_state = true:
	set(value):
		print("Saved state changed (%s)" % value)
		saved_state = value


func save_state(state: bool): saved_state = state

#endregion Project Management
