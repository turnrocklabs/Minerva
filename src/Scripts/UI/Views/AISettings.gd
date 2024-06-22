extends PopupPanel


@onready var _provider_option_button = %ProviderOptionButton as OptionButton
@onready var theme_option_button: OptionButton = %ThemeOptionButton as OptionButton
@onready var option_button:OptionButton = %Microphones

## Returns the script of the provider thats selected.
## `get_selected_provider().new()` to instantiate it
func get_selected_provider() -> GDScript:
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[_provider_option_button.get_selected_id()]

func _ready():
	populate_microphones()
	SingletonObject.theme_changed.connect(set_theme_option_menu)
	theme_option_button.selected = SingletonObject.get_theme()
	# populate the options button with avaivable model providers
	for key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		_provider_option_button.add_item("%s %s" % [instance.provider_name, instance.model_name], key)

	# _provider_option_button.select(SingletonObject.)

func _on_provider_option_button_item_selected(index: int):
	var item_id = _provider_option_button.get_item_id(index)

	var provider_object: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	SingletonObject.Chats.set_provider(provider_object)
	# show a messageg in each chat tab that we changed the model
	for chat_history in SingletonObject.ChatList:
		chat_history.VBox.add_program_message("Changed provider to %s %s" % [provider_object.provider_name, provider_object.model_name])



func _on_about_to_popup():
	var active_provider = SingletonObject.get_active_provider()
	var item_index = _provider_option_button.get_item_index(active_provider)
	
	_provider_option_button.select(item_index)


func _on_theme_option_button_item_selected(index: int) -> void:
	SingletonObject.change_theme(index)

func populate_microphones():
	# Get the list of available microphones
	var input_devices = AudioServer.get_input_device_list()

	# Clear any existing options in the OptionButton
	option_button.clear()

	# Add each microphone to the OptionButton
	for device in input_devices:
		option_button.add_item(device)
	option_button.connect("item_selected", self._on_microphone_selected)

# Function called when user selects a microphone
func _on_microphone_selected(index: int):
	var selected_device = option_button.get_item_text(index)
	
	# Set the selected microphone as the active input device
	AudioServer.set_input_device(selected_device)
	
	# Optionally, you can notify the user or perform any other action
	print("Selected microphone:", selected_device)

func set_theme_option_menu(theme_enum: int):
	theme_option_button.selected = theme_enum
