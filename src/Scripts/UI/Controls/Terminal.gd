class_name Terminal
extends PanelContainer

signal execution_finished()

@export var _send_button: BaseButton

@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var text_edit: TextEdit = %TextEdit
@onready var cwd_label: Label = %CwdLabel

const cwd_delimiter = "##cwd##"

var _thread: Thread:
	set(value):
		_thread = value
		_send_button.disabled = _thread != null

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


static func create() -> Terminal:
	var terminal = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal


func _wrap_windows_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		"/V:ON",
		"/C",
		"cd /d %s && %s & echo %s!cd!" % [cwd, user_input, cwd_delimiter],
	]

	return full_cmd

func _wrap_linux_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		"-c",
		"cd %s; '%s'; echo '%s'$PWD" % [cwd, user_input, cwd_delimiter]
	]

	return full_cmd

func _ready():
	cwd = OS.get_data_dir()

	match OS.get_name():
		"Windows":
			shell = OS.get_environment("COMSPEC")
			wrap_command = _wrap_windows_command

		"Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			shell = OS.get_environment("SHELL")
			wrap_command = _wrap_linux_command


func _process(_delta):
	if not _thread or not _thread.is_started(): return

	if not _thread.is_alive():
		_thread.set_meta("output", _thread.wait_to_finish())
		if _thread.get_meta("callback", null) is Callable:
			_thread.get_meta("callback").call()
			_thread = null


func _execute_command(input: String) -> Array:
	var output = []

	var args = wrap_command.call(input)

	print("Running: %s %s" % [shell, " ".join(args)])

	OS.execute(shell, args, output, true)
	return output


func execute_thread_command(input: String):
	_thread = Thread.new()
	_thread.start(_execute_command.bind(input), Thread.PRIORITY_LOW)
	print("Thread started")

	var callback = func():
		var output = _thread.get_meta("output")

		# last line is current working directory, so we just extarct that
		var cmd_result: String = output.back()
		
		var cwd_index_start = cmd_result.rfind(cwd_delimiter)

		cwd = cmd_result.substr(cwd_index_start+cwd_delimiter.length()).strip_edges()

		cmd_result = cmd_result.substr(0, cwd_index_start)

		
		# If theres \f clear the textedit
		# eg. clear/cls command will just output \f
		if "\f" in cmd_result:
			var idx = cmd_result.rfind("\f")

			cmd_result = cmd_result.substr(idx)
			text_edit.text = cmd_result
		else:
			text_edit.text += "%s>%s\n%s" % [cwd, input, cmd_result]

		_history.insert(0, input)
		_history_idx = -1
	
	_thread.set_meta("callback", callback)


func _on_button_pressed():
	if not command_line_edit.text.is_empty():
		execute_thread_command(command_line_edit.text)
		command_line_edit.text = ""


func _on_command_line_edit_text_submitted(new_text):
	if not command_line_edit.text.is_empty() and not _thread:
		execute_thread_command(new_text)
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


func _on_text_edit_text_set():
	var scroll_container: ScrollContainer = %ScrollContainer
	await scroll_container.get_v_scroll_bar().changed

	# scroll to bottom
	scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value