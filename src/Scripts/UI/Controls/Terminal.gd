class_name Terminal
extends PanelContainer

@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var text_edit: TextEdit = %TextEdit

const cwd_delimiter = "##cwd##"

var cwd = OS.get_data_dir() 

var wrap_command: Callable
var shell: String


func _wrap_windows_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		"/V:ON",
		"/C",
		"cd /d %s && %s && echo %s!cd!" % [cwd, user_input, cwd_delimiter],
	]

	return full_cmd

func _wrap_linux_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		'(cd %s && %s && echo "%s$(pwd)")' % [cwd, user_input, cwd_delimiter]
	]

	return full_cmd


func _init():
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

	text_edit.text += cmd_results



func _on_button_pressed():
	execute_command(command_line_edit.text)
	command_line_edit.text = ""

