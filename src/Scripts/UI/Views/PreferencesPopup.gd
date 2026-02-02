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
