extends Node

## REGION Tabbed Objects
var ThreadList: Array[MemoryThread]
var NotesTab: MemoryTabs

func initialize_notes():
	ThreadList = []
	NotesTab.render_threads()
	pass

## ENDREGION Tabbed Objects

## REGION Chats
var ChatList: Array[ChatHistory]
var last_tab_index: int
var active_chatindex: int
var Provider
var Chats: ChatPane

func initialize_chats(provider, _chats:ChatPane):
	last_tab_index = 0
	active_chatindex = 0
	ChatList = []
	Provider = provider
	Chats = _chats
	Chats.clear_all_chats()
	pass

## ENDREGION Chats

## REGION Common UI Tasks

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

## ENDREGION Common UI Tasks

## REGION API Consumer
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
			config_file.set_value("API KEYS", "GOOGLE_VERTEX", "CAT")
			config_file.set_value("API KEYS", "ANTHROPIC", "")
			config_file.set_value("API KEYS", "OPENAI", "")
			load_api_keys()

## ENDREGION API Consumer

## REGION Project Management

## Function:
# _new_project empties all the tabs and lists currently stored as notes or chats.
func _new_project():
	initialize_notes()
	initialize_chats(Provider, Chats)
	pass

## ENDREGION Project Management
