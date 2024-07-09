class_name Terminal
extends PanelContainer

@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var text_edit: TextEdit = %TextEdit
@onready var cwd_label: Label = %CwdLabel

const cwd_delimiter = "##cwd##"

## History of used commands
var _history: = PackedStringArray()

var _history_idx = 0

## Holds the current working directory
var cwd: String:
	set(value):
		cwd = value
		cwd_label.text = "%s>" % cwd

var wrap_command: Callable
var shell: String


func _wrap_windows_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		"/V:ON",
		"/C",
		"cd /d %s && %s & echo %s!cd!" % [cwd, user_input, cwd_delimiter],
	]

	return full_cmd

func _wrap_linux_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		'(cd %s && %s & echo "%s$(pwd)")' % [cwd, user_input, cwd_delimiter]
	]

	return full_cmd


func _ready():
	cwd = OS.get_data_dir()

	match OS.get_name():
		"Windows":
			shell = OS.get_environment("COMSPEC")
			wrap_command = _wrap_windows_command

		"macOS":
			print("macOS")

		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			shell = OS.get_environment("SHELL")
			wrap_command = _wrap_linux_command

		"Android":
			print("Android")

		"iOS":
			print("iOS")


func execute_command(input: String) -> void:
	var output = []

	var args = wrap_command.call(input)

	var pid = OS.execute(shell, args, output, true)

	# last line is current working directory, so we just extarct that
	var cmd_results: String = output.back()

	# print([cmd_results])

	var cwd_index_start = cmd_results.rfind(cwd_delimiter)

	cwd = cmd_results.substr(cwd_index_start+cwd_delimiter.length()).strip_edges()

	cmd_results = cmd_results.substr(0, cwd_index_start)

	text_edit.text += "%s> %s" % [cwd, cmd_results]

	_history.insert(0, input)
	_history_idx = -1



func _on_button_pressed():
	if not command_line_edit.text.is_empty():
		execute_command(command_line_edit.text)
		command_line_edit.text = ""


func _on_command_line_edit_text_submitted(new_text):
	if not command_line_edit.text.is_empty():
		execute_command(new_text)
		command_line_edit.text = ""


func _on_command_line_edit_gui_input(event: InputEvent):
	if event.is_action_pressed("ui_up"):
		if _history_idx < _history.size() - 1:
			_history_idx += 1
			command_line_edit.text = _history[_history_idx]
			
			await get_tree().process_frame
			command_line_edit.caret_column = command_line_edit.text.length()

	elif event.is_action_pressed("ui_down"):
		if _history_idx > 0:
			_history_idx -= 1
			command_line_edit.text = _history[_history_idx]
			
			await get_tree().process_frame
			command_line_edit.caret_column = command_line_edit.text.length()

