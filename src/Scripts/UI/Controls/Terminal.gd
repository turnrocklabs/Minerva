class_name Terminal
extends PanelContainer

const MAX_COMMAND_OUTPUT_LENGTH: = 8192
var ASCII_COLOR_CODE_REGEX: = RegEx.create_from_string("\\x1B\\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]")

var WINDOWS_PATH_REGEX_PATTERN: = r"^[a-zA-Z](?::(?:[\\\/](?:[a-zA-Z0-9._-]+[\\\/])*([a-zA-Z0-9._-]+)?)?)?"
var LINUX_PATH_REGEX_PATTERN: = r"(?:\/)?(?:[a-zA-Z0-9-_.]+\/)*[a-zA-Z0-9-_.]*(?:\/)?[\s]*"

@warning_ignore("unused_signal")
signal execution_finished()

@onready var scroll_container = %ScrollContainer
@onready var command_line_edit: LineEdit = %CommandLineEdit

## Holds the current output container created in [method _create_command_output_container]
var _current_output_container: Container

var stdio: FileAccess
var stderr: FileAccess

## state of the running shell process
var pid: int
var shell_prompt: String:
	set(value):
		shell_prompt = value
		_update_shell_prompt()

var _cwd: DirAccess

var _stdio_thread: Thread
var _stderr_thread: Thread

## state management for the terminal
var _idx_mutex: = Mutex.new() ## mutex for index of the received character to perserve the order
var _chars_mutex: = Mutex.new() ## mutex for the array of received characters
var last_container_checkbutton: CheckButton

# label where the output of the current running command should go to
@onready var _output_container: Container = %OutputContainer
var _output_label: Label


## History of used commands
var _history: = PackedStringArray()

var _history_idx := 0

var wrap_command: Callable
var delimiter: String = "---$$$$---"
var shell: String
## Parameters for starting the above shell
var _parameters: = PackedStringArray()

## Creates new terminal instance
static func create() -> Terminal:
	var terminal = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal


# region Wrap Commmand

func _wrap_windows_command(user_input: String) -> String:
	return " call {cmd} 2>&1 & echo.&echo {delimiter} & cd & echo {delimiter} | more".format({
		"cmd": user_input,
		"delimiter": delimiter,
	})

func _wrap_linux_command(user_input: String) -> String:
	# escape the string so it doesn't get expanded on linux
	var escaped_delimiter = (
		delimiter
	).replace("\\", "\\\\").replace("$", "\\$").replace("`", "\\`").replace("!", "\\!")


	return "{cmd}; echo -e \"{delimiter}\"; pwd; echo -e \"{delimiter}\"".format({
		"cmd": user_input,
		"delimiter": escaped_delimiter,
	})

# endregion

func _update_shell_prompt():
	if OS.get_name() == "Windows":
		%CwdLabel.text = shell_prompt
	else:
		%CwdLabel.text = "(%s) %s%% " % [OS.get_environment("CONDA_DEFAULT_ENV"), shell_prompt]
	
	%CwdLabel.tooltip_text = %CwdLabel.text

	_cwd = DirAccess.open(shell_prompt)
	_autocomplete_suggestions_cwd.clear()
	_autocomplete_suggestions_cwd.append_array(_cwd.get_files())
	_autocomplete_suggestions_cwd.append_array(_cwd.get_directories())
	_autocomplete_suggestions_cwd.sort()
	_autocomplete_idx = 0

# region Autocomplete

## List of all possible autcomplete results (all files, directories, etc.) for the current [member cwd].[br]
## Regenerated each time [member cwd] changes.
var _autocomplete_suggestions_cwd: Array[String]

## List of all possible autcomplete results from the PATH environment variable. Loaded once on the terminal startup.
var _autocomplete_suggestions_path: Array[String]

var _autocomplete_suggestions_all: Array[String]:
	get: return _autocomplete_suggestions_cwd + _autocomplete_suggestions_path

## Current index of autocomplete suggestion used.
var _autocomplete_idx: int

## List all autocomplete suggestions for the current user input.[br]
## Regenerated each time user changes input.
var _autocomplete_suggestions: PackedStringArray

## User input that is being autocompleted
var _autocomplete_input: String

var _autcomplete_source_idx: int

var _autcomplete_on: = true

func _load_path_autosuggestions() -> void:
	if OS.get_name() == "Windows":
		var path_env: = OS.get_environment("PATH")

		var directories: = path_env.split(";")

		for dir in directories:
			var da: = DirAccess.open(dir)
			if da == null: continue

			_autocomplete_suggestions_path.append_array(da.get_files())

	elif OS.get_name() == "Linux":
		var path_env: = OS.get_environment("PATH")

		var directories: = path_env.split(":")

		for dir in directories:
			var da: = DirAccess.open(dir)
			if da == null: continue
			_autocomplete_suggestions_path.append_array(da.get_files())


## Changes the input text for the autocomplete.
func _autocomplete_change_input_string(text: String):
	if not _autcomplete_on: return

	_autocomplete_input = text
	_autocomplete_idx = -1
	
	if text.is_empty():
		_autocomplete_suggestions = _autocomplete_suggestions_all
		return

	var partial_text: String

	_autcomplete_source_idx = text.rfind(" ")
	if _autcomplete_source_idx == -1:
		partial_text = text
		_autcomplete_source_idx = 0
	else:
		_autcomplete_source_idx += 1
		partial_text = text.substr(_autcomplete_source_idx)

	if partial_text.is_empty():
		_autocomplete_suggestions = _autocomplete_suggestions_all
		return

	_autocomplete_suggestions = (
		_autocomplete_suggestions_all.filter(func(suggestion: String): return suggestion.begins_with(partial_text))
	)


func _autocomplete_get_next() -> String:
	if _autocomplete_suggestions.is_empty(): return ""

	_autocomplete_idx = wrapi(_autocomplete_idx+1, 0, _autocomplete_suggestions.size())

	var next: = _autocomplete_suggestions[_autocomplete_idx]

	return next

func _autocomplete_get_previous() -> String:
	if _autocomplete_suggestions.is_empty(): return ""

	_autocomplete_idx = wrapi(_autocomplete_idx-1, 0, _autocomplete_suggestions.size())

	var next: = _autocomplete_suggestions[_autocomplete_idx]

	return next



func _autocomplete(forward: = true) -> void:
	_autcomplete_on = false

	var next: = _autocomplete_get_next() if forward else _autocomplete_get_previous()
	if not next:
		_autcomplete_on = true
		return

	var text: = command_line_edit.text.left(_autcomplete_source_idx)
	text += next

	command_line_edit.text = text
	command_line_edit.caret_column = text.length()

	_autcomplete_on = true

# endregion

## Creates output container for the currently running command.[br]
## Contains label and check button to enable that output content.
func _create_command_output_container() -> Container:
	_current_output_container = HBoxContainer.new()

	_output_label = Label.new()
	#_output_label.fit_content = true
	#_output_label.selection_enabled = true
	_output_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var check_button = CheckButton.new()
	check_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	check_button.size_flags_vertical = Control.SIZE_SHRINK_END
	if last_container_checkbutton != null:
		check_button.visible = false
	check_button.toggled.connect(_on_output_check_button_toggled.bind(_output_label, check_button))
	check_button.tree_exiting.connect(_on_output_check_button_tree_exiting.bind(check_button))
	last_container_checkbutton = check_button

	_current_output_container.add_child(check_button)
	_current_output_container.add_child(_output_label)
	
	_output_container.add_child.call_deferred(_current_output_container)
	
	return _current_output_container


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

	_load_path_autosuggestions()
	
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
			_parameters = ["/K", "cd /d %s" % OS.get_environment("USERPROFILE")]
			shell_prompt = OS.get_environment("USERPROFILE")

		"Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			shell = OS.get_environment("SHELL")
			wrap_command = _wrap_linux_command
			shell_prompt = OS.get_environment("PWD")
	
	var process = OS.execute_with_pipe(shell, _parameters)
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
	
	_autocomplete_change_input_string(command_line_edit.text)


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
	
	if _stdio_thread.is_alive():
		_stdio_thread.wait_to_finish()
	if _stderr_thread.is_alive():
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
	_chars_mutex.lock()

	if _received_characters.is_empty():
		set_process(false)
		_chars_mutex.unlock()
		return

	for i in min(MAX_PROCESS_PASS, _received_characters.size()):
		_proces_received_text(_received_characters[0], _offset)
		_offset -= 1
		_received_characters.remove_at(0)

	_chars_mutex.unlock()



func _stdio_thread_loop():
	while stdio.is_open() and stdio.get_error() == OK:
		var data: = char(stdio.get_8())

		_idx_mutex.lock()
		_index += 1
		var index = _index
		_idx_mutex.unlock()
	
		_new_text(data, index)
		


func _stderr_thread_loop():
	while stderr.is_open() and stderr.get_error() == OK:
		var data: = char(stderr.get_8())
		
		_idx_mutex.lock()
		_index += 1
		var index = _index
		_idx_mutex.unlock()

		_new_text(data, index)
		


var prev: int
func _new_text(text: String, index: int) -> void:
	# checks if characters are coming in correct order,
	if index > 0 and index - prev != 1:
		push_warning("Current index is %s and previous is %s" % [index, prev])
	prev = index

	_chars_mutex.lock()
	# if we're about to add first element to this array, adjust the _offset
	if _received_characters.is_empty():
		_offset = index

	_received_characters.append(text)
	_chars_mutex.unlock()

	if not is_processing():
		set_process.call_deferred(true)



## A sequence of characters that must be removed from the terminal output
## before it's shown to the user. Used to remove internally used echo statement
class Sequence:
	extends RefCounted

	## Read only full string content where[br]
	## [memeber before], [memeber content] and [memeber after] are added together.
	var full: String:
		get: return "%s%s%s" % [before, content, after]

	var before: String
	var after: String
	var content
	var replace_with: String

	# Whether this delimiter marks the command output end.
	var command_end: = false

	var full_regex: RegEx

	func _init(content_, before_: String, after_: String, command_end_: = false, replace_with_: = "") -> void:
		content = content_
		after = after_
		before = before_
		command_end = command_end_
		replace_with = replace_with_

		if content is String:
			var full_text: = "%s%s%s" % [before, content, after]
			full_regex = RegEx.create_from_string(regex_escape(full_text))
		elif content is RegEx:
			var full_text: = "%s%s%s" % [regex_escape(before), content.get_pattern(), regex_escape(after)]
			full_regex = RegEx.create_from_string("(?m)%s" % full_text)


	static func _create_partial_regex_pattern(literal: String):
		var pattern_array: = PackedStringArray(["^"])

		for i in range(literal.length()):
			var char_ = literal[i]
			
			if i == 0:
				pattern_array.append(regex_escape(char_))
				continue

			pattern_array.append("(" + regex_escape(char_))

		for i in range(literal.length()-1):
			pattern_array.append(")?")
		
		pattern_array.append("$")

		return "".join(pattern_array)

	# Escapes special regex characters in a string to create a literal search pattern
	static func regex_escape(literal: String) -> String:
		# List of special characters that need to be escaped in regex
		const SPECIAL_CHARS = [
			"\\", # Backslash must be first to avoid double-escaping
			".", 
			"+", 
			"*", 
			"?", 
			"^", 
			"$", 
			"(", 
			")", 
			"[", 
			"]", 
			"{", 
			"}", 
			"|",
			"/"
		]
		
		var escaped = literal
		# Add backslash before each special character
		for char_ in SPECIAL_CHARS:
			escaped = escaped.replace(char_, "\\" + char_)
		
		return escaped

	## Checks if [parameter text] has the given [member content]
	## inbetween [member before] and [member after].
	func is_present(text: String) -> bool:

		return full_regex.search(text) is RegExMatch
	
	## Checks whether the provided unfinished [parameter text][br]
	## could potentially match the sequence.
	func is_potential(text: String, allow_empty: = true) -> bool:
		if not before.is_empty() and text.length() <= before.length():
			return before.begins_with(text)

		var remaining: = text.substr(before.length())

		if remaining.strip_escapes().strip_edges().is_empty():
			if allow_empty: return true

		var pr: RegEx

		if content is String:
			pr = RegEx.create_from_string(_create_partial_regex_pattern(content))
		elif content is RegEx:
			pr = content
		
		var match_: = pr.search(remaining)


		if not match_ or match_.get_start() != 0: return false

		remaining = remaining.substr(match_.get_end()+1)


		return true

	func extract_cwd(text: String) -> String:
		
		var match_ = full_regex.search(text)

		if not match_: return ""

		return match_.get_string().trim_prefix(before).trim_suffix(after)

	## Strips the [member content] from the given [parameter text]
	func strip(text: String) -> String:

		return full_regex.sub(text, replace_with)


## Characters that were processed, but are not yet displayed because they[br]
## possibly match the disallowed sequence 
var _processed_text: =  PackedStringArray()


# normally the size of this array is between 0 and 2
# for starting and ending  command sequence
var _disallowed_seq: Array[Sequence]

var _windows_clear_seq: = Sequence.new("\f", "", "")
var _linux_clear_seq: = Sequence.new(RegEx.create_from_string(r"^\x1b(\[2J)?$|^\x1b\[2?$|^\x1b\[$"), "", "")

func _proces_received_text(text: String, _index_a: int) -> void:
	_processed_text.append(text)
	
	var full_string: = "".join(_processed_text)

	if OS.get_name() == "Windows":
		if _windows_clear_seq.is_potential(full_string, false):
			
			if _windows_clear_seq.is_present(full_string):
				clear_terminal()	
			return
	
	elif OS.get_name() == "Linux":
		if _linux_clear_seq.is_potential(full_string, false):
			
			if _linux_clear_seq.is_present(full_string):
				clear_terminal()
			return


	if not _output_label:
		_create_command_output_container()

	if _disallowed_seq.is_empty():
		_append_output_text("".join(_processed_text))
		_processed_text.clear()
		return
	
	var add_char: = true
	var was_stripped: = false

	var ds: Sequence = _disallowed_seq.front()

	# currently received characters are not potentially disallowed sequence just add them
	if ds.is_potential(full_string):
		add_char = false

		if ds.is_present(full_string):
			
			if ds.command_end:
				shell_prompt = ds.extract_cwd(full_string)

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
			# trim the last new line, and the \r in case we're on windows
			_output_label.text = _output_label.text.trim_suffix("\n").trim_suffix("\r")
			_create_command_output_container()
			_toggle_progress_bar(false)


func _append_output_text(text: String) -> void:
	var remaining_space: int
	var label_length: int = 0
	if _output_label != null:
		label_length = _output_label.text.length()
	remaining_space = MAX_COMMAND_OUTPUT_LENGTH - label_length
	
	if remaining_space < text.length():
		text = text.left(remaining_space)

		# Add the notice that the text was truncated, clear the disallowed sequence array,
		# start the new output container and set the meta so we dont do it again
		if not _output_label.get_meta("truncated", false):
			text += "\n(output truncated)"
			_output_label.set_meta("truncated", true)
			_output_label.text += text
		return


	var full_text: String = ""
	if _output_label != null:
		full_text = _output_label.text + text
		_output_label.text = ASCII_COLOR_CODE_REGEX.sub(full_text, "", true)

## Clears all the terminal content
func clear_terminal() -> void:
	for ch in _output_container.get_children():
		ch.queue_free()

func terminate_process() -> void:
	var output = []
	
	if OS.get_name() == "Windows":
		var exit_code = OS.execute("powershell", [
			"-ExecutionPolicy", "Bypass",
			"-Command",
			"Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq %s } | Select-Object ProcessId,Name | ConvertTo-Json" % pid
		], output)

		if exit_code != 0 or output.is_empty():
			push_error("Couldn't fetch the current subprocess data: Exit code: %s" % exit_code)
			push_error("Couldn't fetch the current subprocess data: Output: %s" % output)
			return

		var data = JSON.parse_string(output[0])

		if data is Dictionary:
			# usually this will be the only one, and we shouldn't terminate this one, or else the terminal will crash
			if data["Name"] == "conhost.exe": return

			_generate_console_ctrl_event(data["ProcessId"])

		elif data is Array:
			
			for process_data: Dictionary in data:
				if process_data["Name"] == "conhost.exe": continue
				
				_generate_console_ctrl_event(process_data["ProcessId"])
	elif OS.get_name() == "Linux":

		var exit_code = OS.execute("pgrep", [
			"-P", pid,
		], output, true)

		if exit_code != 0 or output.is_empty():
			push_error("Couldn't fetch the current subprocess data: Exit code: %s" % exit_code)
			push_error("Couldn't fetch the current subprocess data: Output: %s" % output)
			return

		for output_line in output[0].split("\n"):
			output_line = output_line.strip_edges()
			if not output_line.is_valid_int(): continue

			
			var proc_id: = int(output_line)

			_generate_console_ctrl_event(proc_id)


func _generate_console_ctrl_event(process_id: int) -> void:
	var output = []
	var exit_code: int

	# On windows we'll use the powershell to send the CTRL_BREAK_EVENT signal to the given process
	# https://stackoverflow.com/a/64921030
	if OS.get_name() == "Windows":
		var member_definition: = """
			$MemberDefinition = '
			[DllImport(\\"kernel32.dll\\")]public static extern bool FreeConsole();
			[DllImport(\\"kernel32.dll\\")]public static extern bool AttachConsole(uint p);
			[DllImport(\\"kernel32.dll\\")]public static extern bool GenerateConsoleCtrlEvent(uint e, uint p);
			public static void SendCtrlC(uint p) {
				FreeConsole();
				AttachConsole(p);
				GenerateConsoleCtrlEvent(1, p);
				FreeConsole();
				AttachConsole(uint.MaxValue);
			}'
		"""

		var whole_command: = ("
			%s;
			Add-Type -Name 'Terminal' -Namespace 'Minerva' -MemberDefinition $MemberDefinition;
			[Minerva.Terminal]::SendCtrlC(%s);
		" % [member_definition, process_id]).strip_escapes()

		exit_code = OS.execute("powershell", [
			"-ExecutionPolicy", "Bypass",
			"-Command", whole_command
		], output, true)
	
	elif OS.get_name() == "Linux":
		exit_code = OS.execute(shell, [
			"-c", "kill -s SIGINT %s" % process_id
		], output, true)

	
	if exit_code != 0:
		push_error("Couldn't send CTRL_BREAK_EVENT signal to process %s. Exit code: %s" % [process_id, exit_code])
		push_error("Couldn't send CTRL_BREAK_EVENT signal to process %s. Output: %s" % [process_id, output])


func execute_command(input: String):
	if last_container_checkbutton != null:
		last_container_checkbutton.visible = true
	
	_history[0] = input
	_history.insert(0, "")
	_history_idx = 0

	var command_buffer: PackedByteArray

	# if this array is not empty we didn't reach the end of the previous command yet
	if _disallowed_seq.is_empty():

		command_buffer = (wrap_command.call(input) + "\n").to_utf8_buffer()

		# windows shell outputs the input command, where other shells don't do that
		if OS.get_name() == "Windows":
			_disallowed_seq.append(Sequence.new(wrap_command.call(input), "", "", false, input))
		
		
			_disallowed_seq.append(
				Sequence.new(
					RegEx.create_from_string(WINDOWS_PATH_REGEX_PATTERN),
					delimiter + " \r\n",
					"\r\n" + delimiter,
					true,
					""
				)
			)
		
		else: # Linux
			_disallowed_seq.append(
				Sequence.new(
					RegEx.create_from_string(LINUX_PATH_REGEX_PATTERN),
					delimiter + "\n",
					"\n" + delimiter,
					true,
					""
				)
			)

	else:
		command_buffer = (input + "\n").to_utf8_buffer()
	
	stdio.store_buffer(command_buffer)

	if OS.get_name() == "Linux":
		_append_output_text(shell_prompt + "% " + input + "\n")

	_toggle_progress_bar()


func _toggle_progress_bar(on: bool = true) -> void:
	%TextureProgressBar.value = 100 if on else 0

	var tween: Tween = get_tree().create_tween().set_loops()
	tween.tween_property(%TextureProgressBar, "radial_initial_angle", 360.0, 1.5).as_relative()


func _on_button_pressed():
	if not command_line_edit.text.is_empty():
		execute_command(command_line_edit.text)
		
		command_line_edit.clear()
		_autocomplete_change_input_string("")


func _on_command_line_edit_text_submitted(new_text):
	if not command_line_edit.text.is_empty():
		command_line_edit.clear()
		execute_command(new_text)
		_autocomplete_change_input_string("")


func _on_command_line_edit_text_changed(new_text:String) -> void:
	if _history.is_empty():
		_history.append("")
	else:
		_history[0] = new_text
	
	_autocomplete_change_input_string(new_text)


## iterate over used commands from command history 
func _on_command_line_edit_gui_input(event: InputEvent):
	if event.is_action_pressed("ui_up"):
		if _history_idx < _history.size() - 1:
			_history_idx += 1
			command_line_edit.text = _history[_history_idx]
			
			await get_tree().process_frame
			command_line_edit.caret_column = command_line_edit.text.length()
			accept_event()

	elif event.is_action_pressed("ui_down"):
		if _history_idx > 0:
			_history_idx -= 1
			command_line_edit.text = _history[_history_idx]
			
			await get_tree().process_frame
			command_line_edit.caret_column = command_line_edit.text.length()
			accept_event()

	elif event.is_action_pressed("autocomplete"):
		_autocomplete(not Input.is_key_pressed(KEY_SHIFT))
		accept_event()
	
	elif event.is_action_pressed("cancel"):
		terminate_process()
