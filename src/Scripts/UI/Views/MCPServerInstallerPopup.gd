class_name MCPServerInstallerPopup
extends Window
## UI for installing MCP servers from GitHub repositories.

const MCPServerInstallerScript := preload("res://Scripts/Services/MCP/MCPServerInstaller.gd")

signal installation_complete(results: Dictionary)

@onready var install_path_edit: LineEdit = %InstallPathEdit
@onready var browse_button: Button = %BrowseButton
@onready var nudge_checkbox: CheckBox = %NudgeCheckbox
@onready var cobrowser_checkbox: CheckBox = %CoBrowserCheckbox
@onready var codetools_checkbox: CheckBox = %CodeToolsCheckbox
@onready var prerequisites_label: Label = %PrerequisitesLabel
@onready var status_label: Label = %StatusLabel
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var log_output: RichTextLabel = %LogOutput
@onready var install_button: Button = %InstallButton
@onready var directory_dialog: FileDialog = %DirectoryDialog

var _installer = null


func _ready() -> void:
	about_to_popup.connect(_on_about_to_popup)
	add_to_group("mcp_installer_popup")
	_installer = MCPServerInstallerScript.new()
	_installer.progress_updated.connect(_on_progress_updated)
	_installer.log_message.connect(_on_log_message)
	_installer.installation_finished.connect(_on_installation_finished)

	_set_default_install_path()


func _on_about_to_popup() -> void:
	# Sync content scale factor with main window for proper UI scaling
	var main_scale: float = get_tree().root.content_scale_factor
	content_scale_factor = main_scale

	# Re-check prerequisites each time popup is shown
	_check_prerequisites()


func _set_default_install_path() -> void:
	match OS.get_name():
		"Windows":
			var userprofile := OS.get_environment("USERPROFILE")
			if not userprofile.is_empty():
				install_path_edit.text = userprofile + "\\mcp_servers"
			else:
				install_path_edit.text = "C:\\mcp_servers"
		_:
			var home := OS.get_environment("HOME")
			if not home.is_empty():
				install_path_edit.text = home + "/mcp_servers"
			else:
				install_path_edit.text = "/tmp/mcp_servers"


func _check_prerequisites() -> void:
	prerequisites_label.text = "Prerequisites: Checking..."

	var prereqs: Dictionary = _installer.check_prerequisites()

	var status_parts: Array[String] = []

	var python_info: Dictionary = prereqs.get("python", {})
	var git_info: Dictionary = prereqs.get("git", {})
	var firefox_info: Dictionary = prereqs.get("firefox", {})

	if python_info.get("available", false):
		status_parts.append("Python %s" % python_info.get("version", ""))
	else:
		status_parts.append("[color=red]Python 3.11+ required[/color]")

	if git_info.get("available", false):
		status_parts.append("Git")
	else:
		status_parts.append("[color=red]Git required[/color]")

	if firefox_info.get("available", false):
		status_parts.append("Firefox")
	else:
		status_parts.append("[color=yellow]Firefox (optional for CoBrowser)[/color]")

	prerequisites_label.text = "Prerequisites: " + ", ".join(status_parts)

	# Enable/disable install button based on required prerequisites
	var can_install: bool = python_info.get("available", false) and git_info.get("available", false)
	install_button.disabled = not can_install

	if not can_install:
		status_label.text = "Missing required prerequisites"
		_log_prerequisites_instructions(prereqs)
	else:
		status_label.text = "Ready to install"


func _log_prerequisites_instructions(prereqs: Dictionary) -> void:
	log_output.text = ""

	var python_info: Dictionary = prereqs.get("python", {})
	var git_info: Dictionary = prereqs.get("git", {})
	var firefox_info: Dictionary = prereqs.get("firefox", {})

	if not python_info.get("available", false):
		_append_log("[b]Python 3.11+ is required[/b]", true)
		_append_log(MCPServerInstallerScript.get_install_instructions("python"), false)
		_append_log("", false)

	if not git_info.get("available", false):
		_append_log("[b]Git is required[/b]", true)
		_append_log(MCPServerInstallerScript.get_install_instructions("git"), false)
		_append_log("", false)

	if not firefox_info.get("available", false):
		_append_log("[b]Firefox (optional)[/b]", false)
		_append_log("Firefox is required only for CoBrowser functionality.", false)
		_append_log(MCPServerInstallerScript.get_install_instructions("firefox"), false)


func _on_browse_button_pressed() -> void:
	directory_dialog.current_dir = install_path_edit.text if not install_path_edit.text.is_empty() else OS.get_environment("HOME")
	directory_dialog.popup_centered()


func _on_directory_dialog_dir_selected(dir: String) -> void:
	install_path_edit.text = dir


func _on_install_button_pressed() -> void:
	if _installer.is_installing():
		return

	var servers_to_install: Array = []
	if nudge_checkbox.button_pressed:
		servers_to_install.append("nudge")
	if cobrowser_checkbox.button_pressed:
		servers_to_install.append("cobrowser")
	if codetools_checkbox.button_pressed:
		servers_to_install.append("codetools")

	if servers_to_install.is_empty():
		status_label.text = "Please select at least one server to install"
		return

	var install_path := install_path_edit.text.strip_edges()
	if install_path.is_empty():
		status_label.text = "Please specify an installation directory"
		return

	# Start installation
	log_output.text = ""
	_append_log("[b]Starting installation...[/b]", false)
	_append_log("Install directory: %s" % install_path, false)
	_append_log("Servers: %s" % ", ".join(servers_to_install), false)
	_append_log("", false)

	progress_bar.visible = true
	progress_bar.value = 0
	install_button.disabled = true
	browse_button.disabled = true
	nudge_checkbox.disabled = true
	cobrowser_checkbox.disabled = true
	codetools_checkbox.disabled = true
	install_path_edit.editable = false

	# Run installation (this is synchronous due to OS.execute)
	_installer.install_servers(install_path, servers_to_install)


func _on_progress_updated(percent: float, message: String) -> void:
	progress_bar.value = percent
	status_label.text = message


func _on_log_message(text: String, is_error: bool) -> void:
	_append_log(text, is_error)


func _append_log(text: String, is_error: bool) -> void:
	if is_error:
		log_output.append_text("[color=red]%s[/color]\n" % text)
	else:
		log_output.append_text("%s\n" % text)


func _on_installation_finished(success: bool, results: Dictionary) -> void:
	progress_bar.visible = false
	install_button.disabled = false
	browse_button.disabled = false
	nudge_checkbox.disabled = false
	cobrowser_checkbox.disabled = false
	codetools_checkbox.disabled = false
	install_path_edit.editable = true

	_append_log("", false)

	if success:
		status_label.text = "Installation complete!"
		_append_log("[b][color=green]Installation completed successfully![/color][/b]", false)

		# Save installation paths to config
		_save_installation_paths(results)
	else:
		status_label.text = "Installation completed with errors"
		_append_log("[b][color=red]Installation completed with errors[/color][/b]", false)

		if results.has("errors"):
			for error in results.errors:
				_append_log("  - %s" % error, true)

	installation_complete.emit(results)


func _save_installation_paths(results: Dictionary) -> void:
	if not results.has("servers"):
		return

	# Load MCP config and save installation paths
	var config := MCPConfig.new()
	config.load_config()

	for server_name in results.servers:
		var server_result: Dictionary = results.servers[server_name]
		if server_result.get("installed", false):
			var path: String = server_result.get("path", "")
			if not path.is_empty():
				config.set_installation_path(server_name, path)
				_append_log("Saved %s installation path: %s" % [server_name, path], false)

	config.save_config()
