class_name Terminal
extends PanelContainer

@warning_ignore("unused_signal")
signal execution_finished()

@export var _send_button: BaseButton

@onready var scroll_container = %ScrollContainer
@onready var command_line_edit: LineEdit = %CommandLineEdit
@onready var cwd_label: Label = %CwdLabel


var stdio: FileAccess
var stderr: FileAccess
var pid: int

var _stdio_thread: Thread
var _stderr_thread: Thread
var _index: = -1
var _mutex: = Mutex.new()
var _process_text_timer: = Timer.new()

# label where the output of the current running command should go to
@onready var _output_container: Container = %OutputContainer
var _output_label: Label


const cwd_delimiter = "##cwd##"

## History of used commands
var _history: = PackedStringArray()

var _history_idx = 0

var wrap_command: Callable
var delimiter: String = "---$$%s$$---"
var shell: String


static func create() -> Terminal:
	var terminal = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal


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

	return "{cmd} & echo -e \"\n{delimiter}\"".format({
		"cmd": user_input,
		"delimiter": escaped_delimiter,
	})



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



func _on_output_check_button_tree_exiting(btn: CheckButton):
	if not btn.has_meta("memory_item"): return
	
	var item: MemoryItem = btn.get_meta("memory_item")

	var thread: = SingletonObject.get_thread(item.OwningThread)

	thread.MemoryItemList.erase(item)


func _ready():

	_process_text_timer.one_shot = true
	add_child(_process_text_timer)
	
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




# Array of characters we received from streams
var _received_characters: = PackedStringArray()
var _offset: = 0
const MAX_PROCESS_PASS: = 200

func _process(_delta: float) -> void:
	_mutex.lock()

	# print("_process thread: ", OS.get_thread_caller_id())

	if _received_characters.is_empty():
		# print("_received_characters is empty")
		set_process(false)
		_mutex.unlock()
		return
	
	var time_start = Time.get_unix_time_from_system()

	for i in min(MAX_PROCESS_PASS, _received_characters.size()):
		_proces_received_text(_received_characters[-1], _offset)
		_offset -= 1

		_received_characters.remove_at(_received_characters.size()-1)


	prints(min(MAX_PROCESS_PASS, _received_characters.size()), Time.get_unix_time_from_system() - time_start)

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
	# print("_new_text thread: ", OS.get_thread_caller_id())
	
	if index > 0 and index - prev != 1:
		push_warning("Current index is %s and previous is %s" % [index, prev])

	prev = index

	# if we're about to add first element to this array, adjust the _offset
	if _received_characters.is_empty():
		_offset = index


	_received_characters.insert(0, text)

	if not is_processing():
		set_process.call_deferred(true)

	return

	var array_index: = index - _offset

	# for performance reasons, we'll add elements in reverse order

	if array_index < 0:
		# if array_index is -2 we'll need to resize the array to accept 2 new elements
		
		# new array size will be current substracted with array_index, which is negative in this if branch
		# if _received_characters is 50 and array_index -2, 50 - (-2) = 50 + 2
		var new_array_size = _received_characters.size() - array_index
		_received_characters.resize(new_array_size)
		
		_received_characters.set(new_array_size-1, text)
		
		# update the offset since we received index lower than the current one
		_offset = index


	# index: 2
	# _offset: 0
	# array_index 2

	_received_characters.set(-array_index, text)
	
	# ["n", "i", "M"]
	# 

	_received_characters.resize(array_index+1)

	if not is_processing():
		set_process.call_deferred(true)
	


## A sequence of characters that must be removed from the terminal output
## before it's shown to the user. Used to remove internally used echo statement
class DisalowedSequence:
	extends RefCounted

	var full: String:
		get: return "%s%s%s" % [before, content, after]

	var before: String
	var after: String
	var content: String
	var block: = false
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
		
	func is_potential(text: String) -> bool:
		var full_text: = "%s%s%s" % [before, content, after]

		return full_text.begins_with(text)

	## Strips the [member content] from the given [parameter text]
	func strip(text: String) -> String:
		var full_text: = "%s%s%s" % [before, content, after]

		var stripped: = "%s%s" % [before, after]

		return text.replace(full_text, stripped)


var _processed_text: =  PackedStringArray()


# normally the size of this array is between 0 and 2
# for starting and ending  command sequence
var _disallowed_seq: Array[DisalowedSequence]

func _proces_received_text(text: String, _index_a: int) -> void:
	# print("_proces_received_text thread: ", OS.get_thread_caller_id())

	_processed_text.append(text)
	
	if not _output_label:
		_create_command_output_container()

	if _disallowed_seq.is_empty():
		_output_label.text += "".join(_processed_text)
		_processed_text.clear()
		return
	
	var full_string: = "".join(_processed_text)
	
	var add_char: = true
	var was_stripped: = false

	var ds: DisalowedSequence = _disallowed_seq.front()

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
		_output_label.text += full_string
		_processed_text.clear()

		# if this ds marks command end, start the new command output container
		if was_stripped and ds.command_end:
			_create_command_output_container()



func execute_command(input: String):
	_history.append(input)

	var command_buffer: PackedByteArray

	# if this array is not empty we didn't reach the end of the previous command yet
	if _disallowed_seq.is_empty():

		command_buffer = (wrap_command.call(input) + "\n").to_utf8_buffer()

		_disallowed_seq.append(DisalowedSequence.new(wrap_command.call(""), input, ""))
		_disallowed_seq.append(DisalowedSequence.new(delimiter % "", "\n", "", true))

	else:
		command_buffer = (input + "\n").to_utf8_buffer()

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
