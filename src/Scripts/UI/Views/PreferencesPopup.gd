class_name PreferencesPopup
extends PersistentWindow


@onready var output_device_button: OptionButton = %OutputDeviceButton

# Core WebSocket Connection UI
@onready var connection_label: Label = %ConnectionLabel
@onready var connection_texture_rect: TextureRect = %ConnectionTextureRect
@onready var connect_button: Button = %CoreConnetButton
@onready var hcp_url: LineEdit = %leCoreUrl # WebSocket URL for Core

## Container with advanced core connection options
@onready var _core_connection_advanced: Control = %CoreConnectionAdvanced
@onready var _core_connection_advanced_separator: Separator = %CoreConnectionAdvancedSeparator

# Authentication UI
@onready var auth_preset_option_button: OptionButton = %AuthPresetOptionButton
@onready var auth_base_url: LineEdit = %leAuthBaseUrl # HTTP Base URL for Auth
@onready var hcp_username: LineEdit = %leUsername
@onready var hcp_password: LineEdit = %lePassword

@onready var service_selection_window: ServiceSelection = %ServiceSelection
@onready var logs_window: HcpLogs = %Logs

# maps API_PROVIDERs to their config file field name
const PROVIDERS = {
	SingletonObject.API_PROVIDER.OPENAI: "openai",
	SingletonObject.API_PROVIDER.ANTHROPIC: "anthropic",
	SingletonObject.API_PROVIDER.GOOGLE: "google_vertex",
	SingletonObject.API_PROVIDER.LOCAL: "sglang",
	SingletonObject.API_PROVIDER.OPENROUTER: "openrouter",
}

# --- Authentication Presets ---
const AUTH_PRESET_PROD = "https://www.turnrock.ai:4040/v1/login"
const AUTH_PRESET_LOCAL = "http://localhost:4040/v1/login"
const WS_PRESET_PROD = "wss://www.turnrock.ai:27500/connect"
const WS_PRESET_LOCAL = "ws://127.0.0.1:27500/connect"
const AUTH_PRESET_CUSTOM_IDX = 2 # Index of the "Custom" option in the OptionButton

@onready var _fields = {
	"first_name": %leFirstName,
	"last_name": %leLastName,

	"google_vertex": %leGoogleVertex,
	"anthropic": %leAnthropic,
	"openai": %leOpenAI,
	"openrouter": %leOpenRouter,

	"hcp_auto_connect": %leConnectAuto,
	"hcp_url": %leCoreUrl,             # Core WebSocket URL
	"hcp_auth_base_url": %leAuthBaseUrl, # Authentication HTTP Base URL
	"hcp_username": %leUsername,
	"hcp_password": %lePassword,
}

@onready var theme_option_button: OptionButton = %ThemeOptionButton
@onready var microphones: OptionButton = %Microphones

# Provider checkbuttons mapped to API_PROVIDER enum values
@onready var _provider_checkbuttons: Dictionary = {
	SingletonObject.API_PROVIDER.GOOGLE: %GoogleCheckButton,
	SingletonObject.API_PROVIDER.OPENAI: %OpenAICheckButton,
	SingletonObject.API_PROVIDER.ANTHROPIC: %AnthropicCheckButton,
	SingletonObject.API_PROVIDER.LOCAL: %LocalCheckButton,
	SingletonObject.API_PROVIDER.TURNROCK: %TurnRockCheckButton,
	SingletonObject.API_PROVIDER.OPENROUTER: %OpenRouterCheckButton,
	SingletonObject.API_PROVIDER.CLAUDE_CODE: %ClaudeCodeCheckButton,
	SingletonObject.API_PROVIDER.CHATGPT: %ChatGPTCheckButton,
}

var config_file = ConfigFile.new()


func _ready():
	super()
	var res_code = config_file.load_encrypted_pass("user://Preferences.agent", OS.get_unique_id())
	match res_code:
		ERR_FILE_NOT_FOUND:
			# popular config file with default settings
			config_file.set_value("API KEYS", "google_vertex", "")
			config_file.set_value("API KEYS", "anthropic", "")
			config_file.set_value("API KEYS", "openai", "")
			config_file.set_value("API KEYS", "openrouter", "")

			config_file.set_value("USER", "first_name", "Not")
			config_file.set_value("USER", "last_name", "Available")

			# Default HCP settings (including new auth base URL)
			config_file.set_value("HCP", "url", WS_PRESET_PROD) # Default Core WS URL
			config_file.set_value("HCP", "auth_base_url", AUTH_PRESET_PROD) # Default Auth Base URL
			config_file.set_value("HCP", "username", "")
			config_file.set_value("HCP", "password", "")
			config_file.set_value("HCP", "auto_connect", true)
			config_file.set_value("HCP", "auto_connect", true)

			config_file.set_value("HCP", "selected_services", [])

	set_field_values()

	SingletonObject.theme_changed.connect(set_theme_option_menu)
	theme_option_button.selected = SingletonObject.get_theme_enum()

	SingletonObject.mic_changed.connect(set_microphone_option_menu)
	# Defer to next frame to avoid AudioServer race condition crash
	call_deferred("set_microphone_option_menu", SingletonObject.get_microphone())

	# Create custom models tab (after scene tree is ready)
	call_deferred("_create_custom_models_tab")

	# Create tools tab (after scene tree is ready)
	call_deferred("_create_tools_tab")

	# Initialize ChatGPT auth status
	call_deferred("_init_chatgpt_auth")

	if SingletonObject.config_has_saved_section("Experimental"):
		var enable_exp: bool = SingletonObject.config_file.get_value("Experimental", "enabled")
		_on_experimental_check_button_toggled(enable_exp)
		%ExperimentalCheckButton.button_pressed = enable_exp

	# Load verbose logging setting
	if SingletonObject.config_has_saved_section("Logging"):
		var enable_verbose: bool = SingletonObject.config_file.get_value("Logging", "verbose", false)
		%VerboseLoggingCheckButton.button_pressed = enable_verbose

	# Defer to next frame to avoid AudioServer race condition crash
	call_deferred("populate_output_devices_button")

	# core tab stuff - these signals relate to the WebSocket connection status
	Core.client.connection_established.connect(
		func():
			connection_label.text = "You are connected to core"
			connection_texture_rect.texture = preload("res://.godot/imported/check_mark16.webp-ee4b5638509d469382c7cad2d0cf364b.ctex")
			connect_button.text = "Disconnect"
			connect_button.tooltip_text = "Disconnect from the Core"
	)

	Core.client.connection_error.connect(
		func(error: int):
			connection_label.text = "Core WS Error (%s)" % error_string(error)
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.text = "Connect"
			connect_button.tooltip_text = "Connect to the Core"
	)

	Core.client.connection_closed.connect(
		func():
			connection_label.text = "You are not connected to core"
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.text = "Connect"
			connect_button.tooltip_text = "Connect to the Core"
	)

	Core.http_connection_changed.connect(
		func(_active: bool):
			if not Core.connected:
				connection_label.text = "You are not connected to core"
				connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			
			connect_button.text = "Disconnect" if Core.connected else "Connect"
			connect_button.tooltip_text = "Disconnect from the Core" if Core.connected else "Connect to the Core"
	)

	# if auto connect is checked act like the connect button was pressed
	if _fields["hcp_auto_connect"].button_pressed:
		_on_core_connet_button_pressed.call_deferred(false) # dont display error


func set_field_values():
	_fields["first_name"].text = config_file.get_value("USER", "first_name", "Not")
	_fields["last_name"].text = config_file.get_value("USER", "last_name", "Available")

	_fields["google_vertex"].text = config_file.get_value("API KEYS", "google_vertex", "")
	_fields["anthropic"].text = config_file.get_value("API KEYS", "anthropic", "")
	_fields["openai"].text = config_file.get_value("API KEYS", "openai", "")
	_fields["openrouter"].text = config_file.get_value("API KEYS", "openrouter", "")

	_fields["hcp_url"].text = config_file.get_value("HCP", "url", WS_PRESET_PROD) # Core WS URL
	_fields["hcp_auto_connect"].button_pressed = config_file.get_value("HCP", "auto_connect", true)
	_fields["hcp_username"].text = config_file.get_value("HCP", "username", "")
	_fields["hcp_password"].text = config_file.get_value("HCP", "password", "")

	var selected_services_data = config_file.get_value("HCP", "selected_services", [])
	
	service_selection_window.load_saved_selected_services(selected_services_data)
	
	# --- Set Auth Base URL and Preset Dropdown ---
	var saved_auth_url = config_file.get_value("HCP", "auth_base_url", AUTH_PRESET_PROD)
	_fields["hcp_auth_base_url"].text = saved_auth_url

	# Update the dropdown based on the loaded URL
	if saved_auth_url == AUTH_PRESET_PROD:
		auth_preset_option_button.select(0)
		_set_connection_options_visibility(false)
	elif saved_auth_url == AUTH_PRESET_LOCAL:
		auth_preset_option_button.select(1)
		_set_connection_options_visibility(false)
	else:
		auth_preset_option_button.select(AUTH_PRESET_CUSTOM_IDX) # Select "Custom"

# NEW function to handle preset selection
func _on_auth_preset_option_button_item_selected(index: int) -> void:
	match index:
		0: # Production
			auth_base_url.text = AUTH_PRESET_PROD
			hcp_url.text = WS_PRESET_PROD
			_set_connection_options_visibility(false)
		1: # Localhost
			auth_base_url.text = AUTH_PRESET_LOCAL
			hcp_url.text = WS_PRESET_LOCAL
			_set_connection_options_visibility(false)
		2: # Custom
			_set_connection_options_visibility(true)

func _set_connection_options_visibility(on: bool):
	auth_base_url.get_parent().visible = on
	_core_connection_advanced.visible = on
	_core_connection_advanced_separator.visible = on

func _on_btn_save_prefs_pressed():
	config_file.set_value("USER", "first_name", _fields["first_name"].text)
	config_file.set_value("USER", "last_name", _fields["last_name"].text)

	config_file.set_value("API KEYS", "google_vertex", _fields["google_vertex"].text)
	config_file.set_value("API KEYS", "anthropic", _fields["anthropic"].text)
	config_file.set_value("API KEYS", "openai", _fields["openai"].text)
	config_file.set_value("API KEYS", "openrouter", _fields["openrouter"].text)

	config_file.set_value("HCP", "url", _fields["hcp_url"].text) # Core WS URL
	# --- Save the actual text from the Auth Base URL LineEdit ---
	config_file.set_value("HCP", "auth_base_url", _fields["hcp_auth_base_url"].text)
	config_file.set_value("HCP", "username", _fields["hcp_username"].text)
	config_file.set_value("HCP", "password", _fields["hcp_password"].text)
	config_file.set_value("HCP", "auto_connect", _fields["hcp_auto_connect"].button_pressed)
	config_file.set_value("HCP", "selected_services", service_selection_window.get_selected_service_data())

	config_file.save_encrypted_pass("user://Preferences.agent", OS.get_unique_id())

	hide()

func _on_about_to_popup():
	set_field_values()
	theme_option_button.selected = SingletonObject.get_theme_enum()
	set_microphone_option_menu(SingletonObject.get_microphone())
	populate_output_devices_button()
	_sync_provider_checkboxes()
	_populate_openrouter_models()
	_populate_custom_models()


## Sync provider checkbox states with SingletonObject enabled state
func _sync_provider_checkboxes() -> void:
	for provider in _provider_checkbuttons:
		var checkbox: CheckButton = _provider_checkbuttons[provider]
		if checkbox:
			checkbox.set_pressed_no_signal(SingletonObject.is_provider_enabled(provider))

func get_api_key(provider: SingletonObject.API_PROVIDER) -> String:
	if provider == SingletonObject.API_PROVIDER.LOCAL:
		return " "
	elif provider == SingletonObject.API_PROVIDER.CHATGPT:
		# ChatGPT uses OAuth, return the access token
		var chatgpt_auth := SingletonObject.ChatGPTProviderScript.get_auth()
		if chatgpt_auth.is_authenticated():
			return chatgpt_auth.access_token
		return ""
	else:
		return config_file.get_value("API KEYS", PROVIDERS[provider], "")

func get_user_full_name() -> String:
	return "%s %s" % [config_file.get_value("USER", "first_name", ""), config_file.get_value("USER", "last_name", "")]

func get_user_initials() -> String:
	var n1 = config_file.get_value("USER", "first_name")
	if n1: n1 = n1[0]
	else: n1 = "N"

	var n2 = config_file.get_value("USER", "last_name")
	if n2: n2 = n2[0]
	else: n2 = "A"

	return ("%s%s" % [n1, n2]).to_upper()


func _on_open_ai_check_box_toggled(toggled_on: bool) -> void:
	%leOpenAI.secret = !toggled_on


func _on_anthropic_check_box_toggled(toggled_on: bool) -> void:
	%leAnthropic.secret = !toggled_on


func _on_google_vertex_check_box_toggled(toggled_on: bool) -> void:
	%leGoogleVertex.secret = !toggled_on


func _on_open_router_check_box_toggled(toggled_on: bool) -> void:
	%leOpenRouter.secret = !toggled_on

#region Theme preference

func set_theme_option_menu(theme_enum: int):
	theme_option_button.selected = theme_enum


func _on_theme_option_button_item_selected(index: int) -> void:
	SingletonObject.set_theme(index)

#endregion Theme preference

#region Mic preferences

func set_microphone_option_menu(mic_to_set):
	# Get the list of available microphones
	var input_devices = AudioServer.get_input_device_list()

	# Clear any existing options in the OptionButton
	microphones.clear()

	# Add each microphone to the OptionButton
	var index = 0
	for device in input_devices:
		microphones.add_item(device)
		if mic_to_set == device:
			microphones.selected = index
		index += 1


func _on_microphones_item_selected(index: int) -> void:
	SingletonObject.set_microphone(microphones.get_item_text(index))

#endregion Mic preferences


func _on_experimental_check_button_toggled(toggled_on: bool) -> void:
	# Save experimental features setting to config
	SingletonObject.save_to_config_file("Experimental", "enabled", toggled_on)
	$"../VBoxRoot/HBoxContainer/menuMain/View".set_item_disabled(3, !toggled_on)
	$"../VBoxRoot/VSplitContainer/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/HBoxContainer/AddGraphicsEditor".visible = toggled_on
	SingletonObject.toggle_experimental.emit(toggled_on)


func _on_verbose_logging_check_button_toggled(toggled_on: bool) -> void:
	SingletonObject.set_verbose_logging(toggled_on)


func populate_output_devices_button() -> void:
	output_device_button.clear()
	for item in AudioServer.get_output_device_list():
		output_device_button.add_item(item)

	var device = SingletonObject.get_output_device()
	for i in output_device_button.get_item_count():
		if device == output_device_button.get_item_text(i):
			output_device_button.select(i)
			break


func _on_output_device_button_item_selected(index: int) -> void:
	var device: = output_device_button.get_item_text(index)
	SingletonObject.output_device_changed.emit(device)


# MODIFIED: Now handles both authentication and WebSocket connection
func _on_core_connet_button_pressed(display_error: = true) -> void:
	if Core.connected:
		Core.close_connection()
		return

	var core_ws_url = hcp_url.text
	var auth_http_base_url = auth_base_url.text
	var uname = hcp_username.text
	var pword = hcp_password.text

	if auth_http_base_url.is_empty() or core_ws_url.is_empty() or uname.is_empty() or pword.is_empty():
		SingletonObject.ErrorDisplay("Missing Information", "Please fill in Auth Base URI, Core URL, Username, and Password.", self)
		return

	# Update status immediately - maybe "Connecting..."
	connection_label.text = "Authenticating..."
	connection_texture_rect.texture = null # Or a spinner icon

	# Call Core.start with the new parameters
	# NOTE: Core.start signature needs to be updated to accept these
	var connected: bool = await Core.start(
		core_ws_url,        # Core WebSocket URL
		auth_http_base_url, # Auth HTTP Base URL
		uname,
		pword,
		display_error,
	)

	if not connected:
		# If Core.start returns false, it means authentication or WS connection failed.
		# The Core.start function should ideally push a more specific error message.
		connection_label.text = "Failed to connect/authenticate"
		connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
		
		logs_window.add_log_line(
			"Authentication or WebSocket connection failed. Check URLs and credentials",
			HcpLogs.LOG_TYPE.ERROR
		)


func _on_service_selection_visibility_changed() -> void:
	if not service_selection_window.is_visible_in_tree(): return

	if Core.connecting: return

	var services: Array[Service] = await Core.fetch_services(true)
	service_selection_window.set_services(services) # will clear the warning by default
	
	if services.is_empty() and not Core.client._connected:
		service_selection_window.set_warning("Cannot fetch services. Please connect to Core first.")
		return


func _on_service_selection_service_selected(service: Service) -> void:
	Core.service_selected.emit(service)

func _on_service_selection_service_deselected(service: Service) -> void:
	Core.service_deselected.emit(service)

func _on_password_checkbox_toggled(toggled_on:bool) -> void:
	hcp_password.secret = not toggled_on


func _on_hcp_logs_button_pressed() -> void:
	logs_window.popup_centered()


#region OpenRouter Models Tab

@onready var _or_model_list_container: VBoxContainer = %ORModelListContainer

func _populate_openrouter_models() -> void:
	# Clear existing rows
	for child in _or_model_list_container.get_children():
		child.queue_free()

	var manager = SingletonObject.openrouter_model_manager
	if not manager:
		return

	for config in manager.models:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var name_label := Label.new()
		name_label.text = config.get("display_name", "")
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.size_flags_stretch_ratio = 1.5
		row.add_child(name_label)

		var id_label := Label.new()
		id_label.text = config.get("api_model_id", "")
		id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		id_label.modulate.a = 0.6
		row.add_child(id_label)

		var cost_label := Label.new()
		cost_label.text = "$%.2f/$%.2f" % [config.get("input_token_cost", 0.0), config.get("output_token_cost", 0.0)]
		cost_label.custom_minimum_size.x = 80
		row.add_child(cost_label)

		var edit_btn := Button.new()
		edit_btn.text = "Edit"
		var model_id: int = config.get("id", 0)
		edit_btn.pressed.connect(_on_or_edit_model.bind(model_id))
		row.add_child(edit_btn)

		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.pressed.connect(_on_or_delete_model.bind(model_id))
		row.add_child(del_btn)

		_or_model_list_container.add_child(row)

	if manager.models.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No OpenRouter models configured."
		empty_label.modulate.a = 0.5
		_or_model_list_container.add_child(empty_label)


func _on_or_edit_model(model_id: int) -> void:
	var config: Dictionary = SingletonObject.openrouter_model_manager.get_model(model_id)
	if not config.is_empty():
		_show_or_model_dialog(config)


func _on_or_delete_model(model_id: int) -> void:
	var config: Dictionary = SingletonObject.openrouter_model_manager.get_model(model_id)
	if config.is_empty():
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete Model"
	dialog.dialog_text = "Remove \"%s\" from OpenRouter models?" % config.get("display_name", "")
	dialog.content_scale_factor = get_tree().root.content_scale_factor
	dialog.confirmed.connect(func():
		SingletonObject.openrouter_model_manager.remove_model(model_id)
		_populate_openrouter_models()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.confirmed.connect(func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


## Show add/edit dialog for an OpenRouter model.
## Pass empty dict for add mode, or existing config for edit mode.
func _show_or_model_dialog(existing_config: Dictionary = {}) -> void:
	var is_edit := not existing_config.is_empty()
	var win := Window.new()
	win.title = "Edit OpenRouter Model" if is_edit else "Add OpenRouter Model"
	var scale: float = get_tree().root.content_scale_factor
	win.content_scale_factor = scale
	win.size = Vector2i(Vector2(420, 380) * scale)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.anchors_preset = Control.PRESET_FULL_RECT
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Model ID
	var id_label := Label.new()
	id_label.text = "Model ID (e.g. openai/gpt-4o)"
	vbox.add_child(id_label)
	var id_edit := LineEdit.new()
	id_edit.text = existing_config.get("api_model_id", "")
	id_edit.placeholder_text = "provider/model-name"
	vbox.add_child(id_edit)

	# Display Name
	var dn_label := Label.new()
	dn_label.text = "Display Name"
	vbox.add_child(dn_label)
	var dn_edit := LineEdit.new()
	dn_edit.text = existing_config.get("display_name", "")
	vbox.add_child(dn_edit)

	# Short Name
	var sn_label := Label.new()
	sn_label.text = "Short Name (3-4 chars)"
	vbox.add_child(sn_label)
	var sn_edit := LineEdit.new()
	sn_edit.text = existing_config.get("short_name", "")
	sn_edit.max_length = 5
	vbox.add_child(sn_edit)

	# Costs
	var cost_hbox := HBoxContainer.new()
	cost_hbox.add_theme_constant_override("separation", 8)
	var in_label := Label.new()
	in_label.text = "In $/M:"
	cost_hbox.add_child(in_label)
	var in_spin := SpinBox.new()
	in_spin.min_value = 0.0
	in_spin.max_value = 1000.0
	in_spin.step = 0.01
	in_spin.value = existing_config.get("input_token_cost", 0.0)
	in_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost_hbox.add_child(in_spin)
	var out_label := Label.new()
	out_label.text = "Out $/M:"
	cost_hbox.add_child(out_label)
	var out_spin := SpinBox.new()
	out_spin.min_value = 0.0
	out_spin.max_value = 1000.0
	out_spin.step = 0.01
	out_spin.value = existing_config.get("output_token_cost", 0.0)
	out_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost_hbox.add_child(out_spin)
	vbox.add_child(cost_hbox)

	# Reasoning model checkbox
	var reasoning_check := CheckButton.new()
	reasoning_check.text = "Reasoning model"
	reasoning_check.button_pressed = existing_config.get("is_reasoning_model", false)
	vbox.add_child(reasoning_check)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	# Buttons
	var sep := HSeparator.new()
	vbox.add_child(sep)
	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)
	btn_hbox.alignment = BoxContainer.ALIGNMENT_END
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): win.queue_free())
	btn_hbox.add_child(cancel_btn)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(func():
		var api_model_id := id_edit.text.strip_edges()
		if api_model_id.is_empty():
			return
		var new_config := {
			"api_model_id": api_model_id,
			"display_name": dn_edit.text.strip_edges() if not dn_edit.text.strip_edges().is_empty() else api_model_id,
			"short_name": sn_edit.text.strip_edges() if not sn_edit.text.strip_edges().is_empty() else "OR",
			"input_token_cost": in_spin.value,
			"output_token_cost": out_spin.value,
			"is_reasoning_model": reasoning_check.button_pressed,
		}
		if is_edit:
			SingletonObject.openrouter_model_manager.update_model(existing_config["id"], new_config)
		else:
			SingletonObject.openrouter_model_manager.add_model(new_config)
		_populate_openrouter_models()
		win.queue_free()
	)
	btn_hbox.add_child(save_btn)
	vbox.add_child(btn_hbox)

	add_child(win)
	win.popup_centered()


func _on_or_browse_api_pressed() -> void:
	var api_key := get_api_key(SingletonObject.API_PROVIDER.OPENROUTER)
	if api_key.strip_edges().is_empty():
		SingletonObject.ErrorDisplay("No API Key", "Please set your OpenRouter API key in the API Keys tab first.", self)
		return

	_show_or_browse_dialog(api_key)


func _show_or_browse_dialog(api_key: String) -> void:
	var win := Window.new()
	win.title = "Browse OpenRouter Models"
	var scale: float = get_tree().root.content_scale_factor
	win.content_scale_factor = scale
	win.size = Vector2i(Vector2(620, 520) * scale)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.anchors_preset = Control.PRESET_FULL_RECT
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Search bar
	var search_hbox := HBoxContainer.new()
	var search_edit := LineEdit.new()
	search_edit.placeholder_text = "Search models..."
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_hbox.add_child(search_edit)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	search_hbox.add_child(refresh_btn)
	vbox.add_child(search_hbox)

	# Model list
	var item_list := ItemList.new()
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_list.allow_reselect = true
	vbox.add_child(item_list)

	# Details label
	var details_label := Label.new()
	details_label.text = "Select a model to see details."
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_label.custom_minimum_size.y = 40
	vbox.add_child(details_label)

	# Status label for loading
	var status_label := Label.new()
	status_label.text = "Loading models..."
	status_label.modulate.a = 0.6
	vbox.add_child(status_label)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_END
	btn_hbox.add_theme_constant_override("separation", 8)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): win.queue_free())
	btn_hbox.add_child(cancel_btn)
	var add_btn := Button.new()
	add_btn.text = "Add Selected"
	add_btn.disabled = true
	btn_hbox.add_child(add_btn)
	vbox.add_child(btn_hbox)

	add_child(win)
	win.popup_centered()

	# Store fetched models for selection
	var all_models: Array = []

	# Filter function
	var _filter_list := func(search_text: String):
		item_list.clear()
		var query := search_text.strip_edges().to_lower()
		for i in range(all_models.size()):
			var m: Dictionary = all_models[i]
			var name_: String = m.get("display_name", "")
			var id_: String = m.get("api_model_id", "")
			if query.is_empty() or query in name_.to_lower() or query in id_.to_lower():
				var cost_str := "$%.2f/$%.2f" % [m.get("input_token_cost", 0.0), m.get("output_token_cost", 0.0)]
				item_list.add_item("%s — %s" % [name_, cost_str])
				item_list.set_item_metadata(item_list.get_item_count() - 1, i)

	# Selection handler
	item_list.item_selected.connect(func(idx: int):
		var model_idx: int = item_list.get_item_metadata(idx)
		var m: Dictionary = all_models[model_idx]
		details_label.text = "%s\nID: %s\nCost: $%.2f in / $%.2f out per M tokens" % [
			m.get("display_name", ""),
			m.get("api_model_id", ""),
			m.get("input_token_cost", 0.0),
			m.get("output_token_cost", 0.0),
		]
		if m.get("context_length", 0) > 0:
			details_label.text += "\nContext: %dk" % (m["context_length"] / 1000)
		add_btn.disabled = false
	)

	# Add button handler
	add_btn.pressed.connect(func():
		var selected := item_list.get_selected_items()
		if selected.is_empty():
			return
		var model_idx: int = item_list.get_item_metadata(selected[0])
		var m: Dictionary = all_models[model_idx].duplicate()
		m.erase("context_length")
		# Check if already added
		var existing: Dictionary = SingletonObject.openrouter_model_manager.get_model_by_api_id(m.get("api_model_id", ""))
		if not existing.is_empty():
			SingletonObject.ErrorDisplay("Already Added", "Model \"%s\" is already in your list." % m.get("display_name", ""), self)
			return
		SingletonObject.openrouter_model_manager.add_model(m)
		_populate_openrouter_models()
		win.queue_free()
	)

	# Search filter
	search_edit.text_changed.connect(func(text: String): _filter_list.call(text))

	# Fetch models
	var _do_fetch := func():
		status_label.text = "Loading models..."
		add_btn.disabled = true
		var fetched = await SingletonObject.openrouter_model_manager.fetch_api_models(api_key)
		all_models.clear()
		all_models.append_array(fetched)
		if all_models.is_empty():
			status_label.text = "No models found or API error."
		else:
			status_label.text = "%d models available" % all_models.size()
			_filter_list.call(search_edit.text)

	refresh_btn.pressed.connect(func(): _do_fetch.call())
	_do_fetch.call()

#endregion OpenRouter Models Tab


#region Provider toggles

func _on_google_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.GOOGLE, toggled_on)


func _on_openai_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.OPENAI, toggled_on)


func _on_anthropic_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.ANTHROPIC, toggled_on)


func _on_local_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.LOCAL, toggled_on)


func _on_turnrock_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.TURNROCK, toggled_on)


func _on_openrouter_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.OPENROUTER, toggled_on)


func _on_claudecode_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.CLAUDE_CODE, toggled_on)


func _on_chatgpt_provider_toggled(toggled_on: bool) -> void:
	SingletonObject.set_provider_enabled(SingletonObject.API_PROVIDER.CHATGPT, toggled_on)


func _on_chatgpt_connect_pressed() -> void:
	var chatgpt_auth := SingletonObject.ChatGPTProviderScript.get_auth()
	if chatgpt_auth.is_authenticated():
		# Disconnect
		chatgpt_auth.disconnect_account()
		_update_chatgpt_status()
	else:
		# Start OAuth flow
		%ChatGPTConnectButton.disabled = true
		%ChatGPTConnectButton.text = "Connecting..."
		%ChatGPTStatusLabel.text = "Waiting for browser login..."

		chatgpt_auth.auth_completed.connect(_on_chatgpt_auth_completed, CONNECT_ONE_SHOT)
		chatgpt_auth.start_auth_flow(get_tree())


func _on_chatgpt_auth_completed(success: bool, error_message: String) -> void:
	%ChatGPTConnectButton.disabled = false
	if success:
		_update_chatgpt_status()
	else:
		%ChatGPTStatusLabel.text = "Error: %s" % error_message
		%ChatGPTConnectButton.text = "Connect ChatGPT"


func _update_chatgpt_status() -> void:
	var chatgpt_auth := SingletonObject.ChatGPTProviderScript.get_auth()
	if chatgpt_auth.is_authenticated():
		%ChatGPTStatusLabel.text = chatgpt_auth.get_status_text()
		%ChatGPTConnectButton.text = "Disconnect"
	else:
		%ChatGPTStatusLabel.text = "Not connected"
		%ChatGPTConnectButton.text = "Connect ChatGPT"


func _init_chatgpt_auth() -> void:
	var chatgpt_auth := SingletonObject.ChatGPTProviderScript.get_auth()
	chatgpt_auth.load_tokens()
	_update_chatgpt_status()

#endregion Provider toggles


#region Custom Models Tab

var _custom_models_list_container: VBoxContainer
var _custom_models_tab: VBoxContainer

## Build the Custom Models tab programmatically and add to the TabContainer
func _create_custom_models_tab() -> void:
	var tab_container = get_node("MarginContainer/VBoxContainer/TabContainer")
	if not tab_container:
		return

	_custom_models_tab = VBoxContainer.new()
	_custom_models_tab.name = "Models"

	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_custom_models_tab.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var desc := Label.new()
	desc.text = "Browse and add models from each provider. Built-in models are always available."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_custom_models_list_container = VBoxContainer.new()
	_custom_models_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_custom_models_list_container)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)

	var browse_anthropic_btn := Button.new()
	browse_anthropic_btn.text = "Anthropic"
	browse_anthropic_btn.tooltip_text = "Browse available Anthropic models"
	browse_anthropic_btn.pressed.connect(_on_browse_provider_pressed.bind("anthropic"))
	btn_hbox.add_child(browse_anthropic_btn)

	var browse_openai_btn := Button.new()
	browse_openai_btn.text = "OpenAI"
	browse_openai_btn.tooltip_text = "Browse available OpenAI models"
	browse_openai_btn.pressed.connect(_on_browse_provider_pressed.bind("openai"))
	btn_hbox.add_child(browse_openai_btn)

	var browse_google_btn := Button.new()
	browse_google_btn.text = "Google"
	browse_google_btn.tooltip_text = "Browse available Google AI models"
	browse_google_btn.pressed.connect(_on_browse_provider_pressed.bind("google"))
	btn_hbox.add_child(browse_google_btn)

	var refresh_btn := Button.new()
	refresh_btn.text = "Ollama"
	refresh_btn.tooltip_text = "Re-discover models from local Ollama server"
	refresh_btn.pressed.connect(_on_refresh_ollama_pressed)
	btn_hbox.add_child(refresh_btn)

	var add_btn := Button.new()
	add_btn.text = "Manual..."
	add_btn.tooltip_text = "Add a model by entering details manually"
	add_btn.pressed.connect(_on_custom_add_model_pressed)
	btn_hbox.add_child(add_btn)

	vbox.add_child(btn_hbox)

	tab_container.add_child(_custom_models_tab)


func _populate_custom_models() -> void:
	if not _custom_models_list_container:
		return

	for child in _custom_models_list_container.get_children():
		child.queue_free()

	# Collect models from all non-OpenRouter managers
	var sections: Array[Dictionary] = [
		{"label": "Anthropic", "manager": SingletonObject.anthropic_model_manager, "name_key": "model_name"},
		{"label": "OpenAI", "manager": SingletonObject.openai_model_manager, "name_key": "model_name"},
		{"label": "Google", "manager": SingletonObject.google_model_manager, "name_key": "model_name"},
		{"label": "Ollama (discovered)", "manager": SingletonObject.local_model_manager, "name_key": "model_name"},
	]

	var any_models := false
	for section in sections:
		var manager = section["manager"]
		if manager == null or manager.models.is_empty():
			continue

		any_models = true

		# Section header
		var header := Label.new()
		header.text = section["label"]
		header.add_theme_font_size_override("font_size", 14)
		_custom_models_list_container.add_child(header)

		for config in manager.models:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var name_label := Label.new()
			name_label.text = config.get("display_name", config.get("model_name", ""))
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_label.size_flags_stretch_ratio = 1.5
			row.add_child(name_label)

			var model_id_label := Label.new()
			model_id_label.text = config.get("model_name", config.get("api_model_id", ""))
			model_id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			model_id_label.modulate.a = 0.6
			row.add_child(model_id_label)

			var cost_label := Label.new()
			cost_label.text = "$%.2f/$%.2f" % [config.get("input_token_cost", 0.0), config.get("output_token_cost", 0.0)]
			cost_label.custom_minimum_size.x = 80
			row.add_child(cost_label)

			var model_id: int = config.get("id", 0)

			var edit_btn := Button.new()
			edit_btn.text = "Edit"
			edit_btn.pressed.connect(_on_custom_edit_model.bind(model_id, manager))
			row.add_child(edit_btn)

			var del_btn := Button.new()
			del_btn.text = "Delete"
			del_btn.pressed.connect(_on_custom_delete_model.bind(model_id, manager, config.get("display_name", "")))
			row.add_child(del_btn)

			_custom_models_list_container.add_child(row)

		# Add spacing between sections
		var spacer := HSeparator.new()
		spacer.modulate.a = 0.3
		_custom_models_list_container.add_child(spacer)

	if not any_models:
		var empty_label := Label.new()
		empty_label.text = "No custom models configured. Use the buttons below to browse or add models."
		empty_label.modulate.a = 0.5
		_custom_models_list_container.add_child(empty_label)


func _on_custom_add_model_pressed() -> void:
	_show_custom_model_dialog()


func _on_custom_edit_model(model_id: int, manager) -> void:
	var config: Dictionary = manager.get_model(model_id)
	if not config.is_empty():
		_show_custom_model_dialog(config, manager)


func _on_custom_delete_model(model_id: int, manager, display_name: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete Model"
	dialog.dialog_text = "Remove \"%s\"?" % display_name
	dialog.content_scale_factor = get_tree().root.content_scale_factor
	dialog.confirmed.connect(func():
		manager.remove_model(model_id)
		_populate_custom_models()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.confirmed.connect(func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


func _on_refresh_ollama_pressed() -> void:
	SingletonObject.discover_ollama_models()
	# Repopulate after a short delay to let async discovery complete
	get_tree().create_timer(2.0).timeout.connect(_populate_custom_models)


## Show add/edit dialog for a custom model.
func _show_custom_model_dialog(existing_config: Dictionary = {}, existing_manager = null) -> void:
	var is_edit := not existing_config.is_empty()
	var win := Window.new()
	win.title = "Edit Custom Model" if is_edit else "Add Custom Model"
	var scale: float = get_tree().root.content_scale_factor
	win.content_scale_factor = scale
	win.size = Vector2i(Vector2(420, 440) * scale)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.anchors_preset = Control.PRESET_FULL_RECT
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Provider selector (only for new models)
	var provider_option: OptionButton
	if not is_edit:
		var prov_label := Label.new()
		prov_label.text = "Provider"
		vbox.add_child(prov_label)
		provider_option = OptionButton.new()
		provider_option.add_item("Anthropic", 0)
		provider_option.add_item("OpenAI", 1)
		provider_option.add_item("Google", 2)
		provider_option.add_item("Ollama (Local)", 3)
		vbox.add_child(provider_option)

	# Model Name / API ID
	var id_label := Label.new()
	id_label.text = "Model Name / API ID"
	vbox.add_child(id_label)
	var id_edit := LineEdit.new()
	id_edit.text = existing_config.get("model_name", existing_config.get("api_model_id", ""))
	id_edit.placeholder_text = "e.g. claude-opus-4-6, gpt-5.3, gemini-4-pro"
	vbox.add_child(id_edit)

	# Display Name
	var dn_label := Label.new()
	dn_label.text = "Display Name"
	vbox.add_child(dn_label)
	var dn_edit := LineEdit.new()
	dn_edit.text = existing_config.get("display_name", "")
	vbox.add_child(dn_edit)

	# Short Name
	var sn_label := Label.new()
	sn_label.text = "Short Name (3-4 chars)"
	vbox.add_child(sn_label)
	var sn_edit := LineEdit.new()
	sn_edit.text = existing_config.get("short_name", "")
	sn_edit.max_length = 5
	vbox.add_child(sn_edit)

	# Costs
	var cost_hbox := HBoxContainer.new()
	cost_hbox.add_theme_constant_override("separation", 8)
	var in_label := Label.new()
	in_label.text = "In $/M:"
	cost_hbox.add_child(in_label)
	var in_spin := SpinBox.new()
	in_spin.min_value = 0.0
	in_spin.max_value = 1000.0
	in_spin.step = 0.01
	in_spin.value = existing_config.get("input_token_cost", 0.0)
	in_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost_hbox.add_child(in_spin)
	var out_label := Label.new()
	out_label.text = "Out $/M:"
	cost_hbox.add_child(out_label)
	var out_spin := SpinBox.new()
	out_spin.min_value = 0.0
	out_spin.max_value = 1000.0
	out_spin.step = 0.01
	out_spin.value = existing_config.get("output_token_cost", 0.0)
	out_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost_hbox.add_child(out_spin)
	vbox.add_child(cost_hbox)

	# Reasoning model checkbox
	var reasoning_check := CheckButton.new()
	reasoning_check.text = "Reasoning model"
	reasoning_check.button_pressed = existing_config.get("is_reasoning_model", false)
	vbox.add_child(reasoning_check)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	# Buttons
	var sep := HSeparator.new()
	vbox.add_child(sep)
	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)
	btn_hbox.alignment = BoxContainer.ALIGNMENT_END
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): win.queue_free())
	btn_hbox.add_child(cancel_btn)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(func():
		var model_name := id_edit.text.strip_edges()
		if model_name.is_empty():
			return

		var new_config := {
			"model_name": model_name,
			"display_name": dn_edit.text.strip_edges() if not dn_edit.text.strip_edges().is_empty() else model_name,
			"short_name": sn_edit.text.strip_edges() if not sn_edit.text.strip_edges().is_empty() else model_name.left(3).to_upper(),
			"input_token_cost": in_spin.value,
			"output_token_cost": out_spin.value,
			"is_reasoning_model": reasoning_check.button_pressed,
		}

		# For Anthropic, also set api_model_id (used by generate_content)
		if is_edit:
			if existing_config.has("api_model_id"):
				new_config["api_model_id"] = model_name
			existing_manager.update_model(existing_config["id"], new_config)
		else:
			var manager = _get_manager_for_provider_index(provider_option.get_selected_id())
			if provider_option.get_selected_id() == 0:  # Anthropic needs api_model_id
				new_config["api_model_id"] = model_name
			manager.add_model(new_config)

		_populate_custom_models()
		win.queue_free()
	)
	btn_hbox.add_child(save_btn)
	vbox.add_child(btn_hbox)

	add_child(win)
	win.popup_centered()


func _get_manager_for_provider_index(idx: int):
	match idx:
		0: return SingletonObject.anthropic_model_manager
		1: return SingletonObject.openai_model_manager
		2: return SingletonObject.google_model_manager
		3: return SingletonObject.local_model_manager
	return SingletonObject.anthropic_model_manager


func _on_browse_provider_pressed(provider_key: String) -> void:
	var api_key: String
	var manager
	var provider_label: String

	match provider_key:
		"anthropic":
			api_key = get_api_key(SingletonObject.API_PROVIDER.ANTHROPIC)
			manager = SingletonObject.anthropic_model_manager
			provider_label = "Anthropic"
		"openai":
			api_key = get_api_key(SingletonObject.API_PROVIDER.OPENAI)
			manager = SingletonObject.openai_model_manager
			provider_label = "OpenAI"
		"google":
			api_key = get_api_key(SingletonObject.API_PROVIDER.GOOGLE)
			manager = SingletonObject.google_model_manager
			provider_label = "Google"

	if api_key.strip_edges().is_empty():
		SingletonObject.ErrorDisplay("No API Key", "Please set your %s API key in the API Keys tab first." % provider_label, self)
		return

	_show_provider_browse_dialog(provider_key, provider_label, api_key, manager)


func _show_provider_browse_dialog(provider_key: String, provider_label: String, api_key: String, manager) -> void:
	var win := Window.new()
	win.title = "Browse %s Models" % provider_label
	var ui_scale: float = get_tree().root.content_scale_factor
	win.content_scale_factor = ui_scale
	win.size = Vector2i(Vector2(620, 520) * ui_scale)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.anchors_preset = Control.PRESET_FULL_RECT
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Search bar
	var search_hbox := HBoxContainer.new()
	var search_edit := LineEdit.new()
	search_edit.placeholder_text = "Search models..."
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_hbox.add_child(search_edit)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	search_hbox.add_child(refresh_btn)
	vbox.add_child(search_hbox)

	# Model list (multi-select)
	var item_list := ItemList.new()
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_list.select_mode = ItemList.SELECT_MULTI
	vbox.add_child(item_list)

	# Details label
	var details_label := Label.new()
	details_label.text = "Select one or more models to add."
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_label.custom_minimum_size.y = 40
	vbox.add_child(details_label)

	# Status label
	var status_label := Label.new()
	status_label.text = "Loading models..."
	status_label.modulate.a = 0.6
	vbox.add_child(status_label)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_END
	btn_hbox.add_theme_constant_override("separation", 8)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): win.queue_free())
	btn_hbox.add_child(cancel_btn)
	var add_btn := Button.new()
	add_btn.text = "Add Selected"
	add_btn.disabled = true
	btn_hbox.add_child(add_btn)
	vbox.add_child(btn_hbox)

	add_child(win)
	win.popup_centered()

	var all_models: Array = []

	# Filter function
	var _filter_list := func(search_text: String):
		item_list.clear()
		var query := search_text.strip_edges().to_lower()
		for i in range(all_models.size()):
			var m: Dictionary = all_models[i]
			var display: String = m.get("display_name", "")
			var model_id: String = m.get("model_name", "")
			if query.is_empty() or query in display.to_lower() or query in model_id.to_lower():
				item_list.add_item("%s  —  %s" % [display, model_id])
				item_list.set_item_metadata(item_list.get_item_count() - 1, i)

	# Selection handler — update details and enable add button
	item_list.multi_selected.connect(func(_idx: int, _selected: bool):
		var selected := item_list.get_selected_items()
		add_btn.disabled = selected.is_empty()
		if selected.size() == 1:
			var model_idx: int = item_list.get_item_metadata(selected[0])
			var m: Dictionary = all_models[model_idx]
			details_label.text = "%s\nID: %s" % [m.get("display_name", ""), m.get("model_name", "")]
		elif selected.size() > 1:
			details_label.text = "%d models selected" % selected.size()
		else:
			details_label.text = "Select one or more models to add."
	)

	# Add button — add all selected models
	add_btn.pressed.connect(func():
		var selected := item_list.get_selected_items()
		if selected.is_empty():
			return
		var added := 0
		var skipped := 0
		for sel_idx in selected:
			var model_idx: int = item_list.get_item_metadata(sel_idx)
			var m: Dictionary = all_models[model_idx].duplicate()
			# Check if already added
			var existing: Dictionary = manager.get_model_by_name("model_name", m.get("model_name", ""))
			if not existing.is_empty():
				skipped += 1
				continue
			# Anthropic uses api_model_id for the API call
			if provider_key == "anthropic":
				m["api_model_id"] = m["model_name"]
			manager.add_model(m)
			added += 1
		_populate_custom_models()
		if skipped > 0:
			details_label.text = "Added %d model(s), %d already existed." % [added, skipped]
		else:
			win.queue_free()
	)

	# Search filter
	search_edit.text_changed.connect(func(text: String): _filter_list.call(text))

	# Fetch models
	var _do_fetch := func():
		status_label.text = "Loading models..."
		add_btn.disabled = true
		var fetched := await _fetch_provider_models(provider_key, api_key)
		all_models.clear()
		all_models.append_array(fetched)
		if all_models.is_empty():
			status_label.text = "No models found or API error."
		else:
			status_label.text = "%d models available" % all_models.size()
			_filter_list.call(search_edit.text)

	refresh_btn.pressed.connect(func(): _do_fetch.call())
	_do_fetch.call()


## Fetch available models from a provider's API. Returns array of config dicts.
func _fetch_provider_models(provider_key: String, api_key: String) -> Array:
	var http := HTTPRequest.new()
	add_child(http)

	var url: String
	var headers: Array

	match provider_key:
		"anthropic":
			url = "https://api.anthropic.com/v1/models?limit=100"
			headers = [
				"x-api-key: %s" % api_key,
				"anthropic-version: 2023-06-01",
			]
		"openai":
			url = "https://api.openai.com/v1/models"
			headers = [
				"Authorization: Bearer %s" % api_key,
			]
		"google":
			url = "https://generativelanguage.googleapis.com/v1beta/models?key=%s&pageSize=100" % api_key
			headers = []

	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return []

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if response_code < 200 or response_code > 299:
		push_warning("[PreferencesPopup] %s API returned %d" % [provider_key, response_code])
		return []

	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		return []

	var models: Array = []

	match provider_key:
		"anthropic":
			for m in data.get("data", []):
				if not m is Dictionary:
					continue
				var model_id: String = m.get("id", "")
				var display: String = m.get("display_name", model_id)
				models.append({
					"model_name": model_id,
					"display_name": display,
					"short_name": _generate_provider_short_name(display, "A"),
				})
		"openai":
			for m in data.get("data", []):
				if not m is Dictionary:
					continue
				var model_id: String = m.get("id", "")
				# Filter to chat-capable models (skip embeddings, tts, whisper, dall-e, etc.)
				if _is_openai_chat_model(model_id):
					models.append({
						"model_name": model_id,
						"display_name": model_id,
						"short_name": _generate_provider_short_name(model_id, "OA"),
					})
			# Sort alphabetically
			models.sort_custom(func(a, b): return a["model_name"] < b["model_name"])
		"google":
			for m in data.get("models", []):
				if not m is Dictionary:
					continue
				var full_name: String = m.get("name", "")
				var model_id := full_name.replace("models/", "")
				var display: String = m.get("displayName", model_id)
				# Filter to generative models
				var methods: Array = m.get("supportedGenerationMethods", [])
				if "generateContent" in methods:
					models.append({
						"model_name": model_id,
						"display_name": display,
						"short_name": _generate_provider_short_name(display, "G"),
					})

	return models


## Filter OpenAI models to only chat-capable ones
func _is_openai_chat_model(model_id: String) -> bool:
	# Exclude known non-chat model prefixes
	var exclude_prefixes := ["tts-", "whisper-", "dall-e-", "text-embedding-", "babbage-", "davinci-", "moderation"]
	for prefix in exclude_prefixes:
		if model_id.begins_with(prefix):
			return false
	# Exclude fine-tune snapshots (contain "ft:" or long hash suffixes)
	if "ft:" in model_id:
		return false
	return true


## Generate a short name from a model display name
func _generate_provider_short_name(display: String, fallback: String) -> String:
	var words := display.replace("-", " ").replace(".", " ").split(" ")
	var short := ""
	for w in words:
		if not w.is_empty() and w[0].to_upper() != w[0].to_lower():  # is a letter
			short += w[0].to_upper()
		if short.length() >= 4:
			break
	return short if not short.is_empty() else fallback

#endregion Custom Models Tab


#region Tools Tab

const MCPServerInstallerScript := preload("res://Scripts/Services/MCP/MCPServerInstaller.gd")

var _tools_tab: VBoxContainer
var _python_env_option: OptionButton
var _python_envs_cache: Array[Dictionary] = []
var _server_path_edits: Dictionary = {}  # server_name -> LineEdit
var _server_port_spins: Dictionary = {}  # server_name -> SpinBox
var _server_auto_connect_checks: Dictionary = {}  # server_name -> CheckButton
var _server_status_labels: Dictionary = {}  # server_name -> Label
var _tool_set_checks_container: VBoxContainer


func _create_tools_tab() -> void:
	var tab_container = get_node("MarginContainer/VBoxContainer/TabContainer")
	if not tab_container:
		return

	_tools_tab = VBoxContainer.new()
	_tools_tab.name = "Tools"

	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_tools_tab.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# --- Python Environment Section ---
	var py_label := Label.new()
	py_label.text = "Python Environment"
	py_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(py_label)

	var py_hbox := HBoxContainer.new()
	py_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(py_hbox)

	_python_env_option = OptionButton.new()
	_python_env_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_python_env_option.item_selected.connect(_on_python_env_selected)
	py_hbox.add_child(_python_env_option)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.tooltip_text = "Re-scan for Python environments"
	refresh_btn.pressed.connect(_refresh_python_envs)
	py_hbox.add_child(refresh_btn)

	vbox.add_child(HSeparator.new())

	# --- Tool Sets Section ---
	var ts_label := Label.new()
	ts_label.text = "Tool Sets"
	ts_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(ts_label)

	var ts_desc := Label.new()
	ts_desc.text = "Enable or disable tool groups for internal MCP consumers. Empty = all enabled."
	ts_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(ts_desc)

	_tool_set_checks_container = VBoxContainer.new()
	vbox.add_child(_tool_set_checks_container)

	vbox.add_child(HSeparator.new())

	# --- Per-Server Sections ---
	var server_names := ["cobrowser", "nudge", "codetools"]
	var server_labels := {"cobrowser": "Cobrowser (HumanWeb)", "nudge": "Nudge", "codetools": "CodeTools"}

	for server_name in server_names:
		var s_label := Label.new()
		s_label.text = server_labels[server_name]
		s_label.add_theme_font_size_override("font_size", 16)
		vbox.add_child(s_label)

		# Status
		var status_label := Label.new()
		status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		vbox.add_child(status_label)
		_server_status_labels[server_name] = status_label

		# Installation path
		var path_hbox := HBoxContainer.new()
		path_hbox.add_theme_constant_override("separation", 6)
		vbox.add_child(path_hbox)

		var path_label := Label.new()
		path_label.text = "Path:"
		path_label.custom_minimum_size.x = 40
		path_hbox.add_child(path_label)

		var path_edit := LineEdit.new()
		path_edit.editable = false
		path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_edit.placeholder_text = "Not set"
		path_hbox.add_child(path_edit)
		_server_path_edits[server_name] = path_edit

		var browse_btn := Button.new()
		browse_btn.text = "Browse..."
		browse_btn.pressed.connect(_on_tools_browse_pressed.bind(server_name))
		path_hbox.add_child(browse_btn)

		var clear_btn := Button.new()
		clear_btn.text = "Clear"
		clear_btn.pressed.connect(_on_tools_clear_path_pressed.bind(server_name))
		path_hbox.add_child(clear_btn)

		# Port
		var port_hbox := HBoxContainer.new()
		port_hbox.add_theme_constant_override("separation", 6)
		vbox.add_child(port_hbox)

		var port_label := Label.new()
		port_label.text = "Port:"
		port_label.custom_minimum_size.x = 40
		port_hbox.add_child(port_label)

		var port_spin := SpinBox.new()
		port_spin.min_value = 1024
		port_spin.max_value = 65535
		port_spin.value = MCPConfig.DEFAULT_PORTS.get(server_name, 8000)
		port_spin.value_changed.connect(_on_tools_port_changed.bind(server_name))
		port_hbox.add_child(port_spin)
		_server_port_spins[server_name] = port_spin

		# Auto-connect
		var auto_check := CheckButton.new()
		auto_check.text = "Auto-connect on startup"
		auto_check.toggled.connect(_on_tools_auto_connect_toggled.bind(server_name))
		vbox.add_child(auto_check)
		_server_auto_connect_checks[server_name] = auto_check

		if server_name != server_names[server_names.size() - 1]:
			vbox.add_child(HSeparator.new())

	tab_container.add_child(_tools_tab)

	# Load current values
	_load_tools_settings()
	_refresh_python_envs()


## Load tools settings from MCPConfig
func _load_tools_settings() -> void:
	var config := MCPConfig.new()
	config.load_config()

	# Per-server settings
	for server_name in _server_path_edits:
		var path := config.get_installation_path(server_name)
		_server_path_edits[server_name].text = path

		var port := config.get_server_port(server_name)
		_server_port_spins[server_name].value = port

		var server_cfg = config.get_server(server_name)
		if server_cfg:
			_server_auto_connect_checks[server_name].button_pressed = server_cfg.auto_connect

		# Status
		if config.is_server_installed(server_name):
			_server_status_labels[server_name].text = "Installed"
			_server_status_labels[server_name].add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
		else:
			_server_status_labels[server_name].text = "Not installed"
			_server_status_labels[server_name].add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))

	# Tool sets
	_refresh_tool_set_checks()


## Refresh the Python environment dropdown
func _refresh_python_envs() -> void:
	_python_env_option.clear()
	_python_env_option.add_item("Auto (recommended)", 0)

	_python_envs_cache = MCPServerInstallerScript.detect_python_environments()
	for i in range(_python_envs_cache.size()):
		var env: Dictionary = _python_envs_cache[i]
		_python_env_option.add_item("%s — %s" % [env["name"], env["path"]], i + 1)

	# Select current setting
	var config := MCPConfig.new()
	config.load_config()
	if config.python_environment == "auto" or config.python_environment.is_empty():
		_python_env_option.select(0)
	else:
		# Find matching env
		for i in range(_python_envs_cache.size()):
			if _python_envs_cache[i]["path"] == config.python_environment:
				_python_env_option.select(i + 1)
				return
		# Not found in list — add as custom entry
		_python_env_option.add_item("Custom: %s" % config.python_environment, _python_envs_cache.size() + 1)
		_python_env_option.select(_python_env_option.item_count - 1)


func _on_python_env_selected(index: int) -> void:
	var config := MCPConfig.new()
	config.load_config()

	if index == 0:
		config.python_environment = "auto"
	else:
		var env_idx := index - 1
		if env_idx >= 0 and env_idx < _python_envs_cache.size():
			config.python_environment = _python_envs_cache[env_idx]["path"]

	config.save_config()


## Refresh tool set checkboxes from MinervaMCPServer
func _refresh_tool_set_checks() -> void:
	# Clear existing
	for child in _tool_set_checks_container.get_children():
		child.queue_free()

	var mcp = SingletonObject.mcp_manager
	if not mcp or not mcp.minerva_server:
		var note := Label.new()
		note.text = "Tool sets not available (MCP not initialized)"
		_tool_set_checks_container.add_child(note)
		return

	var minerva_server = mcp.minerva_server
	var sets: Dictionary = {}
	for tool_name in mcp.tool_registry:
		var tool = mcp.tool_registry[tool_name]
		if tool.server_name == "minerva" and not tool.tool_set.is_empty() and tool.tool_set != "meta":
			sets[tool.tool_set] = sets.get(tool.tool_set, 0) + 1

	if sets.is_empty():
		var note := Label.new()
		note.text = "No tool sets registered"
		_tool_set_checks_container.add_child(note)
		return

	var all_enabled: bool = minerva_server._enabled_tool_sets.is_empty()

	var set_names := sets.keys()
	set_names.sort()
	for set_name in set_names:
		var check := CheckButton.new()
		check.text = "%s (%d tools)" % [set_name, sets[set_name]]
		check.button_pressed = all_enabled or (set_name in minerva_server._enabled_tool_sets)
		check.toggled.connect(_on_tool_set_check_toggled.bind(set_name))
		_tool_set_checks_container.add_child(check)


func _on_tool_set_check_toggled(toggled_on: bool, set_name: String) -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp or not mcp.minerva_server:
		return

	var minerva_server = mcp.minerva_server

	if minerva_server._enabled_tool_sets.is_empty():
		# Currently all-enabled — build explicit list of all sets minus the unchecked one
		var all_sets: Array = []
		for tool_name in mcp.tool_registry:
			var tool = mcp.tool_registry[tool_name]
			if tool.server_name == "minerva" and not tool.tool_set.is_empty() and tool.tool_set != "meta":
				if tool.tool_set not in all_sets:
					all_sets.append(tool.tool_set)
		if not toggled_on:
			all_sets.erase(set_name)
		minerva_server._enabled_tool_sets = all_sets
	else:
		if toggled_on and set_name not in minerva_server._enabled_tool_sets:
			minerva_server._enabled_tool_sets.append(set_name)
		elif not toggled_on:
			minerva_server._enabled_tool_sets.erase(set_name)

		# If all sets are now enabled, clear the filter
		var all_sets: Array = []
		for tool_name in mcp.tool_registry:
			var tool = mcp.tool_registry[tool_name]
			if tool.server_name == "minerva" and not tool.tool_set.is_empty() and tool.tool_set != "meta":
				if tool.tool_set not in all_sets:
					all_sets.append(tool.tool_set)
		if minerva_server._enabled_tool_sets.size() >= all_sets.size():
			minerva_server._enabled_tool_sets = []

	# Persist to config
	var config := MCPConfig.new()
	config.load_config()
	config.enabled_tool_groups = []
	for s in minerva_server._enabled_tool_sets:
		config.enabled_tool_groups.append(str(s))
	config.save_config()


## Browse for server installation directory
func _on_tools_browse_pressed(server_name: String) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Locate %s Installation" % server_name.capitalize()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.min_size = Vector2i(600, 400)

	dialog.dir_selected.connect(func(path: String) -> void:
		_on_tools_dir_selected(server_name, path)
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void:
		dialog.queue_free()
	)

	get_tree().root.add_child(dialog)
	dialog.popup_centered()


func _on_tools_dir_selected(server_name: String, path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		SingletonObject.create_toast_notification("Directory does not exist", ToastNotification.Type.ERROR)
		return

	# Validate
	if not _validate_tools_server_dir(server_name, path):
		return

	var config := MCPConfig.new()
	config.load_config()
	config.set_installation_path(server_name, path)
	config.save_config()

	_server_path_edits[server_name].text = path
	_server_status_labels[server_name].text = "Installed"
	_server_status_labels[server_name].add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))

	SingletonObject.create_toast_notification(
		"%s: Installation registered" % server_name.capitalize(),
		ToastNotification.Type.SUCCESS
	)


## Validate server directory (shared logic)
static func _validate_tools_server_dir(server_name: String, path: String) -> bool:
	match server_name:
		"cobrowser":
			if not FileAccess.file_exists(path.path_join("src/Library/cobrowser_service.py")):
				SingletonObject.create_toast_notification(
					"Not a valid HumanWeb directory — missing src/Library/cobrowser_service.py",
					ToastNotification.Type.ERROR)
				return false
		"nudge":
			if not FileAccess.file_exists(path.path_join("setup.py")) and not FileAccess.file_exists(path.path_join("pyproject.toml")):
				SingletonObject.create_toast_notification(
					"Not a valid Nudge directory — missing setup.py or pyproject.toml",
					ToastNotification.Type.ERROR)
				return false
		"codetools":
			if not FileAccess.file_exists(path.path_join("setup.py")) and not FileAccess.file_exists(path.path_join("pyproject.toml")):
				SingletonObject.create_toast_notification(
					"Not a valid CodeTools directory — missing setup.py or pyproject.toml",
					ToastNotification.Type.ERROR)
				return false
	return true


func _on_tools_clear_path_pressed(server_name: String) -> void:
	var config := MCPConfig.new()
	config.load_config()
	config.installation_paths.erase(server_name)
	config.save_config()

	_server_path_edits[server_name].text = ""
	_server_status_labels[server_name].text = "Not installed"
	_server_status_labels[server_name].add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))

	SingletonObject.create_toast_notification(
		"%s: Installation path cleared" % server_name.capitalize(),
		ToastNotification.Type.WARNING
	)


func _on_tools_port_changed(value: float, server_name: String) -> void:
	var config := MCPConfig.new()
	config.load_config()
	config.set_server_port(server_name, int(value))
	config.save_config()


func _on_tools_auto_connect_toggled(toggled_on: bool, server_name: String) -> void:
	var config := MCPConfig.new()
	config.load_config()
	var server_cfg = config.get_server(server_name)
	if server_cfg:
		server_cfg.auto_connect = toggled_on
		config.save_config()

#endregion Tools Tab
