extends Node

## REGION Tabbed Objects
var ThreadList: Array[MemoryThread]
var NotesTab: MemoryTabs

## ENDREGION Tabbed Objects


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