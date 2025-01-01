class_name TerminalNew
extends Control

const CURSOR_CHAR: = "█"

var WINDOWS_CWD_REGEX: = RegEx.create_from_string(r"(\r\n)?[a-zA-Z]:[\\\/](?:[a-zA-Z0-9]+[\\\/])*([a-zA-Z0-9]+>)")

@onready var _output_container: ScrollContainer = %OutputContainer
@onready var _check_buttons_container: Control = %CheckButtonsContainer

# var _output_label: TextLayer
var _output_label_nodes: Array[TextLayer]

var terminal:  = WindowsTerminal.new()

var _viewport_start: int = 0
# var _cursor_pos: Vector2i = Vector2i(1, 1)
var _cursor_pos: Vector2i = Vector2i(1, 1):
	set(value):
		print("Cursor position changed from %s to %s" % [_cursor_pos, value])
		print("Real value: %s" % _cursor_pos)

		_cursor_pos = value

		# _cursor_pos = _cursor_pos

		cursor_layer.pos = _cursor_pos

		# var scrollbar: VScrollBar = _output_container.get_v_scroll_bar()

		# scrollbar.value = int((_cursor_pos.x-1) * line_height)

		# _output_container.scroll_vertical = int((_cursor_pos.x-1) * line_height)
		
		cursor_layer.queue_redraw()

var cursor_visible: bool = false

var text_layer: TextLayer
var cursor_layer: CursorLayer

# TODO: use this in subclasses
var font: Font = preload("res://assets/fonts/CascadiaCode/CascadiaCode.ttf")
var font_size: int = ThemeDB.fallback_font_size
var line_height: float
var char_width: float



## Creates new terminal instance
static func create() -> TerminalNew:
	var terminal_instance = preload("res://Scenes/Terminal.tscn").instantiate()
	return terminal_instance



func _ready():
	add_child(terminal)

	var char_metrics = font.get_char_size("M".unicode_at(0), font_size)
	line_height = font.get_height(font_size)  # Use get_height for proper line height
	char_width = char_metrics.x

	var scrollbar: VScrollBar = _output_container.get_v_scroll_bar()


	scrollbar.scrolling.connect(
		func():
			var lines_amount: = floorf(snappedf(scrollbar.value, line_height) / line_height) + 1
			var new_value: = snappedf(scrollbar.value, line_height) + lines_amount
			scrollbar.set_value_no_signal(new_value)
			
			pass# print("NEW VALUE: ", new_value)
			_viewport_start = int(lines_amount) - 1
			print("_viewport_start is now %s" % _viewport_start)
	)

	scrollbar.changed.connect(
		func():
			scrollbar.value = int((_cursor_pos.x-1) * line_height)
			
			var lines_amount: = floorf(snappedf(scrollbar.value, line_height) / line_height) + 1
			_viewport_start = int(lines_amount) - 1
			
			# _output_container.scroll_vertical = int(scrollbar.max_value)
	)



	_create_output_container(false)

	terminal.output_received.connect(_on_output_received)
	# terminal.command_output_end_reached.connect(_create_output_container)
	
	# [25l seq_set_cursor_visible
	# [n;nH seq_cursor_position

	terminal.seq_cursor_home.connect(_set_cursor_position.bind(1, 1))
	terminal.seq_cursor_position.connect(_set_cursor_position)

	

	terminal.seq_erase_character.connect(
		func(count: int):
			pass# print("Delete %s characters at %s" % [count, _cursor_pos])
	)

	terminal.seq_erase_from_cursor_to_end_of_line.connect(
		func():
			text_layer.erase(_cursor_pos.x, _cursor_pos.y)
	)
	
	terminal.seq_set_cursor_visible.connect(
		func(enabled: bool):
			pass# print("Set cursor to: ", enabled)
			cursor_layer.visible = enabled
	)

	terminal.seq_set_foreground_color.connect(_set_color)
	terminal.seq_set_background_color.connect(_set_background_color)
	terminal.seq_reset_graphics.connect(_reset_graphics)

	# terminal.title_changed.connect(DisplayServer.window_set_title)

	await get_tree().process_frame


	pass# print(size)
	pass# prints(int(size.y / line_height), int(size.x / char_width))

	var a = terminal.start(int(size.x / char_width), int(size.y / line_height))
	
	pass# print(a)

	# terminal.start(size.y, size.x)

	resized.connect(
		func():
			pass# print("Terminal resized to %s" % Vector2(int(size.y / line_height), int(size.x / char_width)))
			terminal.resize(int(size.x / char_width), int(size.y / line_height))
	)

func _create_output_container(_next: = true) -> void:
	
	var hbox: = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_check_buttons_container = Control.new()
	_check_buttons_container.custom_minimum_size.x = 32

	text_layer = TextLayer.new()
	text_layer.terminal = self
	text_layer.font = font
	
	cursor_layer = CursorLayer.new()
	cursor_layer.font = font

	
	text_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cursor_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	
	text_layer.add_child(cursor_layer)

	hbox.add_child(_check_buttons_container)
	hbox.add_child(text_layer)

	_output_container.add_child(hbox)

	_output_label_nodes.append(text_layer)

func _create_check_button(offset: float) -> void:
	print(offset)
	var btn = CheckButton.new()

	# var ctrl = Control.new()
	# ctrl.custom_minimum_size.y = offset - 8
	# _check_buttons_container.add_child(ctrl)


	btn.position.y = offset
	_check_buttons_container.add_child(btn)

func _on_output_received(text: String, type: WindowsTerminal.Type) -> void:
	# text = text.replace("\r\n", "\n") # TODO: handle \r\n on windows
	
	pass# print("\n\n_on_output_received: '%s'" % text.c_escape())

	var matches: = WINDOWS_CWD_REGEX.search_all(text)
	
	if not matches.is_empty():
		for match_ in matches:
			text_layer.add_background_color(Color.RED, _cursor_pos)
			_create_check_button((_cursor_pos.x + text.count("\n", match_.get_start(), match_.get_end()) -1) * line_height)
			print("Added check button at %s" % _cursor_pos.x)
		

	if type == WindowsTerminal.Type.TEXT:

		# TODO: buffer the text, split by \n \b or smth
		for i in text.length():
			var char_: = text[i]


			
			# if not (char_ == "\b" or char_ == "\n"):
			
			if char_ == "\r":

				# find next \r or \n
				# var next_r_idx: = text.find("\r", i+1)
				# var next_n_idx: = text.find("\n", i+1)

				# var idx: int = text.length()

				# if next_r_idx == -1 and next_n_idx == -1:
				# 	idx = text.length()
				# elif next_r_idx == -1:
				# 	idx = next_n_idx
				# elif next_n_idx == -1:
				# 	idx = next_r_idx
				# else:
				# 	idx = mini(next_r_idx, next_n_idx)

				# for modifier_key in text_layer.content_modifiers.keys().filter(
				# 	func(modifier_pos: Vector2i):
				# 		pass# print("Going through modifier at %s, while cursor is at %s and idx is %s" % [modifier_pos, _cursor_pos, idx])
				# 		return modifier_pos.y == _cursor_pos.x-1 and modifier_pos.x < idx
				# ):
				# 	pass# print("Deleting modifier at '%s' on line %s after '\\r'" % [modifier_key, i])
				# 	text_layer.content_modifiers.erase(modifier_key)

				_cursor_pos = Vector2i(_cursor_pos.x, 1)
				
				continue

			elif char_ == "\n":
				# text_layer.add_text(char_, _cursor_pos)
				print("char is \\n, going to next line")
				prints(_cursor_pos, Vector2i(_cursor_pos.x+1, _cursor_pos.y))
				_cursor_pos = Vector2i(_cursor_pos.x+1, _cursor_pos.y)
				# _cursor_pos = Vector2i(_cursor_pos.x+1, 1)
				continue
			
			elif char_ == "\b":
				_cursor_pos.y -= 1
				_cursor_pos = _cursor_pos
				continue
			
			pass# print("Adding %s to %s" % [char_.c_escape(), _cursor_pos])
			text_layer.add_text(char_, _cursor_pos)

			_cursor_pos.y += char_.length()
			_cursor_pos = _cursor_pos

		if not matches.is_empty():
			text_layer.add_background_color(Color.TRANSPARENT, _cursor_pos)
			text_layer.queue_redraw()



func _parse_bbcode_tag(text: String) -> Dictionary:
	var regex = RegEx.create_from_string("\\[(\\w+)(.*?)\\](.*?)\\[/\\1\\]")
	var result = regex.search(text)
	if not result:
		return {}

	var tag_data = {
		"tag": result.get_string(1),
		"params": {},
		"content": result.get_string(3)
	}
   
	var params = result.get_string(2).strip_edges()
	if params:
		var param_regex = RegEx.create_from_string("(\\w+)=([^\\s]+)")
		var param_matches = param_regex.search_all(params)
		for match in param_matches:
			tag_data["params"][match.get_string(1)] = match.get_string(2)

	return tag_data



# region cursor


func _set_cursor_position(row: int, column: int) -> void:
	_cursor_pos = Vector2i(row + _viewport_start, column)

	print("Set cursor position to %s..." % _cursor_pos)
	# _update_cursor_position()


# endregion



# region graphics

class BbcodeTag extends RefCounted:
	var name: String
	var parameters: Dictionary
	var params_string: String

	func _init(name_: String, parameters_: Dictionary) -> void:
		name = name_
		parameters = parameters_
		parameters.make_read_only()

		params_string = _get_params_string()

	func _get_params_string() -> String:
		return " ".join(
			parameters.keys().map(
				func(key: String): return "%s=%s" % [key, parameters[key]]
			)
		)

	func get_opening_tag() -> String:
		if not name.is_empty():
			return "[%s %s]" % [name, params_string]
		else:
			return "[%s]" % [params_string]

	func get_closing_tag() -> String:
		return "[/%s]" % [parameters.keys().front() if name.is_empty() else name]

	func _to_string() -> String:
		return get_opening_tag()


func _set_color(color: Color) -> void:
	text_layer.add_color(color, _cursor_pos)

func _set_background_color(color: Color) -> void:
	text_layer.add_background_color(color, _cursor_pos)

func _reset_graphics() -> void:
	text_layer.add_color(Color.WHITE, _cursor_pos)
	text_layer.add_background_color(Color.TRANSPARENT, _cursor_pos)

# endregion

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		# Handle modifier key combinations first
		if event.ctrl_pressed:
			match event.keycode:
				KEY_C: # Copy
					terminal.write_input(char(3))  # CTRL+C sends ETX
				KEY_V: # Paste
					terminal.write_input(DisplayServer.clipboard_get())
				KEY_Z: # CTRL+Z
					terminal.write_input(char(26))  # SUB character

		# Handle navigation and editing keys
		else:
			match event.keycode:
				KEY_ENTER:
					terminal.write_input("\r\n")
				KEY_BACKSPACE:
					terminal.write_input(char(8))
				KEY_ESCAPE:
					terminal.write_input(char(27))
				KEY_DELETE:
					terminal.write_input(char(27) + "[3~")  # Delete key sequence
				KEY_LEFT:
					terminal.write_input(char(27) + "[D")  # Cursor left
				KEY_RIGHT:
					terminal.write_input(char(27) + "[C")  # Cursor right
				KEY_UP:
					terminal.write_input(char(27) + "[A")  # Cursor up (command history)
				KEY_DOWN:
					terminal.write_input(char(27) + "[B")  # Cursor down (command history)
				KEY_HOME:
					terminal.write_input(char(27) + "[H")  # Move to start of line
				KEY_END:
					terminal.write_input(char(27) + "[F")  # Move to end of line
				
				# Function keys F1-F9
				KEY_F1:
					terminal.write_input(char(27) + "[11~")  # or char(27) + "[11~"
				KEY_F2:
					terminal.write_input(char(27) + "[12~")  # or char(27) + "[12~"
				KEY_F3:
					terminal.write_input(char(27) + "[13~")  # or char(27) + "[13~"
				KEY_F4:
					terminal.write_input(char(27) + "[14~")  # or char(27) + "[14~"
				KEY_F5:
					terminal.write_input(char(27) + "[15~")
				KEY_F6:
					terminal.write_input(char(27) + "[17~")
				KEY_F7:
					terminal.write_input(char(27) + "[18~")
				KEY_F8:
					terminal.write_input(char(27) + "[19~")
				KEY_F9:
					terminal.write_input(char(27) + "[20~")
				KEY_F10:
					terminal.write_input(char(27) + "[21~")
				KEY_F11:
					terminal.write_input(char(27) + "[23~")
				KEY_F12:
					terminal.write_input(char(27) + "[24~")
				_:
					if event.unicode > 0:
						terminal.write_input(char(event.unicode))
		
		get_viewport().set_input_as_handled()


class Modifier extends RefCounted:
	var callables: Array[Callable]
	var name: String = "Modifier"

	func _init(callables_: Array[Callable]) -> void:
		callables = callables_

	func _to_string() -> String:
		return name

	func add_callable(callable: Callable):
		callables.append(callable)

	func apply():
		for callable in callables:
			callable.call()

class CursorLayer extends Control:
	
	var blink_time: float = 0.5
	var elapsed: float = 0
	var cursor_visible: = true
	var pos: Vector2i

	var font: Font = load("res://assets/fonts/Mono_Space/SpaceMono-Regular.ttf")
	var font_size: int = ThemeDB.fallback_font_size
	var line_height: float
	var char_width: float


	func _ready() -> void:
		
		# Get metrics using get_char_size for 'M' which is typically the widest character
		var char_metrics = font.get_char_size(" ".unicode_at(0), font_size)
		line_height = font.get_height(font_size)  # Use get_height for proper line height
		char_width = char_metrics.x

		queue_redraw()

	# TODO: don't process if the cursor is hidden
	func _process(delta: float) -> void:
		elapsed += delta

		if elapsed > 0.5:
			elapsed = 0
			cursor_visible = not cursor_visible
			queue_redraw()


	func _draw() -> void:

		if cursor_visible:
			var draw_pos = Vector2((pos.y-1) * char_width, (pos.x) * line_height)

			# draw_pos = Vector2i(char_width, line_height)

			draw_string(font, draw_pos, CURSOR_CHAR, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			# pass# print("Draw cursor at %s" % draw_pos)
			# draw_rect(Rect2(draw_pos, Vector2(char_width, line_height)), Color.WHITE)
		
			custom_minimum_size.y = draw_pos.y



class TextLayer extends Control:
	

	var terminal: TerminalNew
	var font: Font
	var font_size: int = ThemeDB.fallback_font_size
	var line_height: float
	var char_width: float

	var _foreground_color: = Color.WHITE
	var _background_color: = Color.TRANSPARENT

	var _modifier_queue: Array[Modifier]

	func _ready() -> void:
		
		var char_metrics = font.get_char_size(" ".unicode_at(0), font_size)
		line_height = font.get_height(font_size)  # Use get_height for proper line height
		char_width = char_metrics.x

		# var terminal_size: = Vector2i(int(terminal.size.x / char_width), int(terminal.size.y / line_height))
		
		# for row in terminal_size.y:
		# 	content.append("".rpad(terminal_size.x, " "))

		queue_redraw()


	var content: Array[Array] = [
		# [" ", " ", " ", " ", " ", " ", "A", "A", "A", "A", "A", "A", "A", "A", "A", "A", "A"]
	]

	var content_modifiers: Dictionary = {}


	func add_color(color: Color, _at: Vector2i) -> void:

		pass# print("Adding color modifier at %s" % at)

		var modifier_callable: = func(): print("Changed color to: ", color); _foreground_color = color

		var modifier: = Modifier.new([modifier_callable])
		modifier.name += ";fgr_color: %s" % color

		_modifier_queue.append(modifier)

		# _add_modifier_content_part(modifier_callable, at)

		# at = Vector2i(at.y-1, at.x-1)
		
		# pass# print("Added color (%s) modifier at %s" % [color, at])

		# _modifier_queue.append(func(): pass# print("Changed color to: ", color); _foreground_color = color)
	

	func add_background_color(color: Color, _at: Vector2i) -> void:

		# at = Vector2i(at.y-1, at.x-1)
		
		pass# print("Added background color (%s) modifier at %s" % [color, at])

		var modifier_callable: = func(): print("Changed background color to: ", color); _background_color = color
		
		var modifier: = Modifier.new([modifier_callable])
		modifier.name += ";bgr_color: %s" % color

		_modifier_queue.append(modifier)

		# _add_modifier_content_part(modifier_callable, at)


	func _add_string_content_part(part: String, at: Vector2i) -> void:
		if at.x > content.size():
			for i in range(at.x - content.size()):
				content.append([])
		
		pass# print("Adding part '%s' at %s" % [part, at])

		var line_content: Array = content[at.x-1]

		var total: = 0

		var last_string_part_idx: = -1
		for i in range(line_content.size()-1, -1, -1):
			if line_content[i] is String:
				last_string_part_idx = i
				break
		
		if last_string_part_idx == -1:
			var padded: =  "".rpad(at.y-total, char(10240))
			padded[at.y-total-1] = part
			line_content.append(padded)

		else:
			for i in range(line_content.size()):
				var line_part = line_content[i]
				pass# print("ex 1: %s %s" % [total, at.y])
				
				if line_part is String:
					pass# print("ex 2: %s %s" % [total, at.y])
					if total + line_part.length() >= at.y:
						pass# print("Adding '%s' to '%s' at position %s" % [part, line_part, at.y-total-1])
						line_part[at.y-total-1] = part
						line_content[i] = line_part
						break
										
					# if we're on last i and we didnt add the text
					elif i == line_content.size()-1:
						pass# print("ex r: %s %s %s" % [line_content.size(), i, last_string_part_idx])

						# if string is the last element, append the new one
						if i == last_string_part_idx:
							line_part = line_part.rpad(at.y-total, char(10240))
							line_part[at.y-total-1] = part
						else:
							var padded: =  "".rpad(at.y-total, char(10240))
							padded[at.y-total-1] = part
							line_content.append(padded)

					total += line_part.length()
				
				elif line_part is Modifier:
					pass# print("line_part is Modifier")
					pass# prints(last_string_part_idx)

					# if we're not on the last one just skip it
					if i == line_content.size()-1:
						
						var padded: =  "".rpad(at.y-total, char(10240))
						padded[at.y-total-1] = part
						line_content.append(padded)
			
				line_content[i] = line_part
				

		content[at.x-1] = line_content
		pass# print(line_content)
	
	func _add_modifier_content_part(part: Modifier, at: Vector2i) -> void:
		if at.x > content.size():
			for i in range(at.x - content.size()):
				content.append([])
		
		pass# print("Adding part '%s' at %s" % [part, at])

		var line_content: Array = content[at.x-1]

		var total: = 0

		var last_modifier_part_idx: = -1
		for i in range(line_content.size()-1, -1, -1):
			if line_content[i] is Modifier:
				last_modifier_part_idx = i
				break
		
		if last_modifier_part_idx == -1:
			# line_content.append("".rpad(at.y-total-1)) # breaks it :(
			line_content.append(part)

		else:
			for i in range(line_content.size()):
				var line_part = line_content[i]
				pass# print("ex 1: %s %s" % [total, at.y])
				
				if line_part is String:
					pass# print("ex 2: %s %s" % [total, at.y])
					
					if total + line_part.length() >= at.y:
						
						# check if we're on first char of the string, and just add modifier before it

						if at.y-total-1 == 0:
							pass# print("Prepending the modifier")
							line_content.insert(i, part)
							break

						# if this is the case, devide the string into two and insert the modifier inbetween

						pass# print("Splitting '%s' into two strings" % line_part.c_escape())

						var p1: String = line_part.substr(0, at.y-total-1)
						var p2: String = line_part.substr(at.y-total-1)
						pass# prints(p1.c_escape(), p2.c_escape())

						line_content.remove_at(i)

						line_content.insert(i, p2)
						line_content.insert(i, part)
						line_content.insert(i, p1)

						break
					
					# if we're on last i and we didnt add the modifier
					elif i == line_content.size()-1:
						total += line_part.length()
						# since we didn't reach the cursor position, add a padded string to reach it

						line_content.append("".rpad(at.y-total-1))
						line_content.append(part)
						break

						# TODO: rpad a string, then add a modifier
						# if i == last_modifier_part_idx:
						# 	line_part.append(part)
						# else:
						# 	line_content.append(part)

					total += line_part.length()
				
				elif line_part is Modifier:
					pass# print("line_part is Modifier")
					pass# prints(last_modifier_part_idx)

					# if we're not on the last one just skip it
					if i == line_content.size()-1:
						if at.y-total > 0:
							line_content.append("".rpad(at.y-total-1))
							line_content.append(part)
						else:
							line_part.add_callable(part)


						# TODO: rpad this
						# line_part = line_part.rpad(at.y-total, char(10240))
			
				line_content[i] = line_part
				

		content[at.x-1] = line_content

		pass# print(line_content)


	func add_text(text: String, at: Vector2i) -> void:

		for mod in _modifier_queue:
			_add_modifier_content_part(mod, at)
		_modifier_queue.clear()
		
		_add_string_content_part(text, at)

		queue_redraw()
	

	func erase(row: int, from: int, length: int = -1) -> void:
		print("\nErasing.")
		prints(row, from, length)
		
		if row-1 > content.size()-1:
			prints("Cant erase", row, content.size())		
			return

		
		if from == 1 and length == -1: # just delete the whole line right away
			print("Deleting whole line ", content[row-1])
			content[row-1] = []
			queue_redraw()
			return


		from -= 1

		var line_content: = content[row-1]
		var line_content_copy: = line_content.duplicate(true)

		var offset: = 0

		print("offset: ", offset)
		print("from: ", from)
		print("length: ", length)

		print("Erasing line content '%s'" % str(line_content))

		var total: = 0
		var delete_to: = -1 if length == -1 else from + length
		var deleting: = false

		for i in range(line_content.size()):
			var line_part = line_content[i]

			print("line_part: ", line_part)

			if line_part is String:
				total += line_part.length()
				print("Total is now %s" % total)

				# if we reach the point where we start deleting
				if not deleting and from < total-1:
					print("Not deleting and from < total-1")
					var from_rel: = from
					
					var actl = line_part.length()-from_rel if length == -1 else length

					if from_rel + actl >= line_part.length():
						print("Must delete in next parts, deleting = true")
						var chars = max(0, line_part.length()-from_rel) if length == -1 else length
						line_part = line_part.erase(from_rel, chars)
						print("line part is now '%s'" % line_part.c_escape())
						deleting = true
						line_content[i] = line_part
						continue
					else:
						var chars = max(0, line_part.length()-from_rel) if length == -1 else length
						
						line_part = line_part.erase(from_rel, chars)
						print("line part is now '%s'" % line_part.c_escape())
						print(from_rel, length)
						line_content[i] = line_part
						print("break")
						break

				if deleting:
					print("deleting...")
					if delete_to == -1:
						print("Deleting the whole part")
						line_part = ""
					else:
						print("Deleting part of string")
						if delete_to <= total-1:
							line_part = line_part.erase(0, total-1-delete_to)
							print("line part is now '%s'" % line_part.c_escape())
						else:
							print("Deleting whole string, deleting = false")
							line_part = ""
							deleting = false

				if line_part.is_empty():
					line_part = null

				line_part = line_part

			elif line_part is Modifier:
				if deleting:
					line_part = null
			
			line_content[i] = line_part

		content[row-1] = line_content.filter(func(element): return element != null)

		queue_redraw()

		return


		for i in range(line_content.size()):
			var line_part = line_content[i]

			if line_part is String:
				pass# print("Line part is '%s'" % line_part.c_escape())
				deleting = false
				
				var from_rel: = from - offset
				var to_rel: int = line_part.length() if length == -1 else length - offset

				pass# print("from_rel: ", from_rel)
				pass# print("to_rel: ", to_rel)
				pass# print("line_part.length(): ", line_part.length())

				from_rel = max(from_rel, 0)

				if from_rel == 0:
					pass

				if from_rel < line_part.length():
					deleting = true
					offset += line_part.length()
					line_part = line_part.erase(from_rel, to_rel)
					line_content_copy[i] = line_part

					pass# print("After erasing: '%s'" % line_content_copy[i].c_escape())

					if to_rel < line_part.length()-1:
						deleting = false
						break # end reached
				else:
					offset += line_part.length()
				pass# print("offset is now: ", offset)
			
			elif deleting and line_part is Modifier:
				pass# print("DELETING MODIFIER")
				pass# print(line_content_copy[i])
				line_content_copy[i] = null

		content[row-1] = line_content_copy.filter(func(element): return element != null)

		queue_redraw()
		

		# pass# print("Erasing (%s, %s) to %s on line %s..." % [row, from, to, content[row-1].c_escape()])
		
		# if to == -1:
		# 	to = content[row-1].length() - (from-1)
		

		# content[row-1] = content[row-1].erase(from-1, to)
		# content[row-1] = content[row-1].insert(from-1, " ".repeat(to-(from-1)))
		# pass# print("Result: ", content[row-1].c_escape())
		
		# var to_delete: = content_modifiers.keys().filter(
		# 	func(modifier_pos: Vector2i):
		# 		return modifier_pos.y == row-1 and modifier_pos.x >= from-1 and modifier_pos.x <= from-1 + to
		# )
		
		# for key in to_delete:
		# 	content_modifiers.erase(key)

		# queue_redraw()

	func _draw() -> void:

		_foreground_color = Color.WHITE
		_background_color = Color.TRANSPARENT
		
		var pos: = Vector2(0, 1)  # Start at first line


		for line_parts in content:
			# print(line_parts)
			for part in line_parts:
				if part is String:
					var string_pos: = pos * Vector2(char_width, line_height)

					var start: = 0
					for i in range(part.length()):

						if part[i] == char(10240) or i == part.length()-1:
							if i > start+1:
								var background_rect: = Rect2(
									(pos + Vector2(start, 0)) * Vector2(char_width, line_height),
									Vector2((i-start+1)*char_width, -line_height)
								)
								
								draw_rect(background_rect, _background_color)
							start = i+1

					print(part)
					draw_string(font, string_pos, part, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _foreground_color)
					
					
					pos.x += part.length()
				
				if part is Modifier:
					print("Applying part: ", part)
					part.apply()

			pos.y += 1
			pos.x = 0
		
		custom_minimum_size.y = pos.y * line_height
		return

		# for i in range(content.size()):
		# 	pass# print(content[i])

		# for i in range(content.size()):
		# 	var line: = content[i]

		# 	var line_modifier_keys: = content_modifiers.keys().filter(
		# 		func(modifier_pos: Vector2i):
		# 			return modifier_pos.y == i
		# 	)

		# 	if line_modifier_keys.is_empty():
		# 		# pass# print("Drawing '%s' at %s" % [line.c_escape(), pos])
		# 		draw_string(font, pos * Vector2(char_width, line_height), line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _foreground_color)
		# 		pos.y += 1
		# 		pos.x = 0
		# 		continue

		# 	pass# print("\n")

		# 	var offset: = 0
			
		# 	for key in line_modifier_keys:
		# 		var part: = line.substr(offset, key.x-offset)

		# 		pass# print("Drawing '%s' at %s" % [part.c_escape(), pos])
		# 		draw_string(font, pos * Vector2(char_width, line_height), part, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _foreground_color)


		# 		pass# print("Processing modifier at position %s" % key)
		# 		for modifier_callable in content_modifiers[key]:
		# 			modifier_callable.call()
				
		# 		pass# print("Line before the modifier is: '%s'" % part.c_escape())
		# 		pass# print("with color: ", _foreground_color)
				
		# 		pos.x += part.length()
		# 		offset += part.length()


		# 	if pos.x < line.length()-1:
		# 		draw_string(font, pos * Vector2(char_width, line_height), line.substr(pos.x, -1), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _foreground_color)
			
		# 	pass# print("\n")
		# 	pos.y += 1
		# 	pos.x = 0
		
		# custom_minimum_size.y = pos.y * line_height

		return
