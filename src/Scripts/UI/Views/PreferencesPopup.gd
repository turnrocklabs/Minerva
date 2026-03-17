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
	call_deferred("_create_skills_tab")
	call_deferred("_create_voice_tab")
	call_deferred("_create_containers_tab")

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
			_on_core_connection_changed(true)
	)

	Core.client.connection_error.connect(
		func(error: int):
			connection_label.text = "Core WS Error (%s)" % error_string(error)
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.text = "Connect"
			connect_button.tooltip_text = "Connect to the Core"
			_on_core_connection_changed(false)
	)

	Core.client.connection_closed.connect(
		func():
			connection_label.text = "You are not connected to core"
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.text = "Connect"
			connect_button.tooltip_text = "Connect to the Core"
			_on_core_connection_changed(false)
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
var _server_list_container: VBoxContainer
var _profile_checks_container: VBoxContainer
var _add_server_dialog_prefs: AddMCPServerDialog = null


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

	# --- MCP Servers Section (dynamic from config) ---
	var servers_header_hbox := HBoxContainer.new()
	servers_header_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(servers_header_hbox)

	var servers_header := Label.new()
	servers_header.text = "MCP Servers"
	servers_header.add_theme_font_size_override("font_size", 16)
	servers_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	servers_header_hbox.add_child(servers_header)

	var add_server_btn := Button.new()
	add_server_btn.text = "Add Server..."
	add_server_btn.pressed.connect(_on_add_server_button_pressed)
	servers_header_hbox.add_child(add_server_btn)

	_server_list_container = VBoxContainer.new()
	vbox.add_child(_server_list_container)

	vbox.add_child(HSeparator.new())

	# --- Profiles Section ---
	var profiles_label := Label.new()
	profiles_label.text = "Tool Profiles"
	profiles_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(profiles_label)

	var profiles_desc := Label.new()
	profiles_desc.text = "Profiles control which tool groups and MCP servers are active by default. Per-agent and per-chat settings override global profiles."
	profiles_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(profiles_desc)

	_profile_checks_container = VBoxContainer.new()
	vbox.add_child(_profile_checks_container)

	tab_container.add_child(_tools_tab)

	# Load current values
	_load_tools_settings()
	_refresh_python_envs()


## Load tools settings from MCPConfig
func _load_tools_settings() -> void:
	var config := MCPConfig.new()
	config.load_config()

	# Build dynamic server list
	_rebuild_server_list(config)

	# Per-server settings (for servers that have UI controls)
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

	# Skills
	_rebuild_skill_checks()


## Build the dynamic server list in the Tools tab
func _rebuild_server_list(config: MCPConfig) -> void:
	if not _server_list_container:
		return

	# Clear existing
	for child in _server_list_container.get_children():
		child.queue_free()
	_server_path_edits.clear()
	_server_port_spins.clear()
	_server_auto_connect_checks.clear()
	_server_status_labels.clear()

	var mcp = SingletonObject.mcp_manager

	for server_cfg in config.servers:
		var server_name: String = server_cfg.name
		var display_name: String = MCPKnownServers.get_display_name(server_name)
		var is_known := MCPKnownServers.is_known(server_name)
		var is_user := server_cfg.origin == "user"

		# Header row with name and status
		var header_hbox := HBoxContainer.new()
		header_hbox.add_theme_constant_override("separation", 8)
		_server_list_container.add_child(header_hbox)

		var s_label := Label.new()
		s_label.text = display_name
		s_label.add_theme_font_size_override("font_size", 14)
		s_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_hbox.add_child(s_label)

		# Connection status
		var connected = mcp and mcp.is_server_connected(server_name)
		var status_label := Label.new()
		status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		header_hbox.add_child(status_label)
		_server_status_labels[server_name] = status_label

		# Connect/Disconnect button
		var conn_btn := Button.new()
		conn_btn.text = "Disconnect" if connected else "Connect"
		conn_btn.pressed.connect(_on_server_connect_toggle.bind(server_name, conn_btn))
		header_hbox.add_child(conn_btn)

		# Remove button (user servers only)
		if is_user:
			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.pressed.connect(_on_server_remove.bind(server_name))
			header_hbox.add_child(remove_btn)

		# Connection info row
		var info_hbox := HBoxContainer.new()
		info_hbox.add_theme_constant_override("separation", 6)
		_server_list_container.add_child(info_hbox)

		var info_label := Label.new()
		if server_cfg.type == "stdio":
			var cmd_display := server_cfg.command
			if not server_cfg.args.is_empty():
				cmd_display += " " + " ".join(server_cfg.args)
			info_label.text = "  STDIO: %s" % cmd_display
		else:
			var type_prefix := "WS" if server_cfg.type == "websocket" else "HTTP"
			info_label.text = "  %s: %s" % [type_prefix, server_cfg.url]
		info_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		info_hbox.add_child(info_label)

		# Known servers get installation path, port, browse controls
		if is_known and MCPKnownServers.is_installable(server_name):
			var path_hbox := HBoxContainer.new()
			path_hbox.add_theme_constant_override("separation", 6)
			_server_list_container.add_child(path_hbox)

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
			_server_list_container.add_child(port_hbox)

			var port_label := Label.new()
			port_label.text = "Port:"
			port_label.custom_minimum_size.x = 40
			port_hbox.add_child(port_label)

			var port_spin := SpinBox.new()
			port_spin.min_value = 1024
			port_spin.max_value = 65535
			port_spin.value = config.get_server_port(server_name)
			port_spin.value_changed.connect(_on_tools_port_changed.bind(server_name))
			port_hbox.add_child(port_spin)
			_server_port_spins[server_name] = port_spin

		# Auto-connect
		var auto_check := CheckButton.new()
		auto_check.text = "Auto-connect on startup"
		auto_check.button_pressed = server_cfg.auto_connect
		auto_check.toggled.connect(_on_tools_auto_connect_toggled.bind(server_name))
		_server_list_container.add_child(auto_check)
		_server_auto_connect_checks[server_name] = auto_check

		_server_list_container.add_child(HSeparator.new())


## Handle connect/disconnect toggle from preferences
func _on_server_connect_toggle(server_name: String, btn: Button) -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp:
		return
	if mcp.is_server_connected(server_name):
		mcp.disconnect_server(server_name)
		btn.text = "Connect"
	else:
		var err = await mcp.connect_server(server_name)
		if err == OK:
			btn.text = "Disconnect"
	_load_tools_settings()


## Handle remove user server from preferences
func _on_server_remove(server_name: String) -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp:
		return
	mcp.remove_server_at_runtime(server_name)
	_load_tools_settings()


## Handle Add Server button in preferences
func _on_add_server_button_pressed() -> void:
	if not _add_server_dialog_prefs:
		_add_server_dialog_prefs = AddMCPServerDialog.new()
		_add_server_dialog_prefs.server_added.connect(_on_prefs_server_added)
		get_tree().root.add_child(_add_server_dialog_prefs)
	_add_server_dialog_prefs.reset()
	_add_server_dialog_prefs.popup_centered()


func _on_prefs_server_added(config_data: Dictionary) -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp:
		return

	var transport: String = config_data.get("type", "http")
	var server_config: MCPConfig.ServerConfig
	if transport == "stdio":
		var cmd_args := PackedStringArray()
		for arg in config_data.get("args", []):
			cmd_args.append(str(arg))
		server_config = MCPConfig.ServerConfig.create_stdio(
			config_data.get("name", ""), config_data.get("command", ""), cmd_args
		)
		var wd: String = config_data.get("working_directory", "")
		if not wd.is_empty():
			server_config.working_directory = wd
	else:
		server_config = MCPConfig.ServerConfig.new(
			config_data.get("name", ""), transport, config_data.get("url", "")
		)
	server_config.auto_connect = config_data.get("auto_connect", false)
	server_config.origin = "user"
	server_config.persistent = config_data.get("persistent", true)
	var endpoint: String = config_data.get("mcp_endpoint", "")
	if not endpoint.is_empty():
		server_config.mcp_endpoint = endpoint

	await mcp.add_server_at_runtime(server_config, true)
	_load_tools_settings()


## Build profile checkboxes from SkillManager
func _rebuild_skill_checks() -> void:
	if not _profile_checks_container:
		return

	for child in _profile_checks_container.get_children():
		child.queue_free()

	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	for profile in skill_manager.get_profiles():
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		_profile_checks_container.add_child(hbox)

		var check := CheckButton.new()
		check.text = profile.name
		check.tooltip_text = profile.description
		check.button_pressed = skill_manager.is_active(profile.id)
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.toggled.connect(_on_profile_toggled.bind(profile.id))
		hbox.add_child(check)

		if not profile.tool_sets.is_empty():
			var tools_label := Label.new()
			tools_label.text = "[%s]" % ", ".join(profile.tool_sets)
			tools_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			tools_label.add_theme_font_size_override("font_size", 11)
			hbox.add_child(tools_label)
		else:
			var all_label := Label.new()
			all_label.text = "[all tools]"
			all_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			all_label.add_theme_font_size_override("font_size", 11)
			hbox.add_child(all_label)


func _on_profile_toggled(enabled: bool, skill_id: String) -> void:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	var mcp = SingletonObject.mcp_manager
	if enabled:
		skill_manager.activate_skill(skill_id, mcp)
	else:
		skill_manager.deactivate_skill(skill_id, mcp)


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
	# Check for server-specific validation file from registry
	var validation_file := MCPKnownServers.get_validation_file(server_name)
	if not validation_file.is_empty():
		if not FileAccess.file_exists(path.path_join(validation_file)):
			var display := MCPKnownServers.get_display_name(server_name)
			SingletonObject.create_toast_notification(
				"Not a valid %s directory — missing %s" % [display, validation_file],
				ToastNotification.Type.ERROR)
			return false
		return true

	# Fallback: check for setup.py or pyproject.toml (standard Python packages)
	if MCPKnownServers.is_known(server_name):
		if not FileAccess.file_exists(path.path_join("setup.py")) and not FileAccess.file_exists(path.path_join("pyproject.toml")):
			var display := MCPKnownServers.get_display_name(server_name)
			SingletonObject.create_toast_notification(
				"Not a valid %s directory — missing setup.py or pyproject.toml" % display,
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


#region Skills Tab

var _skills_tab: VBoxContainer
var _skills_list_container: VBoxContainer
var _selected_skill_id: String = ""
var _skill_name_edit: LineEdit
var _skill_desc_edit: LineEdit
var _skill_instructions_edit: TextEdit
var _skill_exec_path_edit: LineEdit
var _skill_exec_args_edit: LineEdit
var _skill_exec_desc_edit: LineEdit
var _skill_exec_dir_edit: LineEdit
var _skill_active_check: CheckButton
var _skill_detail_container: VBoxContainer


func _create_skills_tab() -> void:
	var tab_container = get_node("MarginContainer/VBoxContainer/TabContainer")
	if not tab_container:
		return

	_skills_tab = VBoxContainer.new()
	_skills_tab.name = "Skills"

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_skills_tab.add_child(margin)

	var hsplit := HSplitContainer.new()
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(hsplit)

	# --- Left: Skill list ---
	var left_vbox := VBoxContainer.new()
	left_vbox.custom_minimum_size = Vector2(200, 0)
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_stretch_ratio = 0.3
	hsplit.add_child(left_vbox)

	var list_header := Label.new()
	list_header.text = "Skills"
	list_header.add_theme_font_size_override("font_size", 16)
	left_vbox.add_child(list_header)

	_skills_list_container = VBoxContainer.new()
	_skills_list_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(_skills_list_container)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	left_vbox.add_child(btn_row)

	var add_btn := Button.new()
	add_btn.text = "New Skill"
	add_btn.pressed.connect(_on_new_skill_pressed)
	btn_row.add_child(add_btn)

	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	remove_btn.pressed.connect(_on_remove_selected_skill)
	btn_row.add_child(remove_btn)

	# --- Right: Skill detail editor ---
	_skill_detail_container = VBoxContainer.new()
	_skill_detail_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_detail_container.size_flags_stretch_ratio = 0.7
	_skill_detail_container.add_theme_constant_override("separation", 6)
	hsplit.add_child(_skill_detail_container)

	# Name
	var name_row := HBoxContainer.new()
	_skill_detail_container.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name:"
	name_lbl.custom_minimum_size = Vector2(120, 0)
	name_row.add_child(name_lbl)
	_skill_name_edit = LineEdit.new()
	_skill_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_name_edit.text_changed.connect(_on_skill_field_changed)
	name_row.add_child(_skill_name_edit)

	# Description
	var desc_row := HBoxContainer.new()
	_skill_detail_container.add_child(desc_row)
	var desc_lbl := Label.new()
	desc_lbl.text = "Description:"
	desc_lbl.custom_minimum_size = Vector2(120, 0)
	desc_row.add_child(desc_lbl)
	_skill_desc_edit = LineEdit.new()
	_skill_desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_desc_edit.text_changed.connect(_on_skill_field_changed)
	desc_row.add_child(_skill_desc_edit)

	# Active toggle
	_skill_active_check = CheckButton.new()
	_skill_active_check.text = "Active"
	_skill_active_check.toggled.connect(_on_skill_active_toggled)
	_skill_detail_container.add_child(_skill_active_check)

	# Instructions
	var instr_lbl := Label.new()
	instr_lbl.text = "Instructions (injected into system prompt):"
	_skill_detail_container.add_child(instr_lbl)

	_skill_instructions_edit = TextEdit.new()
	_skill_instructions_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_skill_instructions_edit.custom_minimum_size = Vector2(0, 200)
	_skill_instructions_edit.placeholder_text = "Write instructions in markdown that teach the LLM this skill..."
	_skill_instructions_edit.text_changed.connect(_on_skill_instructions_changed)
	_skill_detail_container.add_child(_skill_instructions_edit)

	# Executable section
	var exec_sep := HSeparator.new()
	_skill_detail_container.add_child(exec_sep)

	var exec_header := Label.new()
	exec_header.text = "Executable (optional — registers as an LLM tool)"
	exec_header.add_theme_font_size_override("font_size", 13)
	_skill_detail_container.add_child(exec_header)

	# Executable path
	var exec_path_row := HBoxContainer.new()
	_skill_detail_container.add_child(exec_path_row)
	var exec_path_lbl := Label.new()
	exec_path_lbl.text = "Path:"
	exec_path_lbl.custom_minimum_size = Vector2(120, 0)
	exec_path_row.add_child(exec_path_lbl)
	_skill_exec_path_edit = LineEdit.new()
	_skill_exec_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_exec_path_edit.placeholder_text = "/path/to/script.sh"
	_skill_exec_path_edit.text_changed.connect(_on_skill_field_changed)
	exec_path_row.add_child(_skill_exec_path_edit)

	# Executable args
	var exec_args_row := HBoxContainer.new()
	_skill_detail_container.add_child(exec_args_row)
	var exec_args_lbl := Label.new()
	exec_args_lbl.text = "Default args:"
	exec_args_lbl.custom_minimum_size = Vector2(120, 0)
	exec_args_row.add_child(exec_args_lbl)
	_skill_exec_args_edit = LineEdit.new()
	_skill_exec_args_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_exec_args_edit.placeholder_text = "--flag value (space-separated)"
	_skill_exec_args_edit.text_changed.connect(_on_skill_field_changed)
	exec_args_row.add_child(_skill_exec_args_edit)

	# Executable description
	var exec_desc_row := HBoxContainer.new()
	_skill_detail_container.add_child(exec_desc_row)
	var exec_desc_lbl := Label.new()
	exec_desc_lbl.text = "Tool description:"
	exec_desc_lbl.custom_minimum_size = Vector2(120, 0)
	exec_desc_row.add_child(exec_desc_lbl)
	_skill_exec_desc_edit = LineEdit.new()
	_skill_exec_desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_exec_desc_edit.placeholder_text = "What the executable does (shown to LLM)"
	_skill_exec_desc_edit.text_changed.connect(_on_skill_field_changed)
	exec_desc_row.add_child(_skill_exec_desc_edit)

	# Executable working dir
	var exec_dir_row := HBoxContainer.new()
	_skill_detail_container.add_child(exec_dir_row)
	var exec_dir_lbl := Label.new()
	exec_dir_lbl.text = "Working dir:"
	exec_dir_lbl.custom_minimum_size = Vector2(120, 0)
	exec_dir_row.add_child(exec_dir_lbl)
	_skill_exec_dir_edit = LineEdit.new()
	_skill_exec_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_exec_dir_edit.placeholder_text = "/optional/working/directory"
	_skill_exec_dir_edit.text_changed.connect(_on_skill_field_changed)
	exec_dir_row.add_child(_skill_exec_dir_edit)

	tab_container.add_child(_skills_tab)

	_rebuild_skills_list()
	_show_skill_detail("")  # Empty state


func _rebuild_skills_list() -> void:
	if not _skills_list_container:
		return

	for child in _skills_list_container.get_children():
		child.queue_free()

	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	for skill in skill_manager.get_skills_only():
		var btn := Button.new()
		btn.text = skill.name
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.flat = _selected_skill_id != skill.id
		if _selected_skill_id == skill.id:
			btn.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
		btn.pressed.connect(_on_skill_list_selected.bind(skill.id))
		_skills_list_container.add_child(btn)


func _on_skill_list_selected(skill_id: String) -> void:
	_save_current_skill()
	_selected_skill_id = skill_id
	_show_skill_detail(skill_id)
	_rebuild_skills_list()


func _show_skill_detail(skill_id: String) -> void:
	if not _skill_detail_container:
		return

	var skill_manager = SingletonObject.get_skill_manager()
	if skill_id.is_empty() or not skill_manager:
		_skill_name_edit.text = ""
		_skill_desc_edit.text = ""
		_skill_instructions_edit.text = ""
		_skill_exec_path_edit.text = ""
		_skill_exec_args_edit.text = ""
		_skill_exec_desc_edit.text = ""
		_skill_exec_dir_edit.text = ""
		_skill_active_check.button_pressed = false
		_skill_detail_container.visible = false
		return

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		_skill_detail_container.visible = false
		return

	_skill_detail_container.visible = true
	_skill_name_edit.text = skill.name
	_skill_desc_edit.text = skill.description
	_skill_instructions_edit.text = skill.instructions
	_skill_exec_path_edit.text = skill.executable_path
	_skill_exec_args_edit.text = " ".join(skill.executable_args)
	_skill_exec_desc_edit.text = skill.executable_description
	_skill_exec_dir_edit.text = skill.executable_working_dir
	_skill_active_check.button_pressed = skill_manager.is_active(skill_id)


func _save_current_skill() -> void:
	if _selected_skill_id.is_empty():
		return

	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	var skill = skill_manager.get_skill(_selected_skill_id)
	if not skill or not skill.is_skill():
		return

	skill.name = _skill_name_edit.text.strip_edges()
	skill.description = _skill_desc_edit.text.strip_edges()
	skill.instructions = _skill_instructions_edit.text
	skill.executable_path = _skill_exec_path_edit.text.strip_edges()
	skill.executable_args = []
	var args_text := _skill_exec_args_edit.text.strip_edges()
	if not args_text.is_empty():
		for arg in args_text.split(" ", false):
			skill.executable_args.append(arg)
	skill.executable_description = _skill_exec_desc_edit.text.strip_edges()
	skill.executable_working_dir = _skill_exec_dir_edit.text.strip_edges()

	skill_manager.save_config()


func _on_skill_field_changed(_text = "") -> void:
	_save_current_skill()
	_rebuild_skills_list()


func _on_skill_instructions_changed() -> void:
	_save_current_skill()


func _on_skill_active_toggled(enabled: bool) -> void:
	if _selected_skill_id.is_empty():
		return

	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	var mcp = SingletonObject.mcp_manager
	if enabled:
		skill_manager.activate_skill(_selected_skill_id, mcp)
	else:
		skill_manager.deactivate_skill(_selected_skill_id, mcp)


func _on_new_skill_pressed() -> void:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	# Generate unique ID
	var base_id := "skill_%d" % (skill_manager.get_skills_only().size() + 1)
	var skill := SkillDefinition.new(base_id, "New Skill", "")
	skill.origin = "user"
	skill_manager.add_skill(skill)

	_selected_skill_id = skill.id
	_rebuild_skills_list()
	_show_skill_detail(skill.id)


func _on_remove_selected_skill() -> void:
	if _selected_skill_id.is_empty():
		return

	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return

	skill_manager.remove_skill(_selected_skill_id)
	_selected_skill_id = ""
	_rebuild_skills_list()
	_show_skill_detail("")

#endregion Skills Tab

#region Voice Tab

var _voice_tab: VBoxContainer
var _stt_provider_option: OptionButton
var _stt_backend_option: OptionButton
var _tts_provider_option: OptionButton
var _voice_selector: OptionButton
var _voice_preview_btn: Button
var _tts_backend_option: OptionButton
var _speak_mode_option: OptionButton
var _summary_model_option: OptionButton
var _summary_model_row: HBoxContainer
var _summary_timeout_spin: SpinBox
var _summary_timeout_row: HBoxContainer
var _auto_send_check: CheckButton
var _whisper_fallback_check: CheckButton
var _stt_model_option: OptionButton
var _vad_silence_slider: HSlider
var _vad_silence_value_label: Label
var _tts_volume_slider: HSlider
var _voice_status_label: Label
var _voice_refresh_btn: Button
var _voices_cache: Array = []


func _create_voice_tab() -> void:
	var tab_container = get_node("MarginContainer/VBoxContainer/TabContainer")
	if not tab_container:
		return

	_voice_tab = VBoxContainer.new()
	_voice_tab.name = "Voice"

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_voice_tab.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# --- STT Section ---
	var stt_header := Label.new()
	stt_header.text = "Speech-to-Text (STT)"
	stt_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(stt_header)

	var stt_row := HBoxContainer.new()
	stt_row.add_theme_constant_override("separation", 8)
	vbox.add_child(stt_row)
	var stt_lbl := Label.new()
	stt_lbl.text = "Provider:"
	stt_lbl.custom_minimum_size = Vector2(140, 0)
	stt_row.add_child(stt_lbl)
	_stt_provider_option = OptionButton.new()
	_stt_provider_option.add_item("Voice Service (via Core)", VoiceConfig.STTProvider.VOICE_SERVICE)
	_stt_provider_option.add_item("OpenAI Whisper (REST)", VoiceConfig.STTProvider.OPENAI_WHISPER)
	_stt_provider_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stt_provider_option.item_selected.connect(_on_stt_provider_changed)
	stt_row.add_child(_stt_provider_option)

	# STT backend (voice-service backends: faster-whisper, qwen3-asr)
	var stt_backend_row := HBoxContainer.new()
	stt_backend_row.add_theme_constant_override("separation", 8)
	vbox.add_child(stt_backend_row)
	var stt_backend_lbl := Label.new()
	stt_backend_lbl.text = "STT Backend:"
	stt_backend_lbl.custom_minimum_size = Vector2(140, 0)
	stt_backend_row.add_child(stt_backend_lbl)
	_stt_backend_option = OptionButton.new()
	_stt_backend_option.add_item("faster-whisper (fast)", 0)
	_stt_backend_option.add_item("qwen3-asr (quality)", 1)
	_stt_backend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stt_backend_option.item_selected.connect(_on_stt_backend_changed)
	stt_backend_row.add_child(_stt_backend_option)

	# STT model selector (for faster-whisper)
	var stt_model_row := HBoxContainer.new()
	stt_model_row.add_theme_constant_override("separation", 8)
	vbox.add_child(stt_model_row)
	var stt_model_lbl := Label.new()
	stt_model_lbl.text = "STT Model:"
	stt_model_lbl.custom_minimum_size = Vector2(140, 0)
	stt_model_row.add_child(stt_model_lbl)
	_stt_model_option = OptionButton.new()
	_stt_model_option.add_item("tiny.en (fastest)", 0)
	_stt_model_option.add_item("small.en (balanced)", 1)
	_stt_model_option.add_item("medium.en (accurate)", 2)
	_stt_model_option.add_item("large-v3-turbo (best)", 3)
	_stt_model_option.add_item("distil-large-v3 (fast+accurate)", 4)
	_stt_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stt_model_option.item_selected.connect(_on_stt_model_changed)
	stt_model_row.add_child(_stt_model_option)

	# Whisper fallback
	_whisper_fallback_check = CheckButton.new()
	_whisper_fallback_check.text = "Fall back to Whisper when Core disconnected"
	_whisper_fallback_check.toggled.connect(_on_whisper_fallback_toggled)
	vbox.add_child(_whisper_fallback_check)

	vbox.add_child(HSeparator.new())

	# --- TTS Section ---
	var tts_header := Label.new()
	tts_header.text = "Text-to-Speech (TTS)"
	tts_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(tts_header)

	var tts_row := HBoxContainer.new()
	tts_row.add_theme_constant_override("separation", 8)
	vbox.add_child(tts_row)
	var tts_lbl := Label.new()
	tts_lbl.text = "Provider:"
	tts_lbl.custom_minimum_size = Vector2(140, 0)
	tts_row.add_child(tts_lbl)
	_tts_provider_option = OptionButton.new()
	_tts_provider_option.add_item("Voice Service (via Core)", VoiceConfig.TTSProvider.VOICE_SERVICE)
	_tts_provider_option.add_item("Disabled", VoiceConfig.TTSProvider.NONE)
	_tts_provider_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tts_provider_option.item_selected.connect(_on_tts_provider_changed)
	tts_row.add_child(_tts_provider_option)

	# Backend filter
	var backend_row := HBoxContainer.new()
	backend_row.add_theme_constant_override("separation", 8)
	vbox.add_child(backend_row)
	var backend_lbl := Label.new()
	backend_lbl.text = "TTS Backend:"
	backend_lbl.custom_minimum_size = Vector2(140, 0)
	backend_row.add_child(backend_lbl)
	_tts_backend_option = OptionButton.new()
	_tts_backend_option.add_item("All", 0)
	_tts_backend_option.add_item("kokoro", 1)
	_tts_backend_option.add_item("qwen3-base", 2)
	_tts_backend_option.add_item("qwen3-customvoice", 3)
	_tts_backend_option.add_item("gpt-sovits", 4)
	_tts_backend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tts_backend_option.item_selected.connect(_on_tts_backend_changed)
	backend_row.add_child(_tts_backend_option)

	# Voice selector
	var voice_row := HBoxContainer.new()
	voice_row.add_theme_constant_override("separation", 8)
	vbox.add_child(voice_row)
	var voice_lbl := Label.new()
	voice_lbl.text = "Voice:"
	voice_lbl.custom_minimum_size = Vector2(140, 0)
	voice_row.add_child(voice_lbl)
	_voice_selector = OptionButton.new()
	_voice_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_selector.add_item("(click Refresh to load voices)")
	_voice_selector.disabled = true
	_voice_selector.item_selected.connect(_on_voice_selected)
	voice_row.add_child(_voice_selector)

	var voice_btn_row := HBoxContainer.new()
	voice_btn_row.add_theme_constant_override("separation", 4)
	voice_row.add_child(voice_btn_row)

	_voice_refresh_btn = Button.new()
	_voice_refresh_btn.text = "Refresh"
	_voice_refresh_btn.pressed.connect(_on_voice_refresh_pressed)
	voice_btn_row.add_child(_voice_refresh_btn)

	_voice_preview_btn = Button.new()
	_voice_preview_btn.text = "Preview"
	_voice_preview_btn.pressed.connect(_on_voice_preview_pressed)
	voice_btn_row.add_child(_voice_preview_btn)

	vbox.add_child(HSeparator.new())

	# --- Audio Settings ---
	var audio_header := Label.new()
	audio_header.text = "Audio Settings"
	audio_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(audio_header)

	# Volume
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 8)
	vbox.add_child(vol_row)
	var vol_lbl := Label.new()
	vol_lbl.text = "TTS Volume:"
	vol_lbl.custom_minimum_size = Vector2(140, 0)
	vol_row.add_child(vol_lbl)
	_tts_volume_slider = HSlider.new()
	_tts_volume_slider.min_value = 0.0
	_tts_volume_slider.max_value = 1.0
	_tts_volume_slider.step = 0.05
	_tts_volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tts_volume_slider.value_changed.connect(_on_tts_volume_changed)
	vol_row.add_child(_tts_volume_slider)

	# Speak mode
	var speak_mode_row := HBoxContainer.new()
	speak_mode_row.add_theme_constant_override("separation", 8)
	vbox.add_child(speak_mode_row)
	var speak_mode_lbl := Label.new()
	speak_mode_lbl.text = "Auto-speak:"
	speak_mode_lbl.custom_minimum_size = Vector2(140, 0)
	speak_mode_row.add_child(speak_mode_lbl)
	_speak_mode_option = OptionButton.new()
	_speak_mode_option.add_item("Off", VoiceConfig.SpeakMode.OFF)
	_speak_mode_option.add_item("Speak Full Response", VoiceConfig.SpeakMode.FULL)
	_speak_mode_option.add_item("Summarize then Speak", VoiceConfig.SpeakMode.SUMMARIZE)
	_speak_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_speak_mode_option.item_selected.connect(_on_speak_mode_changed)
	speak_mode_row.add_child(_speak_mode_option)

	# Summary model (visible only in SUMMARIZE mode)
	_summary_model_row = HBoxContainer.new()
	_summary_model_row.add_theme_constant_override("separation", 8)
	_summary_model_row.visible = false
	vbox.add_child(_summary_model_row)
	var summary_model_lbl := Label.new()
	summary_model_lbl.text = "Summary Model:"
	summary_model_lbl.custom_minimum_size = Vector2(140, 0)
	_summary_model_row.add_child(summary_model_lbl)
	_summary_model_option = OptionButton.new()
	_summary_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_model_option.item_selected.connect(_on_summary_model_changed)
	_summary_model_row.add_child(_summary_model_option)

	# Summary timeout (visible only in SUMMARIZE mode)
	_summary_timeout_row = HBoxContainer.new()
	_summary_timeout_row.add_theme_constant_override("separation", 8)
	_summary_timeout_row.visible = false
	vbox.add_child(_summary_timeout_row)
	var summary_timeout_lbl := Label.new()
	summary_timeout_lbl.text = "Summary Timeout:"
	summary_timeout_lbl.custom_minimum_size = Vector2(140, 0)
	_summary_timeout_row.add_child(summary_timeout_lbl)
	_summary_timeout_spin = SpinBox.new()
	_summary_timeout_spin.min_value = 5.0
	_summary_timeout_spin.max_value = 120.0
	_summary_timeout_spin.step = 5.0
	_summary_timeout_spin.suffix = "s"
	_summary_timeout_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_timeout_spin.value_changed.connect(_on_summary_timeout_changed)
	_summary_timeout_row.add_child(_summary_timeout_spin)

	# Auto-send transcription
	_auto_send_check = CheckButton.new()
	_auto_send_check.text = "Auto-send after transcription (skip editing)"
	_auto_send_check.toggled.connect(_on_auto_send_toggled)
	vbox.add_child(_auto_send_check)

	# VAD silence duration (think time)
	var vad_silence_row := HBoxContainer.new()
	vad_silence_row.add_theme_constant_override("separation", 8)
	vbox.add_child(vad_silence_row)
	var vad_silence_lbl := Label.new()
	vad_silence_lbl.text = "Pause tolerance:"
	vad_silence_lbl.custom_minimum_size = Vector2(140, 0)
	vad_silence_row.add_child(vad_silence_lbl)
	_vad_silence_slider = HSlider.new()
	_vad_silence_slider.min_value = 0.3
	_vad_silence_slider.max_value = 5.0
	_vad_silence_slider.step = 0.1
	_vad_silence_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vad_silence_slider.value_changed.connect(_on_vad_silence_changed)
	vad_silence_row.add_child(_vad_silence_slider)
	_vad_silence_value_label = Label.new()
	_vad_silence_value_label.text = "1.0s"
	_vad_silence_value_label.custom_minimum_size = Vector2(40, 0)
	vad_silence_row.add_child(_vad_silence_value_label)

	vbox.add_child(HSeparator.new())

	# --- Status ---
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	vbox.add_child(status_row)
	_voice_status_label = Label.new()
	_voice_status_label.text = "Voice service status: unknown"
	_voice_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_voice_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_voice_status_label)

	var status_btn := Button.new()
	status_btn.text = "Check Status"
	status_btn.pressed.connect(_on_voice_status_pressed)
	status_row.add_child(status_btn)

	tab_container.add_child(_voice_tab)

	# Load saved preferences into UI
	_voice_load_ui_from_config()

	# Auto-populate voice list if Core is connected
	if Core.client._connected:
		_on_voice_refresh_pressed()


func _voice_load_ui_from_config() -> void:
	var cfg := SingletonObject.get_voice_config()

	# STT provider
	for i in _stt_provider_option.item_count:
		if _stt_provider_option.get_item_id(i) == cfg.stt_provider:
			_stt_provider_option.select(i)
			break

	# TTS provider
	for i in _tts_provider_option.item_count:
		if _tts_provider_option.get_item_id(i) == cfg.tts_provider:
			_tts_provider_option.select(i)
			break

	# STT backend
	match cfg.stt_backend:
		"qwen3-asr": _stt_backend_option.select(1)
		_: _stt_backend_option.select(0)
	_stt_backend_option.disabled = cfg.stt_provider != VoiceConfig.STTProvider.VOICE_SERVICE

	# TTS backend
	match cfg.tts_backend:
		"kokoro": _tts_backend_option.select(1)
		"qwen3-base": _tts_backend_option.select(2)
		"qwen3-customvoice": _tts_backend_option.select(3)
		"gpt-sovits": _tts_backend_option.select(4)
		_: _tts_backend_option.select(0)

	_whisper_fallback_check.button_pressed = cfg.whisper_fallback
	_auto_send_check.button_pressed = cfg.auto_send_transcription
	_tts_volume_slider.value = cfg.tts_volume

	# STT model
	var stt_model_map := {"tiny.en": 0, "small.en": 1, "medium.en": 2, "large-v3-turbo": 3, "distil-large-v3": 4}
	if _stt_model_option:
		_stt_model_option.select(stt_model_map.get(cfg.stt_model, 1))

	# VAD silence duration
	if _vad_silence_slider:
		_vad_silence_slider.value = cfg.vad_silence_duration
	if _vad_silence_value_label:
		_vad_silence_value_label.text = "%.1fs" % cfg.vad_silence_duration

	# Speak mode
	for i in _speak_mode_option.item_count:
		if _speak_mode_option.get_item_id(i) == cfg.speak_mode:
			_speak_mode_option.select(i)
			break
	_summary_timeout_spin.value = cfg.summary_timeout
	_update_summary_controls_visible()
	_populate_summary_models()

	# Update TTS section visibility
	_update_tts_section_enabled()


func _update_tts_section_enabled() -> void:
	if not _voice_tab:
		return
	var cfg := SingletonObject.get_voice_config()
	var tts_enabled := cfg.tts_provider != VoiceConfig.TTSProvider.NONE
	var core_connected: bool = Core.client._connected

	# TTS controls need both TTS enabled AND Core connected (Voice Service requires Core)
	var tts_usable := tts_enabled and core_connected
	_tts_backend_option.disabled = not tts_usable
	_voice_selector.disabled = not tts_usable
	_voice_preview_btn.disabled = not tts_usable
	_voice_refresh_btn.disabled = not core_connected
	_tts_volume_slider.editable = tts_enabled
	_speak_mode_option.disabled = not tts_enabled

	# Update status label based on connection
	if not core_connected:
		_voice_status_label.text = "Voice service: Core not connected"
	elif _voices_cache.is_empty():
		_voice_status_label.text = "Voice service: click Refresh to load voices"


## Called when Core connects or disconnects — updates Voice tab enabled state.
func _on_core_connection_changed(_connected: bool) -> void:
	if not _voice_tab:
		return
	_update_tts_section_enabled()


func _on_stt_provider_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.stt_provider = _stt_provider_option.get_item_id(idx)
	var is_voice_service: bool = cfg.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE
	_whisper_fallback_check.visible = is_voice_service
	_stt_backend_option.disabled = not is_voice_service
	cfg.save()


func _on_stt_backend_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	match idx:
		0: cfg.stt_backend = "faster-whisper"
		1: cfg.stt_backend = "qwen3-asr"
	cfg.save()


func _on_tts_provider_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.tts_provider = _tts_provider_option.get_item_id(idx)
	_update_tts_section_enabled()
	cfg.save()


func _on_tts_backend_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	match idx:
		0: cfg.tts_backend = ""
		1: cfg.tts_backend = "kokoro"
		2: cfg.tts_backend = "qwen3-base"
		3: cfg.tts_backend = "qwen3-customvoice"
		4: cfg.tts_backend = "gpt-sovits"
	cfg.save()
	# Refresh voice list for new backend
	_on_voice_refresh_pressed()


func _on_voice_selected(idx: int) -> void:
	if idx < 0 or idx >= _voices_cache.size():
		return
	var cfg := SingletonObject.get_voice_config()
	var voice: Dictionary = _voices_cache[idx]
	cfg.voice_id = voice.get("id", "")
	cfg.voice_name = voice.get("name", voice.get("id", ""))
	cfg.save()


func _on_whisper_fallback_toggled(enabled: bool) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.whisper_fallback = enabled
	cfg.save()


func _on_speak_mode_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.speak_mode = _speak_mode_option.get_item_id(idx)
	_update_summary_controls_visible()
	if cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE:
		_populate_summary_models()
	cfg.save()


func _on_summary_model_changed(idx: int) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.summary_model = _summary_model_option.get_item_text(idx)
	cfg.save()


func _on_summary_timeout_changed(value: float) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.summary_timeout = value
	cfg.save()


func _update_summary_controls_visible() -> void:
	var cfg := SingletonObject.get_voice_config()
	var show: bool = cfg.speak_mode == VoiceConfig.SpeakMode.SUMMARIZE
	_summary_model_row.visible = show
	_summary_timeout_row.visible = show


func _populate_summary_models() -> void:
	_summary_model_option.clear()
	var cfg := SingletonObject.get_voice_config()

	# Find model-chat service and list its actions as available models
	for svc in Core.services:
		if svc.client_id == "model-chat":
			for act in svc.actions:
				_summary_model_option.add_item(act.name)
			break

	# Select the saved model if present
	if not cfg.summary_model.is_empty():
		for i in _summary_model_option.item_count:
			if _summary_model_option.get_item_text(i) == cfg.summary_model:
				_summary_model_option.select(i)
				return

	# If no saved model or not found, select first and save it
	if _summary_model_option.item_count > 0:
		_summary_model_option.select(0)
		cfg.summary_model = _summary_model_option.get_item_text(0)


func _on_auto_send_toggled(enabled: bool) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.auto_send_transcription = enabled
	cfg.save()


func _on_stt_model_changed(idx: int) -> void:
	var models := ["tiny.en", "small.en", "medium.en", "large-v3-turbo", "distil-large-v3"]
	var cfg := SingletonObject.get_voice_config()
	cfg.stt_model = models[idx] if idx < models.size() else "small.en"
	cfg.save()


func _on_vad_silence_changed(value: float) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.vad_silence_duration = value
	cfg.save()
	if _vad_silence_value_label:
		_vad_silence_value_label.text = "%.1fs" % value
	# Update running gateway if connected
	if SingletonObject.Chats and is_instance_valid(SingletonObject.Chats):
		var gateway: Node = SingletonObject.Chats._voice_gateway
		if gateway and gateway._connected:
			gateway._send_gateway_config()


func _on_tts_volume_changed(value: float) -> void:
	var cfg := SingletonObject.get_voice_config()
	cfg.tts_volume = value
	cfg.save()


func _on_voice_refresh_pressed() -> void:
	if not Core.client._connected:
		_voice_status_label.text = "Voice service status: Core not connected"
		return

	_voice_refresh_btn.disabled = true
	_voice_refresh_btn.text = "Loading..."

	var client := SingletonObject.get_voice_client()
	var cfg := SingletonObject.get_voice_config()
	var backend_filter: String = cfg.tts_backend

	var voices: Array = await client.list_voices(backend_filter)

	_voices_cache = voices
	_voice_selector.clear()

	if voices.is_empty():
		_voice_selector.add_item("(no voices available)")
		_voice_selector.disabled = true
	else:
		var selected_idx := 0
		for i in voices.size():
			var v: Dictionary = voices[i]
			var display: String = v.get("name", v.get("id", "unknown"))
			var backend_family: String = v.get("backend_family", "")
			if not backend_family.is_empty():
				display += " (%s)" % backend_family
			_voice_selector.add_item(display)
			if v.get("id", "") == cfg.voice_id:
				selected_idx = i
		_voice_selector.select(selected_idx)
		_voice_selector.disabled = false
		# Update config if selection changed
		if selected_idx < voices.size():
			cfg.voice_id = voices[selected_idx].get("id", "")
			cfg.voice_name = voices[selected_idx].get("name", "")
			cfg.save()

	_voice_refresh_btn.disabled = false
	_voice_refresh_btn.text = "Refresh"
	_voice_status_label.text = "Voice service: %d voices loaded" % voices.size()


func _on_voice_preview_pressed() -> void:
	var cfg := SingletonObject.get_voice_config()
	if cfg.voice_id.is_empty():
		_voice_status_label.text = "Select a voice first"
		return

	if not Core.client._connected:
		_voice_status_label.text = "Core not connected — cannot preview"
		return

	_voice_preview_btn.disabled = true
	_voice_preview_btn.text = "Playing..."
	_voice_status_label.text = "Generating preview..."

	var client := SingletonObject.get_voice_client()
	var voice: String = cfg.voice_name if not cfg.voice_name.is_empty() else cfg.voice_id
	var wav_data: PackedByteArray = await client.synthesize(
		"Hello! This is a preview of the selected voice.",
		voice,
		cfg.tts_backend
	)

	if wav_data.is_empty():
		_voice_status_label.text = "Preview failed — check voice service"
		_voice_preview_btn.disabled = false
		_voice_preview_btn.text = "Preview"
		return

	# Play the WAV audio
	print("[Preview] WAV data: %d bytes, header: %s" % [wav_data.size(), wav_data.slice(0, 4).get_string_from_ascii()])
	var stream := AudioStreamWAV.new()
	VoiceServiceClient.load_audio_into_stream(stream, wav_data)
	print("[Preview] Stream: rate=%d, stereo=%s, format=%d, data=%d bytes" % [stream.mix_rate, stream.stereo, stream.format, stream.data.size()])

	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = linear_to_db(cfg.tts_volume)
	add_child(player)
	player.play()
	player.finished.connect(func(): player.queue_free())

	_voice_status_label.text = "Playing preview..."
	_voice_preview_btn.disabled = false
	_voice_preview_btn.text = "Preview"


func _on_voice_status_pressed() -> void:
	if not Core.client._connected:
		_voice_status_label.text = "Voice service status: Core not connected"
		return

	_voice_status_label.text = "Checking..."
	var client := SingletonObject.get_voice_client()
	var status: Dictionary = await client.get_status()

	if status.has("error"):
		_voice_status_label.text = "Voice service: %s" % status["error"]
	else:
		_voice_status_label.text = "Voice service: online"


## Load raw WAV bytes into an AudioStreamWAV resource.
#endregion Voice Tab

#region Containers Tab

const DockerManagerScript = preload("res://Scripts/Services/Docker/DockerManager.gd")
const ContainerDefScript = preload("res://Scripts/Services/Docker/ContainerDefinition.gd")

var _containers_tab: VBoxContainer
var _docker_status_label: Label
var _container_cards_vbox: VBoxContainer
var _docker_recheck_btn: Button
var _build_poll_timer: Timer
var _build_log_label: Label

func _create_containers_tab() -> void:
	var tab_container = get_node("MarginContainer/VBoxContainer/TabContainer")
	if not tab_container:
		return

	_containers_tab = VBoxContainer.new()
	_containers_tab.name = "Containers"

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_containers_tab.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# --- Docker Status Section ---
	var docker_header := Label.new()
	docker_header.text = "Docker Status"
	docker_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(docker_header)

	_docker_status_label = Label.new()
	_docker_status_label.text = "Checking..."
	_docker_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_docker_status_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	_docker_recheck_btn = Button.new()
	_docker_recheck_btn.text = "Re-check Docker"
	_docker_recheck_btn.pressed.connect(_on_docker_recheck)
	btn_row.add_child(_docker_recheck_btn)

	vbox.add_child(HSeparator.new())

	# --- Managed Containers Section ---
	var containers_header := Label.new()
	containers_header.text = "Managed Containers"
	containers_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(containers_header)

	_container_cards_vbox = VBoxContainer.new()
	_container_cards_vbox.add_theme_constant_override("separation", 12)
	vbox.add_child(_container_cards_vbox)

	# Add Container button
	var add_btn := Button.new()
	add_btn.text = "+ Add Container"
	add_btn.pressed.connect(_on_add_container_pressed)
	vbox.add_child(add_btn)

	# Build log area (shown during builds)
	_build_log_label = Label.new()
	_build_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_log_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_build_log_label.add_theme_font_size_override("font_size", 11)
	_build_log_label.visible = false
	vbox.add_child(_build_log_label)

	# Poll timer for build progress (1s interval)
	_build_poll_timer = Timer.new()
	_build_poll_timer.wait_time = 1.0
	_build_poll_timer.timeout.connect(_on_build_poll)
	_containers_tab.add_child(_build_poll_timer)

	tab_container.add_child(_containers_tab)

	# Run initial detection
	_refresh_docker_status()


func _refresh_docker_status() -> void:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	var status: Dictionary = manager.detect()
	_update_docker_status_ui(status)
	_rebuild_container_cards()


func _update_docker_status_ui(status: Dictionary) -> void:
	if not _docker_status_label:
		return

	if status.get("available", false):
		var runtime: String = status.get("runtime", "unknown")
		var version: String = status.get("version", "")
		var gpu: String = "GPU available" if status.get("gpu_available", false) else "CPU only"
		_docker_status_label.text = "Docker %s (%s, %s)" % [version, runtime, gpu]
		_docker_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
	else:
		var error: String = status.get("error", "Docker not found")
		_docker_status_label.text = error
		_docker_status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))


func _rebuild_container_cards() -> void:
	if not _container_cards_vbox:
		return

	# Clear existing cards
	for child in _container_cards_vbox.get_children():
		child.queue_free()

	var manager: RefCounted = SingletonObject.get_docker_manager()
	var definitions: Array = manager.get_definitions()

	if definitions.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No containers registered. Enable features that require containers (e.g., Voice Gateway)."
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_container_cards_vbox.add_child(empty_label)
		return

	for definition in definitions:
		var card := _create_container_card(definition)
		_container_cards_vbox.add_child(card)


func _create_container_card(definition: Resource) -> PanelContainer:
	var panel := PanelContainer.new()

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	# Left: info
	var info_vbox := VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_vbox)

	var name_label := Label.new()
	name_label.text = definition.display_name
	name_label.add_theme_font_size_override("font_size", 14)
	info_vbox.add_child(name_label)

	var manager: RefCounted = SingletonObject.get_docker_manager()
	var state: String = manager.get_state(definition)
	var state_label: Label = Label.new()
	state_label.name = "StateLabel"
	_apply_state_style(state_label, state)
	info_vbox.add_child(state_label)

	var image_label := Label.new()
	image_label.text = "Image: %s" % definition.image_name
	image_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	image_label.add_theme_font_size_override("font_size", 12)
	info_vbox.add_child(image_label)

	# Right: buttons
	var btn_vbox := VBoxContainer.new()
	btn_vbox.add_theme_constant_override("separation", 4)
	hbox.add_child(btn_vbox)

	var has_image: bool = manager.is_image_built(definition)

	if not has_image:
		var build_btn: Button = Button.new()
		build_btn.text = "Build"
		build_btn.pressed.connect(_on_build_pressed.bind(definition))
		btn_vbox.add_child(build_btn)
	else:
		var is_running: bool = manager.is_running(definition)
		var toggle_btn := Button.new()
		toggle_btn.text = "Stop" if is_running else "Start"
		toggle_btn.pressed.connect(_on_toggle_pressed.bind(definition))
		btn_vbox.add_child(toggle_btn)

		var rebuild_btn := Button.new()
		rebuild_btn.text = "Rebuild"
		rebuild_btn.pressed.connect(_on_build_pressed.bind(definition))
		btn_vbox.add_child(rebuild_btn)

	# Remove button (custom containers only)
	if not manager.is_builtin(definition):
		var remove_btn := Button.new()
		remove_btn.text = "Remove"
		remove_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		remove_btn.pressed.connect(_on_remove_pressed.bind(definition))
		btn_vbox.add_child(remove_btn)

	return panel


func _apply_state_style(label: Label, state: String) -> void:
	match state:
		"running":
			label.text = "Running"
			label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		"building":
			label.text = "Building..."
			label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
		"error":
			label.text = "Error"
			label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		_:
			label.text = "Stopped"
			label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


func _on_docker_recheck() -> void:
	_docker_status_label.text = "Checking..."
	_refresh_docker_status()


func _on_build_pressed(definition: Resource) -> void:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	if manager.build_image(definition):
		_rebuild_container_cards()
		# Start polling for build progress
		if _build_log_label:
			_build_log_label.text = "Building %s..." % definition.display_name
			_build_log_label.visible = true
		if _build_poll_timer:
			_build_poll_timer.start()


func _on_toggle_pressed(definition: Resource) -> void:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	if manager.is_running(definition):
		manager.stop_container(definition)
	else:
		manager.start_container(definition)
	_rebuild_container_cards()

func _on_remove_pressed(definition: Resource) -> void:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	manager.remove_container(definition)
	_rebuild_container_cards()


func _on_add_container_pressed() -> void:
	# Create a popup dialog for adding a new container
	var dialog := AcceptDialog.new()
	dialog.title = "Add Container"
	dialog.min_size = Vector2(500, 400)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 6)

	var fields: Dictionary = {}

	# Display Name
	var name_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "Display Name:"
	name_lbl.custom_minimum_size = Vector2(120, 0)
	name_row.add_child(name_lbl)
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "My Container"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	form.add_child(name_row)
	fields["display_name"] = name_edit

	# Image Name
	var img_row := HBoxContainer.new()
	var img_lbl := Label.new()
	img_lbl.text = "Image Name:"
	img_lbl.custom_minimum_size = Vector2(120, 0)
	img_row.add_child(img_lbl)
	var img_edit := LineEdit.new()
	img_edit.placeholder_text = "my-container"
	img_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img_row.add_child(img_edit)
	form.add_child(img_row)
	fields["image_name"] = img_edit

	# Dockerfile Path
	var df_row := HBoxContainer.new()
	var df_lbl := Label.new()
	df_lbl.text = "Dockerfile:"
	df_lbl.custom_minimum_size = Vector2(120, 0)
	df_row.add_child(df_lbl)
	var df_edit := LineEdit.new()
	df_edit.placeholder_text = "/path/to/Dockerfile"
	df_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	df_row.add_child(df_edit)
	form.add_child(df_row)
	fields["dockerfile_path"] = df_edit

	# Build Context
	var ctx_row := HBoxContainer.new()
	var ctx_lbl := Label.new()
	ctx_lbl.text = "Build Context:"
	ctx_lbl.custom_minimum_size = Vector2(120, 0)
	ctx_row.add_child(ctx_lbl)
	var ctx_edit := LineEdit.new()
	ctx_edit.placeholder_text = "/path/to/context/ (directory with Dockerfile)"
	ctx_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctx_row.add_child(ctx_edit)
	form.add_child(ctx_row)
	fields["build_context"] = ctx_edit

	# Port (simple: one host:container pair)
	var port_row := HBoxContainer.new()
	var port_lbl := Label.new()
	port_lbl.text = "Port (host:ctr):"
	port_lbl.custom_minimum_size = Vector2(120, 0)
	port_row.add_child(port_lbl)
	var port_edit := LineEdit.new()
	port_edit.placeholder_text = "8080:8080"
	port_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	port_row.add_child(port_edit)
	form.add_child(port_row)
	fields["port"] = port_edit

	# Health Endpoint
	var health_row := HBoxContainer.new()
	var health_lbl := Label.new()
	health_lbl.text = "Health URL:"
	health_lbl.custom_minimum_size = Vector2(120, 0)
	health_row.add_child(health_lbl)
	var health_edit := LineEdit.new()
	health_edit.placeholder_text = "http://localhost:8080/health (optional)"
	health_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	health_row.add_child(health_edit)
	form.add_child(health_row)
	fields["health_endpoint"] = health_edit

	# GPU optional
	var gpu_check := CheckButton.new()
	gpu_check.text = "Request GPU if available"
	form.add_child(gpu_check)
	fields["gpu_optional"] = gpu_check

	dialog.add_child(form)

	dialog.confirmed.connect(func():
		var dn: String = fields["display_name"].text.strip_edges()
		var img: String = fields["image_name"].text.strip_edges()
		var df: String = fields["dockerfile_path"].text.strip_edges()
		var ctx: String = fields["build_context"].text.strip_edges()
		var hp: String = fields["health_endpoint"].text.strip_edges()
		var gpu: bool = fields["gpu_optional"].button_pressed

		if img == "":
			return  # Need at least image name

		# Parse port
		var ports: Dictionary = {}
		var port_str: String = fields["port"].text.strip_edges()
		if ":" in port_str:
			var parts: PackedStringArray = port_str.split(":")
			if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
				ports[parts[0].to_int()] = parts[1].to_int()

		if dn == "":
			dn = img

		if ctx == "" and df != "":
			ctx = df.get_base_dir()

		var manager: RefCounted = SingletonObject.get_docker_manager()
		manager.register_custom(dn, img, df, ctx, ports, hp, gpu)
		_rebuild_container_cards()
		dialog.queue_free()
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)

	add_child(dialog)
	dialog.popup_centered()


func _on_build_poll() -> void:
	var manager: RefCounted = SingletonObject.get_docker_manager()
	var any_building := false

	for def in manager.get_definitions():
		if manager.get_state(def) == "building":
			any_building = true
			var still_going: bool = manager.poll_build(def)
			if not still_going:
				# Build finished — refresh cards and show result
				_rebuild_container_cards()
				if _build_log_label:
					var state: String = manager.get_state(def)
					if state == "error":
						_build_log_label.text = "Build failed for %s. Check log." % def.display_name
						_build_log_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
					else:
						_build_log_label.text = "Build complete: %s" % def.display_name
						_build_log_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))

	if not any_building and _build_poll_timer:
		_build_poll_timer.stop()

#endregion Containers Tab
