class_name AddMCPServerDialog
extends AcceptDialog
## Dialog for adding user-defined MCP servers at runtime.
## Phase 1: HTTP only. WS/STDIO support deferred to Phase 2.

signal server_added(config: Dictionary)

var _name_edit: LineEdit
var _url_edit: LineEdit
var _port_spin: SpinBox
var _auto_connect_check: CheckButton
var _persist_check: CheckButton
var _error_label: Label


func _init() -> void:
	title = "Add MCP Server"
	min_size = Vector2i(400, 300)
	ok_button_text = "Add"
	add_cancel_button("Cancel")

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Name
	var name_label := Label.new()
	name_label.text = "Server Name (unique identifier):"
	vbox.add_child(name_label)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "e.g., my-server"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_name_edit)

	# URL
	var url_label := Label.new()
	url_label.text = "Server URL:"
	vbox.add_child(url_label)

	var url_hbox := HBoxContainer.new()
	url_hbox.add_theme_constant_override("separation", 4)
	vbox.add_child(url_hbox)

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

	# Options
	vbox.add_child(HSeparator.new())

	_auto_connect_check = CheckButton.new()
	_auto_connect_check.text = "Auto-connect on startup"
	_auto_connect_check.button_pressed = false
	vbox.add_child(_auto_connect_check)

	_persist_check = CheckButton.new()
	_persist_check.text = "Remember across sessions"
	_persist_check.button_pressed = true
	vbox.add_child(_persist_check)

	# Error label
	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	vbox.add_child(_error_label)

	confirmed.connect(_on_confirmed)


func _on_confirmed() -> void:
	var server_name := _name_edit.text.strip_edges().to_lower()
	var url := _url_edit.text.strip_edges()
	var port := int(_port_spin.value)

	# Validation
	if server_name.is_empty():
		_show_error("Server name is required.")
		return

	if server_name.begins_with("minerva"):
		_show_error("Server names starting with 'minerva' are reserved.")
		return

	if not url.begins_with("http://") and not url.begins_with("https://"):
		_show_error("URL must start with http:// or https://")
		return

	# Check for name collision with known servers
	if MCPKnownServers.is_known(server_name):
		_show_error("'%s' is a known server name. Use a different name." % server_name)
		return

	var full_url := "%s:%d" % [url, port]

	server_added.emit({
		"name": server_name,
		"type": "http",
		"url": full_url,
		"auto_connect": _auto_connect_check.button_pressed,
		"persistent": _persist_check.button_pressed,
		"origin": "user",
	})

	hide()


func _show_error(msg: String) -> void:
	_error_label.text = msg
	_error_label.visible = true


## Reset fields for reuse
func reset() -> void:
	_name_edit.text = ""
	_url_edit.text = "http://localhost"
	_port_spin.value = 8080
	_auto_connect_check.button_pressed = false
	_persist_check.button_pressed = true
	_error_label.visible = false
