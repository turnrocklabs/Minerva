extends PersistentWindow

signal create_system_prompt_message(message)

@onready var _provider_option_button = %ProviderOptionButton as OptionButton
@onready var option_button:OptionButton = %Microphones

## Returns the script of the provider thats selected.
## `get_selected_provider().new()` to instantiate it
func get_selected_provider() -> GDScript:
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[_provider_option_button.get_selected_id()]

func _ready():
	super()
	for key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		_provider_option_button.add_item("%s %s" % [instance.provider_name, instance.model_name], key)


func _on_provider_option_button_item_selected(index: int):
	var item_id = _provider_option_button.get_item_id(index)

	var provider_script: Script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]

	SingletonObject.Chats.default_provider_script = provider_script

	if SingletonObject.ChatList.is_empty():
		SingletonObject.Chats._provider_option_button.select(index)




func _on_accept_button_pressed() -> void:
	var system_prompt_text = %SystemPromptTextEdit.text
	create_system_prompt_message.emit(system_prompt_text)
	hide()


func _on_cancel_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	hide()


func _on_about_to_popup() -> void:
	if SingletonObject.ChatList.size() > 0:
		var current_tab: int = SingletonObject.Chats.current_tab
		if SingletonObject.ChatList[current_tab].HasUsedSystemPrompt:
			var chat_item = SingletonObject.Chats.get_first_chat_item()
			%SystemPromptTextEdit.text = chat_item.Message


func _on_record_sytem_prompt_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	SingletonObject.AtT.FieldForFilling = %SystemPromptTextEdit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %RecordSytemPromptButton
	%RecordSytemPromptButton.modulate = Color(Color.LIME_GREEN)
