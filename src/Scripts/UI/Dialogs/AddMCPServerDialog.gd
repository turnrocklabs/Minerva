class_name AddMCPServerDialog
extends AcceptDialog
## Dialog for adding user-defined MCP servers at runtime.
## Supports HTTP, WebSocket, and STDIO transports.

signal server_added(config: Dictionary)

var _name_edit: LineEdit
var _type_option: OptionButton
var _url_container: VBoxContainer
var _stdio_container: VBoxContainer
var _url_edit: LineEdit
var _port_spin: SpinBox
var _mcp_endpoint_edit: LineEdit
var _command_edit: LineEdit
var _args_edit: LineEdit
var _working_dir_edit: LineEdit
var _auto_connect_check: CheckButton
var _persist_check: CheckButton
var _error_label: Label
var _test_btn: Button
var _test_status: Label


func _init() -> void:
	title = "Add MCP Server"
	min_size = Vector2i(450, 0)
	ok_button_text = "Add"
	add_cancel_button("Cancel")

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# Name
	var name_label := Label.new()
	name_label.text = "Server Name (unique identifier):"
	vbox.add_child(name_label)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "e.g., my-server"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_name_edit)

	# Transport type
	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 8)
	vbox.add_child(type_row)

	var type_label := Label.new()
	type_label.text = "Transport:"
	type_label.custom_minimum_size = Vector2(80, 0)
	type_row.add_child(type_label)

	_type_option = OptionButton.new()
	_type_option.add_item("HTTP", 0)
	_type_option.add_item("WebSocket", 1)
	_type_option.add_item("STDIO", 2)
	_type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_type_option.item_selected.connect(_on_type_changed)
	type_row.add_child(_type_option)

	vbox.add_child(HSeparator.new())

	# --- URL-based fields (HTTP / WebSocket) ---
	_url_container = VBoxContainer.new()
	_url_container.add_theme_constant_override("separation", 6)
	vbox.add_child(_url_container)

	var url_label := Label.new()
	url_label.text = "Server URL:"
	_url_container.add_child(url_label)

	var url_hbox := HBoxContainer.new()
	url_hbox.add_theme_constant_override("separation", 4)
	_url_container.add_child(url_hbox)

	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "http://localhost"
	_url_edit.text = "http://localhost"
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_hbox.add_child(_url_edit)

	var port_label := Label.new()
	port_label.text = ":"
	url_hbox.add_child(port_label)

	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.value = 8080
	url_hbox.add_child(_port_spin)

	# MCP endpoint
	var endpoint_row := HBoxContainer.new()
	endpoint_row.add_theme_constant_override("separation", 4)
	_url_container.add_child(endpoint_row)

	var endpoint_label := Label.new()
	endpoint_label.text = "MCP endpoint:"
	endpoint_label.custom_minimum_size = Vector2(100, 0)
	endpoint_row.add_child(endpoint_label)

	_mcp_endpoint_edit = LineEdit.new()
	_mcp_endpoint_edit.text = "/mcp"
	_mcp_endpoint_edit.placeholder_text = "/mcp"
	_mcp_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	endpoint_row.add_child(_mcp_endpoint_edit)

	# --- STDIO fields ---
	_stdio_container = VBoxContainer.new()
	_stdio_container.add_theme_constant_override("separation", 6)
	_stdio_container.visible = false
	vbox.add_child(_stdio_container)

	var cmd_label := Label.new()
	cmd_label.text = "Command:"
	_stdio_container.add_child(cmd_label)

	_command_edit = LineEdit.new()
	_command_edit.placeholder_text = "/path/to/mcp-server"
	_command_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stdio_container.add_child(_command_edit)

	var args_label := Label.new()
	args_label.text = "Arguments (space-separated):"
	_stdio_container.add_child(args_label)

	_args_edit = LineEdit.new()
	_args_edit.placeholder_text = "--port 8080 --verbose"
	_args_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stdio_container.add_child(_args_edit)

	var dir_label := Label.new()
	dir_label.text = "Working directory (optional):"
	_stdio_container.add_child(dir_label)

	_working_dir_edit = LineEdit.new()
	_working_dir_edit.placeholder_text = "/path/to/working/dir"
	_working_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stdio_container.add_child(_working_dir_edit)

	# --- Options ---
	vbox.add_child(HSeparator.new())

	_auto_connect_check = CheckButton.new()
	_auto_connect_check.text = "Auto-connect on startup"
	_auto_connect_check.button_pressed = false
	vbox.add_child(_auto_connect_check)

	_persist_check = CheckButton.new()
	_persist_check.text = "Remember across sessions"
	_persist_check.button_pressed = true
	vbox.add_child(_persist_check)

	# --- Test connection ---
	vbox.add_child(HSeparator.new())

	var test_row := HBoxContainer.new()
	test_row.add_theme_constant_override("separation", 8)
	vbox.add_child(test_row)

	_test_btn = Button.new()
	_test_btn.text = "Test Connection"
	_test_btn.pressed.connect(_on_test_pressed)
	test_row.add_child(_test_btn)

	_test_status = Label.new()
	_test_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	test_row.add_child(_test_status)

	# Error label
	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	vbox.add_child(_error_label)

	confirmed.connect(_on_confirmed)


func _on_type_changed(idx: int) -> void:
	var is_stdio := idx == 2
	_url_container.visible = not is_stdio
	_stdio_container.visible = is_stdio
	_test_status.text = ""
	_error_label.visible = false

	# Update URL placeholder based on transport
	if idx == 0:  # HTTP
		_url_edit.placeholder_text = "http://localhost"
		if _url_edit.text.begins_with("ws"):
			_url_edit.text = "http://localhost"
	elif idx == 1:  # WebSocket
		_url_edit.placeholder_text = "ws://localhost"
		if _url_edit.text.begins_with("http"):
			_url_edit.text = "ws://localhost"


func _get_transport_type() -> String:
	match _type_option.selected:
		1: return "websocket"
		2: return "stdio"
		_: return "http"


func _on_confirmed() -> void:
	var server_name := _name_edit.text.strip_edges().to_lower()
	var transport := _get_transport_type()

	# Common validation
	if server_name.is_empty():
		_show_error("Server name is required.")
		return

	if server_name.begins_with("minerva"):
		_show_error("Server names starting with 'minerva' are reserved.")
		return

	if MCPKnownServers.is_known(server_name):
		_show_error("'%s' is a known server name. Use a different name." % server_name)
		return

	# Check for duplicate against existing config
	var mcp = SingletonObject.mcp_manager
	if mcp and mcp.config.get_server(server_name):
		_show_error("A server named '%s' already exists." % server_name)
		return

	var config_data := {
		"name": server_name,
		"type": transport,
		"auto_connect": _auto_connect_check.button_pressed,
		"persistent": _persist_check.button_pressed,
		"origin": "user",
	}

	if transport == "stdio":
		var cmd := _command_edit.text.strip_edges()
		if cmd.is_empty():
			_show_error("Command is required for STDIO servers.")
			return
		config_data["command"] = cmd
		var args_text := _args_edit.text.strip_edges()
		if not args_text.is_empty():
			config_data["args"] = args_text.split(" ", false)
		else:
			config_data["args"] = []
		var wd := _working_dir_edit.text.strip_edges()
		if not wd.is_empty():
			config_data["working_directory"] = wd
	else:
		var url := _url_edit.text.strip_edges()
		var port := int(_port_spin.value)

		if transport == "http":
			if not url.begins_with("http://") and not url.begins_with("https://"):
				_show_error("URL must start with http:// or https://")
				return
		elif transport == "websocket":
			if not url.begins_with("ws://") and not url.begins_with("wss://"):
				_show_error("URL must start with ws:// or wss://")
				return

		config_data["url"] = "%s:%d" % [url, port]
		var endpoint := _mcp_endpoint_edit.text.strip_edges()
		if not endpoint.is_empty():
			config_data["mcp_endpoint"] = endpoint

	server_added.emit(config_data)
	hide()


func _on_test_pressed() -> void:
	var transport := _get_transport_type()

	if transport == "stdio":
		var cmd := _command_edit.text.strip_edges()
		if cmd.is_empty():
			_test_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			_test_status.text = "Enter a command first."
			return
		if not FileAccess.file_exists(cmd):
			_test_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			_test_status.text = "Command not found: %s" % cmd
			return
		_test_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		_test_status.text = "Command exists."
		return

	# HTTP / WebSocket — try a quick connection test
	var url := _url_edit.text.strip_edges()
	var port := int(_port_spin.value)
	var full_url := "%s:%d" % [url, port]

	if transport == "http":
		var endpoint := _mcp_endpoint_edit.text.strip_edges()
		if endpoint.is_empty():
			endpoint = "/mcp"
		var test_url := full_url + endpoint
		_test_status.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
		_test_status.text = "Testing..."
		_test_btn.disabled = true

		var http := HTTPRequest.new()
		add_child(http)
		http.timeout = 5.0
		http.request_completed.connect(_on_test_http_complete.bind(http))
		var err := http.request(test_url, [], HTTPClient.METHOD_GET)
		if err != OK:
			_test_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			_test_status.text = "Request failed: %s" % error_string(err)
			_test_btn.disabled = false
			http.queue_free()
	else:
		# WebSocket — just validate the URL format
		if not url.begins_with("ws://") and not url.begins_with("wss://"):
			_test_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			_test_status.text = "Invalid WebSocket URL."
			return
		_test_status.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
		_test_status.text = "URL format valid. Will test on connect."


func _on_test_http_complete(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	_test_btn.disabled = false

	if result != HTTPRequest.RESULT_SUCCESS:
		_test_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		match result:
			HTTPRequest.RESULT_CANT_CONNECT:
				_test_status.text = "Cannot connect to server."
			HTTPRequest.RESULT_CANT_RESOLVE:
				_test_status.text = "Cannot resolve hostname."
			HTTPRequest.RESULT_TIMEOUT:
				_test_status.text = "Connection timed out."
			_:
				_test_status.text = "Connection failed (code %d)." % result
		return

	_test_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	_test_status.text = "Reachable (HTTP %d)." % response_code


func _show_error(msg: String) -> void:
	_error_label.text = msg
	_error_label.visible = true


## Reset fields for reuse
func reset() -> void:
	_name_edit.text = ""
	_type_option.select(0)
	_url_edit.text = "http://localhost"
	_port_spin.value = 8080
	_mcp_endpoint_edit.text = "/mcp"
	_command_edit.text = ""
	_args_edit.text = ""
	_working_dir_edit.text = ""
	_auto_connect_check.button_pressed = false
	_persist_check.button_pressed = true
	_test_status.text = ""
	_error_label.visible = false
	_url_container.visible = true
	_stdio_container.visible = false
