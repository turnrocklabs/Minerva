extends PersistentWindow

signal create_system_prompt_message(message)

@onready var _provider_option_button = %ProviderOptionButton as OptionButton


enum GPT_params {
	temp,
	topP,
	FreqPenalty,
	PresPenalty
}

var current_chat_tab_ref: ChatHistory = null

## Returns the script of the provider thats selected.
## `get_selected_provider().new()` to instantiate it
func get_selected_provider() -> GDScript:
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[_provider_option_button.get_selected_id()]

func _ready():
	super()
	var sorted_keys: = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()
	sorted_keys.sort_custom(
		func(a: SingletonObject.API_MODEL_PROVIDERS, b: SingletonObject.API_MODEL_PROVIDERS):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		_provider_option_button.add_item("%s %s" % [instance.provider_name, instance.display_name], key)
	
	if SingletonObject.config_has_saved_section("Providers"):
		var provider  = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
		var provider_name = SingletonObject.get_config_file_value("Providers", "DefaultProviderName")
		if provider != null:
			_provider_option_button.select(_provider_option_button.get_item_index(provider))


func _on_provider_option_button_item_selected(index: int):
	var item_id = _provider_option_button.get_item_id(index)

	var provider_script: Script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]

	SingletonObject.Chats.default_provider_script = provider_script
	SingletonObject.save_to_config_file("Providers", "DefaultProviderId", item_id)
	SingletonObject.save_to_config_file("Providers", "DefaultProviderName", _provider_option_button.get_item_text(index))
	if SingletonObject.ChatList.is_empty():
		SingletonObject.Chats._provider_option_button.select(index)


func _on_accept_button_pressed() -> void:
	var system_prompt_text = %SystemPromptTextEdit.text
	create_system_prompt_message.emit(system_prompt_text)
	hide()
	%SystemPromptTextEdit.text = ""


func _on_cancel_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	hide()


func _on_about_to_popup() -> void:
	if SingletonObject.ChatList.size() > 0:
		var current_tab: int = SingletonObject.Chats.current_tab
		current_chat_tab_ref = SingletonObject.ChatList[current_tab]
		if current_chat_tab_ref.HasUsedSystemPrompt:
			var chat_item = SingletonObject.Chats.get_first_chat_item()
			%SystemPromptTextEdit.text = chat_item.Message
		
		# we get the current tab param values and update the UI sliders
		%TempHSlider.value = current_chat_tab_ref.Temperature
		%TempSliderValueLabel.text = str(current_chat_tab_ref.Temperature)
		
		%TopPHSlider.value = current_chat_tab_ref.TopP
		%TopPValueLabel.text = str(current_chat_tab_ref.TopP)
		
		%FreqHSlider.value = current_chat_tab_ref.FrequencyPenalty
		%FreqPenSliderValueLabel.text = str(current_chat_tab_ref.FrequencyPenalty)
		
		%PresenceHSlider.value = current_chat_tab_ref.PresencePenalty
		%PresPenSliderValueLabel.text = str(current_chat_tab_ref.PresencePenalty)
		


func _on_record_system_prompt_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	SingletonObject.AtT.FieldForFilling = %SystemPromptTextEdit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %RecordSystemPromptButton
	%RecordSystemPromptButton.modulate = Color(Color.LIME_GREEN)


#region Slider functs

func _on_temp_h_slider_value_changed(value: float) -> void:
	update_current_tab_param(GPT_params.temp, value)
	%TempSliderValueLabel.text = str(value)


func _on_top_ph_slider_value_changed(value: float) -> void:
	update_current_tab_param(GPT_params.topP, value)
	%TopPValueLabel.text = str(value)


func _on_freq_h_slider_value_changed(value: float) -> void:
	update_current_tab_param(GPT_params.FreqPenalty, value)
	%FreqPenSliderValueLabel.text = str(value)


func _on_presence_h_slider_value_changed(value: float) -> void:
	update_current_tab_param(GPT_params.PresPenalty, value)
	%PresPenSliderValueLabel.text = str(value)


func update_current_tab_param(param_enum: int, value: float) -> void:
	if current_chat_tab_ref:
		
		match param_enum:
			GPT_params.temp:
				current_chat_tab_ref.Temperature = value
				print("Temperature: " + str(current_chat_tab_ref.Temperature))
			GPT_params.topP:
				current_chat_tab_ref.TopP = value
				print("TopP: " + str(current_chat_tab_ref.TopP))
			GPT_params.FreqPenalty:
				current_chat_tab_ref.FrequencyPenalty = value
				print("FrequencyPenalty: " + str(current_chat_tab_ref.FrequencyPenalty))
			GPT_params.PresPenalty:
				current_chat_tab_ref.PresencePenalty = value
				print("PresencePenalty: " + str(current_chat_tab_ref.PresencePenalty))
	else:
		print("no chats are open right now")

#endregion Slider functs


func _on_close_requested() -> void:
	current_chat_tab_ref = null
	_on_cancel_button_pressed()
