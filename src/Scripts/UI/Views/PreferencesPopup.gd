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


## Sync provider checkbox states with SingletonObject enabled state
func _sync_provider_checkboxes() -> void:
	for provider in _provider_checkbuttons:
		var checkbox: CheckButton = _provider_checkbuttons[provider]
		if checkbox:
			checkbox.set_pressed_no_signal(SingletonObject.is_provider_enabled(provider))

func get_api_key(provider: SingletonObject.API_PROVIDER) -> String:
	if provider == SingletonObject.API_PROVIDER.LOCAL:
		return " "
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

#endregion Provider toggles
