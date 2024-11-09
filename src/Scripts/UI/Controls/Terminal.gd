class_name Terminal
extends PanelContainer

const MAX_COMMAND_OUTPUT_LENGTH: = 2048

@warning_ignore("unused_signal")
signal execution_finished()

@onready var scroll_container = %ScrollContainer
@onready var command_line_edit: LineEdit = %CommandLineEdit


var stdio: FileAccess
var stderr: FileAccess
## PID of the running shell process
var pid: int

var _stdio_thread: Thread
var _stderr_thread: Thread
var _mutex: = Mutex.new()

# label where the output of the current running command should go to
@onready var _output_container: Container = %OutputContainer
var _output_label: Label


## History of used commands
var _history: = PackedStringArray()

var _history_idx = 0

var wrap_command: Callable
var delimiter: String = "---$$%s$$---"
var shell: String

## Creates new terminal instance
static func create() -> Terminal:
	var terminal = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal


# region Wrap Commmand

func _wrap_windows_command(user_input: String) -> String:
	return "{cmd} & echo.&echo {delimiter}".format({
		"cmd": user_input,
		"delimiter": delimiter % "",
	})

func _wrap_linux_command(user_input: String) -> String:
	# escape the string so it doesn't get expanded on linux
	var escaped_delimiter = (
		delimiter % ""
	).replace("\\", "\\\\").replace("$", "\\$").replace("`", "\\`").replace("!", "\\!")

	var color_code_regex = r"s/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]//g"

	return "{cmd} | sed -r \"{regex}\"; echo -e \"{delimiter}\"".format({
		"regex": color_code_regex,
		"cmd": user_input,
		"delimiter": escaped_delimiter,
	})

# endregion

## Creates output container for the currently running command.[br]
## Contains label and check button to enable that output content.
func _create_command_output_container() -> Container:
	var command_output_container = HBoxContainer.new()

	_output_label = Label.new()
	#_output_label.fit_content = true
	#_output_label.selection_enabled = true
	_output_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var check_button = CheckButton.new()
	check_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	check_button.size_flags_vertical = Control.SIZE_SHRINK_END
	check_button.toggled.connect(_on_output_check_button_toggled.bind(_output_label, check_button))
	check_button.tree_exiting.connect(_on_output_check_button_tree_exiting.bind(check_button))

	command_output_container.add_child(check_button)
	command_output_container.add_child(_output_label)
	
	_output_container.add_child.call_deferred(command_output_container)
	
	return command_output_container


func _on_output_check_button_toggled(toggled_on: bool, label: Label, btn: CheckButton):
	# Create a new memoryitem to access the hash function. 
	var item: MemoryItem = MemoryItem.new()
	item.Enabled = false
	item.Type = SingletonObject.note_type.TEXT
	item.Title = "Terminal Note"
	item.Visible = true
	item.Content = label.text

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


## Clean up the memory items if the terminal was deleted
func _on_output_check_button_tree_exiting(btn: CheckButton):
	if not btn.has_meta("memory_item"): return
	
	var item: MemoryItem = btn.get_meta("memory_item")

	var thread: = SingletonObject.get_thread(item.OwningThread)

	thread.MemoryItemList.erase(item)


func _ready():
	
	# for auto scrolling the output container
	var scrollbar: VScrollBar = scroll_container.get_v_scroll_bar()
	scrollbar.changed.connect(
		func():
			scroll_container.scroll_vertical = scrollbar.max_value
	)

	match OS.get_name():
		"Windows":
			shell = OS.get_environment("COMSPEC")
			wrap_command = _wrap_windows_command

		"Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			shell = OS.get_environment("SHELL")
			wrap_command = _wrap_linux_command
	
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


# Auto focus the line input when control is visible again 
func _on_visibility_changed() -> void:
	if not is_node_ready(): await ready
	
	if is_visible_in_tree():
		command_line_edit.grab_focus()


# colse the threads on node exit
func _exit_tree() -> void:
	_clean()

## Stops the [class FileAccess] streams, threads and kills the shell process.
func _clean() -> void:
	if pid: OS.kill(pid)

	stdio.close()
	stderr.close()

	_stdio_thread.wait_to_finish()
	_stderr_thread.wait_to_finish()

	print("Cleaned up shell pipes and threads.")




# mutex regulate access to next 3 variables

# Array of characters we received from streams
var _received_characters: = PackedStringArray()
# index counter for the character order
var _index: = -1
# offset for the first element in _received_characters
var _offset: = 0

# maximum number of processed characters in _process function
const MAX_PROCESS_PASS: = 200

func _process(_delta: float) -> void:
	_mutex.lock()

	if _received_characters.is_empty():
		set_process(false)
		_mutex.unlock()
		return
	
	# var time_start = Time.get_unix_time_from_system()

	for i in min(MAX_PROCESS_PASS, _received_characters.size()):
		_proces_received_text(_received_characters[-1], _offset)
		_offset -= 1

		_received_characters.remove_at(_received_characters.size()-1)


	# prints(min(MAX_PROCESS_PASS, _received_characters.size()), Time.get_unix_time_from_system() - time_start)

	_mutex.unlock()



func _stdio_thread_loop():
	while stdio.is_open() and stdio.get_error() == OK:
		var data: = char(stdio.get_8())

		_mutex.lock()
		# print("stdio thread: ", OS.get_thread_caller_id())
		
		_index += 1
		var index = _index
		
		_new_text(data, index)
		
		_mutex.unlock()


func _stderr_thread_loop():
	while stderr.is_open() and stderr.get_error() == OK:
		var data: = char(stderr.get_8())

		_mutex.lock()
		# print("stderr thread: ", OS.get_thread_caller_id())
		
		_index += 1
		var index = _index
		
		_new_text(data, index)
		
		_mutex.unlock()


var prev: int
func _new_text(text: String, index: int) -> void:
	# checks if characters are coming in correct order,
	if index > 0 and index - prev != 1:
		push_warning("Current index is %s and previous is %s" % [index, prev])
	prev = index

	# if we're about to add first element to this array, adjust the _offset
	if _received_characters.is_empty():
		_offset = index

	_received_characters.insert(0, text)

	if not is_processing():
		set_process.call_deferred(true)



## A sequence of characters that must be removed from the terminal output
## before it's shown to the user. Used to remove internally used echo statement
class DisalowedSequence:
	extends RefCounted

	## Read only full string content where[br]
	## [memeber before], [memeber content] and [memeber after] are added together.
	var full: String:
		get: return "%s%s%s" % [before, content, after]

	var before: String
	var after: String
	var content: String

	# Whether this delimiter marks the command output end.
	var command_end: = false

	func _init(content_: String, before_: String, after_: String, command_end_: = false) -> void:
		content = content_
		after = after_
		before = before_
		command_end = command_end_
	
	## Checks if [parameter text] has give [member content]
	## inbetween [member before] and [member after].
	func is_present(text: String) -> bool:
		return text.contains("%s%s%s" % [before, content, after])
	
	## Checks whether the provided unfinished [parameter text][br]
	## could potentially match the disallowed sequence.
	func is_potential(text: String) -> bool:
		var full_text: = "%s%s%s" % [before, content, after]

		return full_text.begins_with(text)

	## Strips the [member content] from the given [parameter text]
	func strip(text: String) -> String:
		var full_text: = "%s%s%s" % [before, content, after]

		var stripped: = "%s%s" % [before, after]

		return text.replace(full_text, stripped)


## Characters that were processed, but are not yet displayed because they[br]
## possibly match the disallowed sequence 
var _processed_text: =  PackedStringArray()


# normally the size of this array is between 0 and 2
# for starting and ending  command sequence
var _disallowed_seq: Array[DisalowedSequence]

func _proces_received_text(text: String, _index_a: int) -> void:
	_processed_text.append(text)
	
	if not _output_label:
		_create_command_output_container()

	if _disallowed_seq.is_empty():
		_append_output_text("".join(_processed_text))
		_processed_text.clear()
		return
	
	var full_string: = "".join(_processed_text)
	
	var add_char: = true
	var was_stripped: = false

	var ds: DisalowedSequence = _disallowed_seq.front()

	# print("Checking \"%s\"..." % full_string)

	# currently received characters are not potentially disallowed sequence just add them
	if ds.is_potential(full_string):
		# print(r"'%s' is potential for '%s'" % [full_string, ds.full])
		add_char = false

		if ds.is_present(full_string):

			var stripped: = ds.strip(full_string)
			full_string = stripped
			was_stripped = true

			add_char = true
			_disallowed_seq.erase(ds)
	
	if add_char:
		_append_output_text(full_string)
		
		_processed_text.clear()

		# if this ds marks command end, start the new command output container
		if was_stripped and ds.command_end:
			_create_command_output_container()
			_toggle_progress_bar(false)


func _append_output_text(text: String) -> void:
	var remaining_space: = MAX_COMMAND_OUTPUT_LENGTH - _output_label.text.length()
	
	if remaining_space < text.length():
		text = text.left(remaining_space)

		# Add the notice that the text was truncated, clear the disallowed sequence array,
		# start the new output container and set the meta so we dont do it again
		if not _output_label.get_meta("truncated", false):
			text += "\n(output truncated)"
			_output_label.set_meta("truncated", true)
			_output_label.text += text
			# _create_command_output_container()
			# _disallowed_seq.clear()
		return

	_output_label.text += text

func execute_command(input: String):
	_history.append(input)

	var command_buffer: PackedByteArray

	# if this array is not empty we didn't reach the end of the previous command yet
	if _disallowed_seq.is_empty():

		command_buffer = (wrap_command.call(input) + "\n").to_utf8_buffer()

		# windows shell outputs the input command, where other shells don't do that
		if OS.get_name() == "Windows":
			_disallowed_seq.append(DisalowedSequence.new(wrap_command.call(""), input, ""))
		
		_disallowed_seq.append(DisalowedSequence.new(delimiter % "", "\n", "", true))

	else:
		command_buffer = (input + "\n").to_utf8_buffer()

	stdio.store_buffer(command_buffer)

	_toggle_progress_bar()


func _toggle_progress_bar(on: bool = true) -> void:
	%TextureProgressBar.value = 100 if on else 0

	var tween: Tween = get_tree().create_tween().set_loops()
	tween.tween_property(%TextureProgressBar, "radial_initial_angle", 360.0, 1.5).as_relative()


func _on_button_pressed():
	if not command_line_edit.text.is_empty():
		execute_command(command_line_edit.text)
		command_line_edit.text = ""


func _on_command_line_edit_text_submitted(new_text):
	if not command_line_edit.text.is_empty():
		execute_command(new_text)
		command_line_edit.text = ""

## iterate over used commands from command history 
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

