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


func display_output(output: String) -> void:
	var output_container = HBoxContainer.new()
	const MAX_OUTPUT_LEN: int = 8192
	var check_button = CheckButton.new()
	check_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	check_button.size_flags_vertical = Control.SIZE_SHRINK_END
	check_button.toggled.connect(_on_output_check_button_toggled.bind(output, check_button))
	check_button.tree_exiting.connect(_on_output_check_button_tree_exiting.bind(check_button))
	output_container.add_child(check_button)

	var label = Label.new()
	#label.fit_content = true
	#label.selection_enabled = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label_text: String  = ""
	if len(output) <=  MAX_OUTPUT_LEN:
		label_text = output
	else:
		label_text = output.substr(0, MAX_OUTPUT_LEN)
		label_text += "\n"
		label_text += "(rest truncated...)"
	
	label.text = label_text
	output_container.add_child(label)
	
	outputs_container.add_child(output_container)
	
	#this 2 lines are for auto scrollling all the way down
	await get_tree().process_frame
	%ScrollContainer.ensure_control_visible(%CwdLabel)


func _on_output_check_button_toggled(toggled_on: bool, output: String, btn: CheckButton):
	# Create a new memoryitem to access the hash function. 
	var item: MemoryItem = MemoryItem.new()
	item.Enabled = false
	item.Type = SingletonObject.note_type.TEXT
	item.Title = "Terminal Note"
	item.Visible = true
	item.Content = output

	# use the hash to see if we already have this item in the DetachedNotes
	var detached_index: int = -1
	for search_index in SingletonObject.DetachedNotes.size():
		if SingletonObject.DetachedNotes[search_index].Sha_256 == item.Sha_256:
			detached_index = search_index
	
	# if we don't have it, connect a toggled handler and append to detached notes.
	if detached_index == -1:
		item.Enabled = toggled_on
		item.toggled.connect(
			func(on: bool):
				btn.button_pressed = on
		)
		SingletonObject.DetachedNotes.append(item)
	else:
		SingletonObject.DetachedNotes[detached_index].Enabled = toggled_on



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
