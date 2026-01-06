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


## Load all settings from the current chat tab (or defaults if no chat).
## Called by ChatPane before showing this window.
func load_current_chat_settings() -> void:
	%ToolAccessLabel.text = "Tool Access:"

	if SingletonObject.ChatList.is_empty():
		# No active chats - show defaults and still populate tools
		current_chat_tab_ref = null
		%SystemPromptTextEdit.text = ""

		# Reset sliders to defaults
		%TempHSlider.value = 1.0
		%TempSliderValueLabel.text = "1.0"
		%TopPHSlider.value = 1.0
		%TopPValueLabel.text = "1.0"
		%FreqHSlider.value = 0.0
		%FreqPenSliderValueLabel.text = "0"
		%PresenceHSlider.value = 0.0
		%PresPenSliderValueLabel.text = "0"

		# Reset agentic settings to defaults
		%MaxToolRoundsSpinBox.value = 10
		%AutoContinueCheckButton.button_pressed = true
		%AllowedDirsTextEdit.text = ""
		%AgenticSystemPromptTextEdit.text = ""
		# Context limits (0 = use defaults)
		%MaxToolResultSpinBox.value = 0
		%ContextWarningSpinBox.value = 0
		%ContextHardLimitSpinBox.value = 0
		%SummarizeThresholdSpinBox.value = 0

		# Image generation settings (global, not per-chat)
		%MaxImageIterationsSpinBox.value = SingletonObject.max_image_iterations

		# Still populate tool checkboxes (for visibility)
		populate_tool_checkboxes()

		# Update UI for default provider
		var provider = SingletonObject.Chats._provider_option_button.get_selected_provider()
		if provider:
			update_ui_for_provider(provider)
		return

	var current_tab: int = SingletonObject.Chats.current_tab
	current_chat_tab_ref = SingletonObject.ChatList[current_tab]

	# Load system prompt if used
	if current_chat_tab_ref.HasUsedSystemPrompt:
		var chat_item = SingletonObject.Chats.get_first_chat_item()
		%SystemPromptTextEdit.text = chat_item.Message

	# Load slider values
	%TempHSlider.value = current_chat_tab_ref.Temperature
	%TempSliderValueLabel.text = str(current_chat_tab_ref.Temperature)

	%TopPHSlider.value = current_chat_tab_ref.TopP
	%TopPValueLabel.text = str(current_chat_tab_ref.TopP)

	%FreqHSlider.value = current_chat_tab_ref.FrequencyPenalty
	%FreqPenSliderValueLabel.text = str(current_chat_tab_ref.FrequencyPenalty)

	%PresenceHSlider.value = current_chat_tab_ref.PresencePenalty
	%PresPenSliderValueLabel.text = str(current_chat_tab_ref.PresencePenalty)

	# Load agentic settings
	%MaxToolRoundsSpinBox.value = current_chat_tab_ref.MaxToolCallRounds
	%AutoContinueCheckButton.button_pressed = current_chat_tab_ref.AutoContinueToolCalls

	# Load allowed directories (one per line)
	var dirs_text = "\n".join(current_chat_tab_ref.AllowedDirectories)
	%AllowedDirsTextEdit.text = dirs_text

	# Load agentic system prompt
	%AgenticSystemPromptTextEdit.text = current_chat_tab_ref.AgenticSystemPrompt

	# Load context limit settings
	%MaxToolResultSpinBox.value = current_chat_tab_ref.AgentMaxToolResultLength
	%ContextWarningSpinBox.value = current_chat_tab_ref.AgentContextWarningThreshold
	%ContextHardLimitSpinBox.value = current_chat_tab_ref.AgentContextHardLimit
	%SummarizeThresholdSpinBox.value = current_chat_tab_ref.AgentSummarizeThreshold

	# Populate tool checkboxes
	populate_tool_checkboxes()

	# Update UI visibility based on provider capabilities
	update_ui_for_provider(current_chat_tab_ref.provider)


## Sync the provider dropdown to match ChatPane's current selection.
## Called by ChatPane before showing this window.
func sync_provider_to_current_chat() -> void:
	# Get the currently selected provider instance from ChatPane
	var provider = SingletonObject.Chats._provider_option_button.get_selected_provider()
	if provider == null:
		return

	# Build the display text in the same format we use (provider_name + display_name)
	var target_text = "%s %s" % [provider.provider_name, provider.display_name]

	# Find and select matching item in our dropdown
	for i in range(_provider_option_button.get_item_count()):
		if _provider_option_button.get_item_text(i) == target_text:
			_provider_option_button.select(i)
			return


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
		if provider != null:
			_provider_option_button.select(_provider_option_button.get_item_index(provider))


func _on_provider_option_button_item_selected(index: int):
	var item_id = _provider_option_button.get_item_id(index)

	var provider_script: Script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]

	SingletonObject.Chats.default_provider_script = provider_script
	SingletonObject.save_to_config_file("Providers", "DefaultProviderId", item_id)
	SingletonObject.save_to_config_file("Providers", "DefaultProviderName", _provider_option_button.get_item_text(index))

	# Update ChatPane's dropdown selection only when no chats are open (for consistency)
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

		# Load agentic settings
		%MaxToolRoundsSpinBox.value = current_chat_tab_ref.MaxToolCallRounds
		%AutoContinueCheckButton.button_pressed = current_chat_tab_ref.AutoContinueToolCalls

		# Load allowed directories (one per line)
		var dirs_text = "\n".join(current_chat_tab_ref.AllowedDirectories)
		%AllowedDirsTextEdit.text = dirs_text

		# Load agentic system prompt
		%AgenticSystemPromptTextEdit.text = current_chat_tab_ref.AgenticSystemPrompt

		# Load context limit settings
		%MaxToolResultSpinBox.value = current_chat_tab_ref.AgentMaxToolResultLength
		%ContextWarningSpinBox.value = current_chat_tab_ref.AgentContextWarningThreshold
		%ContextHardLimitSpinBox.value = current_chat_tab_ref.AgentContextHardLimit
		%SummarizeThresholdSpinBox.value = current_chat_tab_ref.AgentSummarizeThreshold

		# Image generation settings (global, not per-chat)
		%MaxImageIterationsSpinBox.value = SingletonObject.max_image_iterations

		# Populate tool checkboxes
		populate_tool_checkboxes()

		# Update UI visibility based on provider capabilities
		update_ui_for_provider(current_chat_tab_ref.provider)


## Populate tool checkboxes from MCP manager
func populate_tool_checkboxes() -> void:
	var container = %ToolCheckboxContainer

	# Clear existing checkboxes
	for child in container.get_children():
		child.queue_free()

	# Get available tools from MCP manager
	var mcp = SingletonObject.get_mcp_manager()
	if mcp == null:
		_add_tool_placeholder(container, "(Enable Agent Mode to configure tools)")
		return

	var tools = mcp.get_available_tools()
	if tools.is_empty():
		_add_tool_placeholder(container, "(No MCP tools registered)")
		return

	# Get disabled tools list (empty if no active chat)
	var disabled_tools: Array[String] = []
	if current_chat_tab_ref != null:
		disabled_tools = current_chat_tab_ref.DisabledTools

	# Create a checkbox for each tool
	var added_count := 0
	for tool in tools:
		var tool_name: String = tool.name
		if tool_name.is_empty():
			continue

		var checkbox = CheckButton.new()
		checkbox.text = tool_name
		checkbox.button_pressed = tool_name not in disabled_tools
		checkbox.toggled.connect(_on_tool_checkbox_toggled.bind(tool_name))
		container.add_child(checkbox)
		added_count += 1

	if added_count == 0:
		_add_tool_placeholder(container, "(No tools with valid names)")


func _add_tool_placeholder(container: Control, message: String) -> void:
	var label = Label.new()
	label.text = message
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	container.add_child(label)


## Handle tool checkbox toggle
func _on_tool_checkbox_toggled(enabled: bool, tool_name: String) -> void:
	if current_chat_tab_ref == null:
		return

	if enabled:
		# Remove from disabled list
		var idx = current_chat_tab_ref.DisabledTools.find(tool_name)
		if idx >= 0:
			current_chat_tab_ref.DisabledTools.remove_at(idx)
	else:
		# Add to disabled list
		if tool_name not in current_chat_tab_ref.DisabledTools:
			current_chat_tab_ref.DisabledTools.append(tool_name)

	print("DisabledTools: " + str(current_chat_tab_ref.DisabledTools))


## Update UI visibility based on provider capabilities
func update_ui_for_provider(provider: BaseProvider) -> void:
	if provider == null:
		return

	# Temperature section visibility
	%TemperatureHBoxContainer.visible = provider.supports_temperature
	if provider.temperature_warning and not provider.temperature_warning.is_empty():
		%TemperatureWarning.text = provider.temperature_warning
		%TemperatureWarning.visible = true
	else:
		%TemperatureWarning.visible = false

	# Update temperature slider max value based on provider
	%TempHSlider.max_value = provider.temperature_max

	# Top P section visibility
	%TopPHBoxContainer.visible = provider.supports_top_p

	# Frequency/Presence penalty visibility
	%FrequencyBoxContainer.visible = provider.supports_frequency_penalty
	%PresenceHBoxContainer.visible = provider.supports_presence_penalty

	# System prompt section visibility
	%SystemPromptVBoxContainer.visible = provider.supports_system_prompt


func _on_record_system_prompt_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	SingletonObject.AtT.FieldForFilling = %SystemPromptTextEdit
	if SingletonObject.AtT._StartConverting() != OK: return
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


#region Agentic settings

func _on_max_tool_rounds_spin_box_value_changed(value: float) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.MaxToolCallRounds = int(value)
		print("MaxToolCallRounds: " + str(current_chat_tab_ref.MaxToolCallRounds))
	else:
		print("no chats are open right now")


func _on_auto_continue_check_button_toggled(toggled_on: bool) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AutoContinueToolCalls = toggled_on
		print("AutoContinueToolCalls: " + str(current_chat_tab_ref.AutoContinueToolCalls))
	else:
		print("no chats are open right now")


func _on_allowed_dirs_text_edit_text_changed() -> void:
	if current_chat_tab_ref:
		var text = %AllowedDirsTextEdit.text.strip_edges()
		var dirs: Array[String] = []
		if not text.is_empty():
			for line in text.split("\n"):
				var trimmed = line.strip_edges()
				if not trimmed.is_empty():
					dirs.append(trimmed)
		current_chat_tab_ref.AllowedDirectories = dirs
		print("AllowedDirectories: " + str(current_chat_tab_ref.AllowedDirectories))
	else:
		print("no chats are open right now")


func _on_agentic_system_prompt_text_edit_text_changed() -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgenticSystemPrompt = %AgenticSystemPromptTextEdit.text
		print("AgenticSystemPrompt updated")
	else:
		print("no chats are open right now")


func _on_record_agentic_system_prompt_button_pressed() -> void:
	%AgenticSystemPromptTextEdit.text = ""
	SingletonObject.AtT.FieldForFilling = %AgenticSystemPromptTextEdit
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.btn = %RecordAgenticSystemPromptButton
	%RecordAgenticSystemPromptButton.modulate = Color(Color.LIME_GREEN)


func _on_max_tool_result_spin_box_value_changed(value: float) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgentMaxToolResultLength = int(value)
		print("AgentMaxToolResultLength: " + str(current_chat_tab_ref.AgentMaxToolResultLength))
	else:
		print("no chats are open right now")


func _on_context_warning_spin_box_value_changed(value: float) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgentContextWarningThreshold = int(value)
		print("AgentContextWarningThreshold: " + str(current_chat_tab_ref.AgentContextWarningThreshold))
	else:
		print("no chats are open right now")


func _on_context_hard_limit_spin_box_value_changed(value: float) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgentContextHardLimit = int(value)
		print("AgentContextHardLimit: " + str(current_chat_tab_ref.AgentContextHardLimit))
	else:
		print("no chats are open right now")


func _on_summarize_threshold_spin_box_value_changed(value: float) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgentSummarizeThreshold = int(value)
		print("AgentSummarizeThreshold: " + str(current_chat_tab_ref.AgentSummarizeThreshold))
	else:
		print("no chats are open right now")


func _on_max_image_iterations_spin_box_value_changed(value: float) -> void:
	SingletonObject.max_image_iterations = int(value)
	print("max_image_iterations: " + str(SingletonObject.max_image_iterations))

#endregion Agentic settings


func _on_close_requested() -> void:
	current_chat_tab_ref = null
	_on_cancel_button_pressed()
