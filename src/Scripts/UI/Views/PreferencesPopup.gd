class_name PreferencesPopup
extends PersistentWindow


@onready var output_device_button: OptionButton = %OutputDeviceButton

@onready var connection_label: Label = %ConnectionLabel
@onready var connection_texture_rect: TextureRect = %ConnectionTextureRect
@onready var connect_button: Button = %CoreConnetButton
@onready var service_selection_window: ServiceSelection = %ServiceSelection

@onready var core_error_item_list: ItemList = %CoreErrorItemList
@onready var hcp_password: LineEdit = %lePassword
@onready var hcp_username: LineEdit = %leUsername
@onready var hcp_url: LineEdit = %leCoreUrl
@onready var hcp_logs_window: PersistentWindow = %HcpLogs

# maps API_PROVIDERs to their config file field name
const PROVIDERS = {
	SingletonObject.API_PROVIDER.OPENAI: "openai",
	SingletonObject.API_PROVIDER.ANTHROPIC: "anthropic",
	SingletonObject.API_PROVIDER.GOOGLE: "google_vertex",
}

@onready var _fields = {
	"first_name": %leFirstName,
	"last_name": %leLastName,

	"google_vertex": %leGoogleVertex,
	"anthropic": %leAnthropic,
	"openai": %leOpenAI,

	"hcp_auto_connect": %leConnectAuto,
	"hcp_url": %leCoreUrl,
	"hcp_username": %leUsername,
	"hcp_password": %lePassword,
}

@onready var theme_option_button: OptionButton = %ThemeOptionButton
@onready var microphones: OptionButton = %Microphones


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

			config_file.set_value("USER", "first_name", "Not")
			config_file.set_value("USER", "last_name", "Available")
	set_field_values()
	
	SingletonObject.theme_changed.connect(set_theme_option_menu)
	theme_option_button.selected = SingletonObject.get_theme_enum()
	
	SingletonObject.mic_changed.connect(set_microphone_option_menu)
	set_microphone_option_menu(SingletonObject.get_microphone())
	
	if SingletonObject.config_has_saved_section("Experimental"):
		var enable_exp: bool = SingletonObject.config_file.get_value("Experimental", "enabled")
		_on_experimental_check_button_toggled(enable_exp)
		%ExperimentalCheckButton.button_pressed = enable_exp
	
	populate_output_devices_button()

	# core tab stuff
	Core.client.connection_established.connect(
		func():
			connection_label.text = "You are connected to core"
			connection_texture_rect.texture = preload("res://.godot/imported/check_mark16.webp-ee4b5638509d469382c7cad2d0cf364b.ctex")
			connect_button.disabled = true
	)

	Core.client.connection_error.connect(
		func(error: int):
			connection_label.text = "Error while trying to connect to core (%s)" % error_string(error)
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.disabled = false
	)

	Core.client.connection_closed.connect(
		func():
			connection_label.text = "You are not connected to core"
			connection_texture_rect.texture = preload("res://.godot/imported/close.svg-a39d6ec6a963366ce69cbdb73008bf4d.ctex")
			connect_button.disabled = false
	)


func set_field_values():
	_fields["first_name"].text = config_file.get_value("USER", "first_name", "Not")
	_fields["last_name"].text = config_file.get_value("USER", "last_name", "Available")
	
	_fields["google_vertex"].text = config_file.get_value("API KEYS", "google_vertex", "")
	_fields["anthropic"].text = config_file.get_value("API KEYS", "anthropic", "")
	_fields["openai"].text = config_file.get_value("API KEYS", "openai", "")

	_fields["hcp_url"].text = config_file.get_value("HCP", "url", "")
	_fields["hcp_auto_connect"].button_pressed = config_file.get_value("HCP", "auto_connect", false)
	_fields["hcp_username"].text = config_file.get_value("HCP", "username", "")
	_fields["hcp_password"].text = config_file.get_value("HCP", "password", "")



func _on_btn_save_prefs_pressed():
	config_file.set_value("USER", "first_name", _fields["first_name"].text)
	config_file.set_value("USER", "last_name", _fields["last_name"].text)

	config_file.set_value("API KEYS", "google_vertex", _fields["google_vertex"].text)
	config_file.set_value("API KEYS", "anthropic", _fields["anthropic"].text)
	config_file.set_value("API KEYS", "openai", _fields["openai"].text)

	config_file.set_value("HCP", "url", _fields["hcp_url"].text)
	config_file.set_value("HCP", "username", _fields["hcp_username"].text)
	config_file.set_value("HCP", "password", _fields["hcp_password"].text)
	config_file.set_value("HCP", "auto_connect", _fields["hcp_auto_connect"].button_pressed)
	
	config_file.save_encrypted_pass("user://Preferences.agent", OS.get_unique_id())
	
	hide()

func _on_about_to_popup():
	set_field_values()	
	theme_option_button.selected = SingletonObject.get_theme_enum()
	set_microphone_option_menu(SingletonObject.get_microphone())
	populate_output_devices_button()

func get_api_key(provider: SingletonObject.API_PROVIDER) -> String:
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
	# Experimental Features are stored as "Experimental" in config file and there is a global group label
	%View.set_item_disabled(3, !toggled_on)
	for node in get_tree().get_nodes_in_group("Experimental"):
		if node is Control:
			node.visible = toggled_on
		if node is Button:
			node.disabled = !toggled_on
	SingletonObject.toggle_experimental.emit(toggled_on)


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


func _on_core_connet_button_pressed() -> void:
	var connected: = await Core.start(
		hcp_url.text,
		hcp_username.text,
		hcp_password.text,
	)

	print("Core connection on url: ", hcp_url.text)
	print(connected)

	if connected:
		var msg_received: = (
			Core
				.await_message()
				.with_cmd("error")
				.with_topic("system")
				.receive_all()
		)

		msg_received.connect(
			func(msg: Dictionary):
				var err: String

				if msg["params"].has("error_code"):
					err = "%s: %s" % [msg["params"]["error_code"], msg["params"]["error"]]
				else:
					err = msg["params"]["error"]
				
				core_error_item_list.add_item(
					err,
					preload("res://.godot/imported/warning_icon.svg-0d14ac513b8003b886b4926b52005686.ctex"),
					false
				)
		)


func _on_select_services_button_pressed() -> void:
	var services: = await Core.fetch_services()

	service_selection_window.set_services(services)
	
	service_selection_window.popup_centered()

var selected_service: Service
var selected_action: Action

func _on_service_selection_service_selected(service: Service, action: Action) -> void:
	selected_service = service
	selected_action = action

	Core.service_selected.emit(service, action)


func _on_password_checkbox_toggled(toggled_on:bool) -> void:
	hcp_password.secret = not toggled_on


func _on_hcp_logs_button_pressed() -> void:
	hcp_logs_window.popup_centered()
