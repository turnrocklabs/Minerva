extends PersistentWindow

signal create_system_prompt_message(message)

@onready var _provider_option_button = %ProviderOptionButton as OptionButton

# Nano Banana Pro settings container (created dynamically)
var _nbp_settings_container: VBoxContainer = null

# Model-chat settings container (created dynamically)
var _model_chat_settings_container: VBoxContainer = null

# Timeout settings container (created dynamically)
var _timeout_settings_container: VBoxContainer = null


enum GPT_params {
	temp,
	topP,
	FreqPenalty,
	PresPenalty
}

var current_chat_tab_ref: ChatHistory = null

## Flag to prevent saving when programmatically setting text fields
var _loading_values: bool = false

## Returns the script of the provider thats selected.
## `get_selected_provider().new()` to instantiate it
func get_selected_provider() -> GDScript:
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[_provider_option_button.get_selected_id()]


## Load all settings from the current chat tab (or defaults if no chat).
## Called by ChatPane before showing this window.
func load_current_chat_settings() -> void:
	_loading_values = true
	%ToolAccessLabel.text = "Tool Access:"

	if SingletonObject.ChatList.is_empty():
		# No active chats - show defaults and still populate tools
		current_chat_tab_ref = null
		%SystemPromptTextEdit.text = ""
		%SystemPromptEnabledCheckButton.button_pressed = true

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
		%AgenticSystemPromptEnabledCheckButton.button_pressed = true
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
		_loading_values = false
		return

	var current_tab: int = SingletonObject.Chats.current_tab
	current_chat_tab_ref = SingletonObject.ChatList[current_tab]

	# Load system prompt if used, otherwise clear it
	if current_chat_tab_ref.HasUsedSystemPrompt:
		var chat_item = SingletonObject.Chats.get_first_chat_item()
		%SystemPromptTextEdit.text = chat_item.Message
	else:
		%SystemPromptTextEdit.text = ""

	# Load system prompt enabled state
	%SystemPromptEnabledCheckButton.button_pressed = current_chat_tab_ref.SystemPromptEnabled

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

	# Load agentic system prompt - show effective prompt (custom or default)
	if current_chat_tab_ref.AgenticSystemPrompt.is_empty():
		%AgenticSystemPromptTextEdit.text = SingletonObject.Chats._build_agent_system_prompt()
	else:
		%AgenticSystemPromptTextEdit.text = current_chat_tab_ref.AgenticSystemPrompt
	%AgenticSystemPromptEnabledCheckButton.button_pressed = current_chat_tab_ref.AgenticSystemPromptEnabled

	# Load context limit settings
	%MaxToolResultSpinBox.value = current_chat_tab_ref.AgentMaxToolResultLength
	%ContextWarningSpinBox.value = current_chat_tab_ref.AgentContextWarningThreshold
	%ContextHardLimitSpinBox.value = current_chat_tab_ref.AgentContextHardLimit
	%SummarizeThresholdSpinBox.value = current_chat_tab_ref.AgentSummarizeThreshold

	# Populate tool checkboxes
	populate_tool_checkboxes()

	# Update UI visibility based on provider capabilities
	update_ui_for_provider(current_chat_tab_ref.provider)
	_loading_values = false


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
	_rebuild_provider_dropdown()

	# Rebuild dropdown when providers are enabled/disabled
	SingletonObject.provider_enabled_changed.connect(_on_provider_enabled_changed)

	if SingletonObject.config_has_saved_section("Providers"):
		var provider = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
		if provider != null:
			var idx = _provider_option_button.get_item_index(provider)
			if idx >= 0:
				_provider_option_button.select(idx)


## Handle provider enable/disable changes
func _on_provider_enabled_changed(_provider: SingletonObject.API_PROVIDER, _enabled: bool) -> void:
	_rebuild_provider_dropdown()


## Rebuild the provider dropdown with only enabled providers
func _rebuild_provider_dropdown() -> void:
	var current_id = _provider_option_button.get_selected_id()
	_provider_option_button.clear()

	var sorted_keys: = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()
	sorted_keys.sort_custom(
		func(a, b):
			return _get_provider_instance(a).token_cost < _get_provider_instance(b).token_cost
	)

	for key in sorted_keys:
		# Skip models whose provider is disabled
		if not SingletonObject.is_model_enabled(key):
			continue

		var instance = _get_provider_instance(key)
		_provider_option_button.add_item("%s %s" % [instance.provider_name, instance.display_name], key)

	# Restore previous selection if still available
	if current_id >= 0:
		var idx = _provider_option_button.get_item_index(current_id)
		if idx >= 0:
			_provider_option_button.select(idx)


## Creates a provider instance for the given model key, applying config for dynamic models
func _get_provider_instance(key: int) -> BaseProvider:
	if key >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		var instance = SingletonObject.create_dynamic_provider(key)
		if instance:
			return instance
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key].new()


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
	_loading_values = true
	if SingletonObject.ChatList.size() > 0:
		var current_tab: int = SingletonObject.Chats.current_tab
		current_chat_tab_ref = SingletonObject.ChatList[current_tab]
		if current_chat_tab_ref.HasUsedSystemPrompt:
			var chat_item = SingletonObject.Chats.get_first_chat_item()
			%SystemPromptTextEdit.text = chat_item.Message
		else:
			%SystemPromptTextEdit.text = ""

		# Load system prompt enabled state
		%SystemPromptEnabledCheckButton.button_pressed = current_chat_tab_ref.SystemPromptEnabled

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

		# Load agentic system prompt - show effective prompt (custom or default)
		if current_chat_tab_ref.AgenticSystemPrompt.is_empty():
			%AgenticSystemPromptTextEdit.text = SingletonObject.Chats._build_agent_system_prompt()
		else:
			%AgenticSystemPromptTextEdit.text = current_chat_tab_ref.AgenticSystemPrompt
		%AgenticSystemPromptEnabledCheckButton.button_pressed = current_chat_tab_ref.AgenticSystemPromptEnabled

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
	_loading_values = false


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

	# Nano Banana Pro settings
	var is_nbp: bool = provider.get("is_nano_banana_pro") == true
	_update_nbp_settings_visibility(is_nbp)

	# Model-chat settings (context window)
	var is_model_chat: bool = provider.get("supports_num_ctx") == true
	_update_model_chat_settings_visibility(is_model_chat, provider)

	# Timeout settings - always visible for all providers
	_update_timeout_settings_visibility(provider)


## Create or update Nano Banana Pro settings UI
func _update_nbp_settings_visibility(should_show: bool) -> void:
	if not should_show:
		if _nbp_settings_container:
			_nbp_settings_container.visible = false
		return

	# Create NBP settings if they don't exist
	if _nbp_settings_container == null:
		_create_nbp_settings()

	_nbp_settings_container.visible = true

	# Update values from singleton
	var search_btn = _nbp_settings_container.get_node("GoogleSearchHBox/GoogleSearchCheckButton") as CheckButton
	var aspect_btn = _nbp_settings_container.get_node("AspectRatioHBox/AspectRatioOptionButton") as OptionButton
	var size_btn = _nbp_settings_container.get_node("ImageSizeHBox/ImageSizeOptionButton") as OptionButton

	if search_btn:
		search_btn.button_pressed = SingletonObject.nbp_google_search_enabled
	if aspect_btn:
		_select_option_by_text(aspect_btn, SingletonObject.nbp_aspect_ratio)
	if size_btn:
		_select_option_by_text(size_btn, SingletonObject.nbp_image_size)


func _select_option_by_text(btn: OptionButton, text: String) -> void:
	for i in btn.get_item_count():
		if btn.get_item_text(i) == text:
			btn.select(i)
			return


## Create the Nano Banana Pro settings UI dynamically
func _create_nbp_settings() -> void:
	_nbp_settings_container = VBoxContainer.new()
	_nbp_settings_container.name = "NBPSettingsContainer"

	# Add separator
	var sep = HSeparator.new()
	_nbp_settings_container.add_child(sep)

	# Add header label
	var header = Label.new()
	header.text = "Nano Banana Pro Settings:"
	header.add_theme_font_size_override("font_size", 14)
	_nbp_settings_container.add_child(header)

	# Google Search grounding toggle
	var search_hbox = HBoxContainer.new()
	search_hbox.name = "GoogleSearchHBox"
	var search_label = Label.new()
	search_label.text = "Google Search Grounding:"
	search_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_label.tooltip_text = "Ground image generation in real-time web data (current events, weather, etc.)"
	search_hbox.add_child(search_label)
	var search_btn = CheckButton.new()
	search_btn.name = "GoogleSearchCheckButton"
	search_btn.button_pressed = SingletonObject.nbp_google_search_enabled
	search_btn.toggled.connect(_on_nbp_google_search_toggled)
	search_hbox.add_child(search_btn)
	_nbp_settings_container.add_child(search_hbox)

	# Aspect Ratio
	var aspect_hbox = HBoxContainer.new()
	aspect_hbox.name = "AspectRatioHBox"
	var aspect_label = Label.new()
	aspect_label.text = "Aspect Ratio:"
	aspect_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	aspect_hbox.add_child(aspect_label)
	var aspect_btn = OptionButton.new()
	aspect_btn.name = "AspectRatioOptionButton"
	for ratio in ["1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"]:
		aspect_btn.add_item(ratio)
	_select_option_by_text(aspect_btn, SingletonObject.nbp_aspect_ratio)
	aspect_btn.item_selected.connect(_on_nbp_aspect_ratio_selected)
	aspect_hbox.add_child(aspect_btn)
	_nbp_settings_container.add_child(aspect_hbox)

	# Image Size
	var size_hbox = HBoxContainer.new()
	size_hbox.name = "ImageSizeHBox"
	var size_label = Label.new()
	size_label.text = "Image Size:"
	size_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_hbox.add_child(size_label)
	var size_btn = OptionButton.new()
	size_btn.name = "ImageSizeOptionButton"
	for sz in ["1K", "2K", "4K"]:
		size_btn.add_item(sz)
	_select_option_by_text(size_btn, SingletonObject.nbp_image_size)
	size_btn.item_selected.connect(_on_nbp_image_size_selected)
	size_hbox.add_child(size_btn)
	_nbp_settings_container.add_child(size_hbox)

	# Add to the Model tab after the parameter sliders (before System Prompt separator)
	var model_vbox = %PresenceHBoxContainer.get_parent()
	var insert_idx = %PresenceHBoxContainer.get_index() + 1
	model_vbox.add_child(_nbp_settings_container)
	model_vbox.move_child(_nbp_settings_container, insert_idx)


func _on_nbp_google_search_toggled(enabled: bool) -> void:
	SingletonObject.nbp_google_search_enabled = enabled
	print("NBP Google Search Grounding: %s" % enabled)


func _on_nbp_aspect_ratio_selected(index: int) -> void:
	var btn = _nbp_settings_container.get_node("AspectRatioHBox/AspectRatioOptionButton") as OptionButton
	SingletonObject.nbp_aspect_ratio = btn.get_item_text(index)
	print("NBP Aspect Ratio: %s" % SingletonObject.nbp_aspect_ratio)


func _on_nbp_image_size_selected(index: int) -> void:
	var btn = _nbp_settings_container.get_node("ImageSizeHBox/ImageSizeOptionButton") as OptionButton
	SingletonObject.nbp_image_size = btn.get_item_text(index)
	print("NBP Image Size: %s" % SingletonObject.nbp_image_size)


## Create or update Model-chat settings UI visibility
func _update_model_chat_settings_visibility(should_show: bool, provider: BaseProvider = null) -> void:
	if not should_show:
		if _model_chat_settings_container:
			_model_chat_settings_container.visible = false
		return

	# Create model-chat settings if they don't exist
	if _model_chat_settings_container == null:
		_create_model_chat_settings()

	_model_chat_settings_container.visible = true

	# Update context value from per-model setting or provider default
	var ctx_spin = _model_chat_settings_container.get_node("NumCtxHBox/NumCtxSpinBox") as SpinBox
	if ctx_spin and provider:
		var context = SingletonObject.get_model_context(provider.model_name)
		if context > 0:
			ctx_spin.value = context
		elif provider.default_context > 0:
			ctx_spin.value = provider.default_context
		else:
			ctx_spin.value = 40000  # Fallback default

	# Update num_gpu value from per-model setting or provider default
	var gpu_spin = _model_chat_settings_container.get_node("NumGpuHBox/NumGpuSpinBox") as SpinBox
	if gpu_spin and provider:
		var num_gpu = SingletonObject.get_model_num_gpu(provider.model_name)
		gpu_spin.value = num_gpu


## Create the Model-chat settings UI dynamically
func _create_model_chat_settings() -> void:
	_model_chat_settings_container = VBoxContainer.new()
	_model_chat_settings_container.name = "ModelChatSettingsContainer"

	# Add separator
	var sep = HSeparator.new()
	_model_chat_settings_container.add_child(sep)

	# Add header label
	var header = Label.new()
	header.text = "Model-Chat Settings:"
	header.add_theme_font_size_override("font_size", 14)
	_model_chat_settings_container.add_child(header)

	# Context window size
	var ctx_hbox = HBoxContainer.new()
	ctx_hbox.name = "NumCtxHBox"
	var ctx_label = Label.new()
	ctx_label.text = "Context Window (num_ctx):"
	ctx_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctx_label.tooltip_text = "Context window size in tokens. Higher = more memory but slower."
	ctx_hbox.add_child(ctx_label)
	var ctx_spin = SpinBox.new()
	ctx_spin.name = "NumCtxSpinBox"
	ctx_spin.min_value = 2048
	ctx_spin.max_value = 131072
	ctx_spin.step = 1024
	ctx_spin.value = SingletonObject.model_chat_num_ctx
	ctx_spin.value_changed.connect(_on_model_chat_num_ctx_changed)
	ctx_hbox.add_child(ctx_spin)
	_model_chat_settings_container.add_child(ctx_hbox)

	# GPU layers (num_gpu)
	var gpu_hbox = HBoxContainer.new()
	gpu_hbox.name = "NumGpuHBox"
	var gpu_label = Label.new()
	gpu_label.text = "GPU Layers (num_gpu):"
	gpu_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gpu_label.tooltip_text = "GPU layer offloading. 0=CPU only, 999=full GPU, -1=default"
	gpu_hbox.add_child(gpu_label)
	var gpu_spin = SpinBox.new()
	gpu_spin.name = "NumGpuSpinBox"
	gpu_spin.min_value = -1
	gpu_spin.max_value = 999
	gpu_spin.step = 1
	gpu_spin.value = -1
	gpu_spin.value_changed.connect(_on_num_gpu_changed)
	gpu_hbox.add_child(gpu_spin)
	_model_chat_settings_container.add_child(gpu_hbox)

	# Insert after NBP settings (or after PresenceHBoxContainer)
	var model_vbox = %PresenceHBoxContainer.get_parent()
	var insert_idx = %PresenceHBoxContainer.get_index() + 1
	if _nbp_settings_container:
		insert_idx = _nbp_settings_container.get_index() + 1
	model_vbox.add_child(_model_chat_settings_container)
	model_vbox.move_child(_model_chat_settings_container, insert_idx)


func _on_model_chat_num_ctx_changed(value: float) -> void:
	var provider: BaseProvider = null
	if current_chat_tab_ref and current_chat_tab_ref.provider:
		provider = current_chat_tab_ref.provider
	else:
		# No active chat - get provider from dropdown
		provider = SingletonObject.Chats._provider_option_button.get_selected_provider()

	if provider:
		SingletonObject.set_model_context(provider.model_name, int(value))
		print("Model context for '%s': %d" % [provider.model_name, int(value)])


func _on_num_gpu_changed(value: float) -> void:
	var provider: BaseProvider = null
	if current_chat_tab_ref and current_chat_tab_ref.provider:
		provider = current_chat_tab_ref.provider
	else:
		# No active chat - get provider from dropdown
		provider = SingletonObject.Chats._provider_option_button.get_selected_provider()

	if provider:
		SingletonObject.set_model_num_gpu(provider.model_name, int(value))
		print("Model num_gpu for '%s': %d" % [provider.model_name, int(value)])


## Update or create timeout settings UI visibility
func _update_timeout_settings_visibility(provider: BaseProvider) -> void:
	if _timeout_settings_container == null:
		_create_timeout_settings()

	_timeout_settings_container.visible = true

	# Update value from singleton or provider default (keyed by model_name)
	var spin = _timeout_settings_container.get_node("TimeoutHBox/TimeoutSpinBox") as SpinBox
	if spin:
		var timeout = SingletonObject.get_model_timeout(provider.model_name)
		if timeout > 0:
			spin.value = timeout
		else:
			spin.value = provider.default_timeout


## Create the timeout settings UI dynamically
func _create_timeout_settings() -> void:
	_timeout_settings_container = VBoxContainer.new()
	_timeout_settings_container.name = "TimeoutSettingsContainer"

	# Add separator
	var sep = HSeparator.new()
	_timeout_settings_container.add_child(sep)

	# Request timeout setting
	var timeout_hbox = HBoxContainer.new()
	timeout_hbox.name = "TimeoutHBox"
	var timeout_label = Label.new()
	timeout_label.text = "Request Timeout:"
	timeout_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeout_label.tooltip_text = "Maximum seconds to wait for AI response. Set per-provider."
	timeout_hbox.add_child(timeout_label)

	var timeout_spin = SpinBox.new()
	timeout_spin.name = "TimeoutSpinBox"
	timeout_spin.min_value = 10
	timeout_spin.max_value = 600
	timeout_spin.step = 10
	timeout_spin.suffix = "s"
	timeout_spin.value_changed.connect(_on_timeout_changed)
	timeout_hbox.add_child(timeout_spin)
	_timeout_settings_container.add_child(timeout_hbox)

	# Insert after model-chat settings (or NBP settings, or PresenceHBoxContainer)
	var model_vbox = %PresenceHBoxContainer.get_parent()
	var insert_idx = %PresenceHBoxContainer.get_index() + 1
	if _nbp_settings_container:
		insert_idx = _nbp_settings_container.get_index() + 1
	if _model_chat_settings_container:
		insert_idx = _model_chat_settings_container.get_index() + 1
	model_vbox.add_child(_timeout_settings_container)
	model_vbox.move_child(_timeout_settings_container, insert_idx)


func _on_timeout_changed(value: float) -> void:
	var provider: BaseProvider = null
	if current_chat_tab_ref and current_chat_tab_ref.provider:
		provider = current_chat_tab_ref.provider
	else:
		# No active chat - get provider from dropdown
		provider = SingletonObject.Chats._provider_option_button.get_selected_provider()

	if provider:
		SingletonObject.set_model_timeout(provider.model_name, value)
		print("Model timeout for '%s': %ds" % [provider.model_name, int(value)])


func _on_record_system_prompt_button_pressed() -> void:
	%SystemPromptTextEdit.text = ""
	SingletonObject.AtT.FieldForFilling = %SystemPromptTextEdit
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.btn = %RecordSystemPromptButton
	%RecordSystemPromptButton.modulate = Color(Color.LIME_GREEN)


func _on_system_prompt_enabled_check_button_toggled(toggled_on: bool) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.SystemPromptEnabled = toggled_on
		print("SystemPromptEnabled: " + str(current_chat_tab_ref.SystemPromptEnabled))
	else:
		print("no chats are open right now")


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
	if _loading_values:
		return
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
	if _loading_values:
		return  # Don't save when programmatically setting text
	if current_chat_tab_ref:
		current_chat_tab_ref.AgenticSystemPrompt = %AgenticSystemPromptTextEdit.text
		print("AgenticSystemPrompt updated")
	else:
		print("no chats are open right now")


func _on_agentic_system_prompt_enabled_check_button_toggled(toggled_on: bool) -> void:
	if current_chat_tab_ref:
		current_chat_tab_ref.AgenticSystemPromptEnabled = toggled_on
		print("AgenticSystemPromptEnabled: " + str(current_chat_tab_ref.AgenticSystemPromptEnabled))
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
