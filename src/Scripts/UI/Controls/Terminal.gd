class_name Terminal
extends PanelContainer

@warning_ignore("unused_signal")
signal execution_finished()

@export var _send_button: BaseButton

@onready var scroll_container = %ScrollContainer
@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var buttons_container: VBoxContainer = %ButtonsContainer
@onready var cwd_label: Label = %CwdLabel


var stdio: FileAccess
var stderr: FileAccess
var pid: int

var _stdio_thread: Thread
var _stderr_thread: Thread

# label where the output of the current running command should go to
@onready var _output_label: RichTextLabel = %RichTextLabel

const cwd_delimiter = "##cwd##"

var _last_enabled_line: int = -1

## History of used commands
var _history: = PackedStringArray()

var _history_idx = 0

var wrap_command: Callable
var delimiter: String = "---$$$---"
var shell: String


static func create() -> Terminal:
	var terminal = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal


func _wrap_windows_command(user_input: String) -> String:
	return "{cmd} & echo {delimiter}".format({
		"cmd": user_input,
		"delimiter": delimiter,
	})

func _wrap_linux_command(user_input: String) -> PackedStringArray:
	var full_cmd = [
		"-c",
		# "cd '%s' && %s; echo '%s'\\$PWD" % [cwd, user_input, cwd_delimiter]
	]

	return full_cmd

var _last_content_height: float = 0

func _text_updated():
	return
	var present_btns: = buttons_container.get_child_count()
	var lines: = _output_label.get_parsed_text().split("\n").size()
	
	# if lines == 1:
	# 	_line_height = float(_output_label.get_content_height())

	if not _output_label.is_ready():
		await _output_label.finished

	for i in range(lines - present_btns):
		var line_num = present_btns+i
		
		var check_button = CheckButton.new()
		check_button.set_meta("line_num", line_num)
		check_button.add_theme_constant_override("icon_max_width", 30)
		check_button.toggled.connect(_on_output_check_button_toggled.bind(line_num, check_button))
		check_button.tree_exiting.connect(_on_output_check_button_tree_exiting.bind(check_button))

		var remaining_height = (_output_label.get_content_height() - _last_content_height) * 0.95

		_last_content_height = _output_label.get_content_height()

		check_button.custom_minimum_size.y = remaining_height

		buttons_container.add_child(check_button)		

		print("Line: ", line_num)
		prints(_output_label.get_content_height(), _last_content_height, remaining_height)

		_output_label.push_indent(1)

		


func _on_output_check_button_toggled(toggled_on: bool, line_num: int, btn: CheckButton):

	var enabled_lines: = _output_label.get_meta("_enabled") as Dictionary

	if Input.is_key_pressed(KEY_SHIFT) and _last_enabled_line != -1:
		for i in range(_last_enabled_line, line_num):
			var check_button: CheckButton = buttons_container.get_child(i)
			check_button.button_pressed = toggled_on
			var ln: int = check_button.get_meta("line_num")
			enabled_lines[ln] = true
			
				
	_last_enabled_line = line_num

	enabled_lines[line_num] = toggled_on

	var content_lines: PackedStringArray

	for ln in enabled_lines.keys():
		if not enabled_lines[ln]: continue

		


	var item: MemoryItem
	
	if not has_meta("memory_item"):
		item = SingletonObject.NotesTab.create_note("Terminal Note")
		item.Content = "line_num"
		
		if not item:
			SingletonObject.ErrorDisplay("Failed", "Failed to create memory item from the terminal.")
			btn.button_pressed = false
			return
		
		item.toggled.connect(
			func(on: bool):
				btn.button_pressed = on
		)

		set_meta("memory_item", item)
		SingletonObject.DetachedNotes.append(item)
	else:
		item = get_meta("memory_item")
		var present = SingletonObject.DetachedNotes.any(func(item_: MemoryItem): return item_ == item)

		if not present:
			SingletonObject.DetachedNotes.append(item)

	item.Enabled = toggled_on


func _on_output_check_button_tree_exiting(btn: CheckButton):
	if not btn.has_meta("memory_item"): return
	
	var item: MemoryItem = btn.get_meta("memory_item")

	var thread: = SingletonObject.get_thread(item.OwningThread)

	thread.MemoryItemList.erase(item)


func _ready():

	match OS.get_name():
		"Windows":
			shell = OS.get_environment("COMSPEC")
			wrap_command = _wrap_windows_command

		"Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			shell = OS.get_environment("SHELL")
	
	var process = OS.execute_with_pipe(shell, [])
	if not process.is_empty():
		stdio = process.get("stdio")
		stderr = process.get("stderr")
		pid = process.get("pid")

		_stdio_thread = Thread.new()
		_stdio_thread.start(_stdio_thread_loop)
		
		_stderr_thread = Thread.new()
		_stderr_thread.start(_stderr_thread_loop)

		get_window().close_requested.connect(_clean)

		print("Started the shell process with pid %s" % pid)

	_output_label.set_meta("_enabled", {})

# colse the threads on node exit
func _exit_tree() -> void:
	_clean()


func _clean() -> void:
	if pid: OS.kill(pid)

	stdio.close()
	stderr.close()

	_stdio_thread.wait_to_finish()
	_stderr_thread.wait_to_finish()

	print("Cleaned up shell pipes and threads.")


func _stdio_thread_loop():
	while stdio.is_open() and stdio.get_error() == OK:
		_new_text.call_deferred(char(stdio.get_8()))


func _stderr_thread_loop():
	while stderr.is_open() and stderr.get_error() == OK:
		_new_text.call_deferred(char(stderr.get_8()))


var _last_cmd: String

func _new_text(text: String) -> void:


	_output_label.add_text(text)
	_text_updated()


func execute_command(input: String):
	_history.append(input)

	var command_buffer = (input + "\n").to_utf8_buffer()

	stdio.store_buffer(command_buffer)


func _is_new_shell_command() -> bool:
	if _history.is_empty(): return true

	var found_delimiter: = false

	var lines: PackedStringArray = _output_label.get_meta("raw_output", _output_label.text).strip_edges().split("\n")
	lines.reverse()
	for line in lines:
		
		if line.contains(wrap_command.call(_history[-1])):
			return found_delimiter

		if line.strip_edges() == delimiter:
			found_delimiter = true

	return false

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


func _scroll_down():
	await scroll_container.get_v_scroll_bar().changed

	# scroll to bottom
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
