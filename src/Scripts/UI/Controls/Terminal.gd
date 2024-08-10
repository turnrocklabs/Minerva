class_name Terminal
extends PanelContainer

signal execution_finished()

@export var _send_button: BaseButton

@onready var scroll_container = %ScrollContainer
@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var outputs_container: VBoxContainer = %OutputsContainer
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
		"cd '%s' && %s; echo '%s'\\$PWD" % [cwd, user_input, cwd_delimiter]
	]

	return full_cmd


func display_output(output: String) -> void:
	var output_container = HBoxContainer.new()
	
	var check_button = CheckButton.new()
	check_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	check_button.size_flags_vertical = Control.SIZE_SHRINK_END
	check_button.toggled.connect(_on_output_check_button_toggled.bind(output, check_button))
	check_button.tree_exiting.connect(_on_output_check_button_tree_exiting.bind(check_button))
	output_container.add_child(check_button)

	var label = RichTextLabel.new()
	label.fit_content = true
	label.selection_enabled = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text = output
	output_container.add_child(label)
	
	outputs_container.add_child(output_container)
	
	#this 2 lines are for auto scrollling all the way down
	await get_tree().process_frame
	%ScrollContainer.ensure_control_visible(%CwdLabel)


func _on_output_check_button_toggled(toggled_on: bool, output: String, btn: CheckButton):
	var item: MemoryItem

	if not has_meta("memory_item"):
		item = SingletonObject.NotesTab.create_note("Terminal Note")
		item.Content = output
		
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

	printraw("Raw Output: %s" % str(output))  # Debugging print

	return output

func _clear_screen_sequence_idx(output: String) -> int:
	# List more sequences if needed
	var clear_sequences = ["\\033[H\\033[2J", "\\u001b[2J", "\f"]
	for sequence in clear_sequences:
		if sequence in output:
			return output.rfind(sequence)
	return -1

func execute_thread_command(input: String):
	_thread = Thread.new()
	_thread.start(_execute_command.bind(input), Thread.PRIORITY_LOW)

	var callback = func():
		var output = _thread.get_meta("output")

		# last line is current working directory, so we just extarct that
		var cmd_result: String = output.back()
		
		var cwd_index_start = cmd_result.rfind(cwd_delimiter)

		var new_cwd = cmd_result.substr(cwd_index_start+cwd_delimiter.length()).strip_edges()

		cmd_result = cmd_result.substr(0, cwd_index_start)
		
		var idx = _clear_screen_sequence_idx(cmd_result)

		if idx != -1:
			cmd_result = cmd_result.substr(idx)

			# clear the previous outputs since we cleared the terminal
			for child in outputs_container.get_children():
				child.queue_free()

			# check if there's anything to display
			if not cmd_result.strip_edges().is_empty():
				display_output(cmd_result)
		else:
			display_output("%s>%s\n%s" % [cwd, input, cmd_result])

		cwd = new_cwd

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
	await scroll_container.get_v_scroll_bar().changed

	# scroll to bottom
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
