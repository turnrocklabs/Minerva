extends PopupPanel


@onready var _provider_option_button = %ProviderOptionButton as OptionButton
@onready var theme_option_button: OptionButton = %ThemeOptionButton as OptionButton

## Returns the script of the provider thats selected.
## `get_selected_provider().new()` to instantiate it
func get_selected_provider() -> GDScript:
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[_provider_option_button.get_selected_id()]

func _ready():
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
	SingletonObject.set_theme(index)


func set_theme_option_menu(theme_enum: int):
	theme_option_button.selected = theme_enum
