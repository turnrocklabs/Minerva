class_name TerminalNew
extends Control

const CURSOR_CHAR: = "█"

var WINDOWS_CWD_REGEX: = RegEx.create_from_string(r"(\r\n)?[a-zA-Z]:[\\\/](?:[a-zA-Z0-9]+[\\\/])*([a-zA-Z0-9\s-]+>)")

@onready var _output_container: ScrollContainer = %OutputContainer
@onready var _check_buttons_container: Control = %CheckButtonsContainer

var _output_label_nodes: Array[TextLayer]

var terminal:  = Terminal.new()


var _viewport_start: int = 0
var _cursor_pos: Vector2i = Vector2i(1, 1):
	set(value):
		_cursor_pos = value
		cursor_layer.pos = _cursor_pos
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

func _update_font_metrics():
	var char_metrics = font.get_char_size("M".unicode_at(0), font_size)
	line_height = font.get_height(font_size)
	char_width = char_metrics.x

func _ready():
	add_child(terminal)

	visibility_changed.connect(
		func():
			if is_visible_in_tree():
				grab_focus()
	)

	_update_font_metrics()

	var scrollbar: VScrollBar = _output_container.get_v_scroll_bar()


	scrollbar.scrolling.connect(
		func():
			var lines_amount: = floorf(snappedf(scrollbar.value, line_height) / line_height) + 1
			var new_value: = snappedf(scrollbar.value, line_height) + lines_amount
			scrollbar.set_value_no_signal(new_value)
			
			_viewport_start = int(lines_amount) - 1
	)

	scrollbar.changed.connect(
		func():
			scrollbar.value = int((_cursor_pos.x-1) * line_height)
			
			var lines_amount: = floorf(snappedf(scrollbar.value, line_height) / line_height) + 1
			_viewport_start = int(lines_amount) - 1
	)

	_create_output_container()

	terminal.output_received.connect(_on_output_received)

	terminal.seq_cursor_home.connect(_set_cursor_position.bind(1, 1))
	terminal.seq_cursor_position.connect(_set_cursor_position)

	terminal.seq_erase_character.connect(
		func(_count: int):
			pass # print("Delete %s characters at %s" % [count, _cursor_pos])
	)

	terminal.seq_erase_from_cursor_to_end_of_line.connect(
		func():
			text_layer.erase(_cursor_pos.x, _cursor_pos.y)
	)

	terminal.seq_erase_entire_screen.connect(
		func(): text_layer.erase_screen()
	)
	
	terminal.seq_set_cursor_visible.connect(
		func(enabled: bool):
			cursor_layer.visible = enabled
	)

	terminal.on_shell_prompt_start.connect(
		func():
			_create_check_button((_cursor_pos.x -1))
	)

	terminal.on_shell_prompt_end.connect(
		func():
			_create_check_button((_cursor_pos.x -1))
	)

	terminal.seq_set_foreground_color.connect(_set_color)
	terminal.seq_set_background_color.connect(_set_background_color)
	terminal.seq_reset_graphics.connect(_reset_graphics)

	# terminal.title_changed.connect(DisplayServer.window_set_title)

	await get_tree().process_frame

	terminal.start(int(size.x / char_width), int(size.y / line_height))
	
	resized.connect(
		func():
			terminal.resize(int(size.x / char_width), int(size.y / line_height))
	)

func _create_output_container() -> void:
	var hbox: = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_check_buttons_container = Control.new()
	_check_buttons_container.custom_minimum_size.x = 32

	text_layer = TextLayer.new()
	text_layer.terminal = self
	
	cursor_layer = CursorLayer.new()
	cursor_layer.terminal = self

	
	text_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cursor_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	
	text_layer.add_child(cursor_layer)

	hbox.add_child(_check_buttons_container)
	hbox.add_child(text_layer)

	_output_container.add_child(hbox)

	_output_label_nodes.append(text_layer)

func _create_check_button(row: float) -> void:
	var btn = CheckButton.new()
	btn.set_meta("row", row)

	btn.toggled.connect(_on_check_button_toggled.bind(btn))

	btn.position.y = row * line_height
	_check_buttons_container.add_child(btn)


func _on_check_button_toggled(toggled_on: bool, btn: CheckButton):
	var item: MemoryItem

	if not btn.has_meta("memory_item"):
		item = MemoryItem.new()
		item.Title = "Terminal Note"
		
		# content will be every line from this check buttons row to next check button
		# if theres no next check button, got untill the end

		item.Content = ""

		var last: CheckButton

		for i in range(_check_buttons_container.get_child_count()-1, -1, -1):
			var ch = _check_buttons_container.get_child(i)
			if ch is CheckButton:
				# break when we reach btn that was toggled
				if ch == btn:
					break
				
				last = ch

		var last_line: int

		# if this IS the last check button go until the end
		if not last or btn == last:
			last_line = text_layer.content.size()
		else:
			last_line = last.get_meta("row")+1
		
		for i in range(btn.get_meta("row"), last_line):
			item.Content += "\n"
			for line_part in text_layer.content[i]:
				if line_part is String:
					item.Content += line_part

		item.toggled.connect(
			(func(on: bool, btn: CheckButton):
				btn.button_pressed = on).bind(btn)
		)

		btn.set_meta("memory_item", item)
		SingletonObject.DetachedNotes.append(item)
	else:
		item = btn.get_meta("memory_item")
		var present = SingletonObject.DetachedNotes.any(func(item_: MemoryItem): return item_ == item)

		if not present:
			SingletonObject.DetachedNotes.append(item)

	item.Enabled = toggled_on


func _on_output_received(text: String, type: Terminal.Type) -> void:
	var matches: = WINDOWS_CWD_REGEX.search_all(text)

	# check if last check button is toggled on and update the content

	var ch: CheckButton

	if _check_buttons_container.get_child_count() > 0:
		ch = _check_buttons_container.get_child(_check_buttons_container.get_child_count()-1)

	# FIXME: if theres a prompt in text, some content of next command will end up in here
	if ch and ch.button_pressed:
		(ch.get_meta("memory_item") as MemoryItem).Content += text


	
	if not matches.is_empty():
		for match_ in matches:
			_create_check_button((_cursor_pos.x + text.count("\n", match_.get_start(), match_.get_end()) -1))
		

	if type == Terminal.Type.TEXT:

		# TODO: buffer the text, split by \n \b or smth
		for i in text.length():
			var char_: = text[i]

			if char_ == "\r":
				_cursor_pos = Vector2i(_cursor_pos.x, 1)
				
				continue

			elif char_ == "\n":
				# if we're on linux also move to the beginning of the line
				if OS.get_name() == "Linux":
					_cursor_pos = Vector2i(_cursor_pos.x, 1)

				_cursor_pos = Vector2i(_cursor_pos.x+1, _cursor_pos.y)
				continue
			
			elif char_ == "\b":
				_cursor_pos.y -= 1
				_cursor_pos = _cursor_pos
				continue
			
			text_layer.add_text(char_, _cursor_pos)

			_cursor_pos.y += char_.length()
			_cursor_pos = _cursor_pos

		if not matches.is_empty():
			text_layer.queue_redraw()


# region cursor


func _set_cursor_position(row: int, column: int) -> void:
	_cursor_pos = Vector2i(row + _viewport_start, column)

	pass # print("Set cursor position to %s..." % _cursor_pos)

# endregion



# region graphics

func _set_color(color: Color) -> void:
	text_layer.add_color(color, _cursor_pos)

func _set_background_color(color: Color) -> void:
	text_layer.add_background_color(color, _cursor_pos)

func _reset_graphics() -> void:
	text_layer.add_color(Color.WHITE, _cursor_pos)
	text_layer.add_background_color(Color.TRANSPARENT, _cursor_pos)

# endregion

func _shortcut_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if not event.is_pressed(): return

		if event.ctrl_pressed and event.keycode == KEY_C:
			DisplayServer.clipboard_set(text_layer.get_selected_text())
			
		if event.ctrl_pressed and event.keycode == KEY_V:
			terminal.write_input(DisplayServer.clipboard_get())
			

func _gui_input(event: InputEvent) -> void:
	
	# if there's selected text ignore the event
	if text_layer.selection_active:
		if event is InputEventKey:
			if not (event.keycode == KEY_CTRL or event.keycode == KEY_ALT):
				text_layer.reset_selection.call_deferred()

		return

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


class  Modifier extends RefCounted:
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
	var terminal: TerminalNew
	var blink_time: float = 0.5
	var elapsed: float = 0
	var cursor_visible: = true
	var pos: Vector2i


	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS

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
			var draw_pos = Vector2((pos.y-1) * terminal.char_width, (pos.x) * terminal.line_height)
			draw_string(terminal.font, draw_pos, CURSOR_CHAR, HORIZONTAL_ALIGNMENT_LEFT, -1, terminal.font_size)
			custom_minimum_size.y = draw_pos.y



class TextLayer extends Control:
	var terminal: TerminalNew

	var _foreground_color: = Color.WHITE
	var _background_color: = Color.TRANSPARENT
	var _selection_background_color: = Color.WHITE_SMOKE

	var _modifier_queue: Array[Modifier]

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = CursorShape.CURSOR_IBEAM

		queue_redraw()

	var selection_active: bool:
		get: return abs(_selection_start - _selection_end) > Vector2i.ZERO

	var _selecting: = false
	var _selection_start: Vector2i
	var _selection_end: Vector2i
	var p1: Vector2i
	var p2: Vector2i

	func reset_selection():
		_selection_start = Vector2i.ZERO
		_selection_end = Vector2i.ZERO
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if _selecting:
			accept_event()

		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_selecting = event.is_pressed()
			accept_event()

			if not _selecting: return

			var row: = maxi(0, floori(event.position.y / terminal.line_height))
			var column: = maxi(0, floori(event.position.x / terminal.char_width))

			p1 = Vector2i(column, row)
			p2 = p1

			var check = func(a, b):
				return a.y < b.y or (a.y == b.y and a.x < b.x)
			
			_selection_start = p1 if check.call(p1, p2) else p2
			_selection_end = p1 if check.call(p2, p1) else p2

			_selecting = event.is_pressed()

			queue_redraw()
			
		
		if _selecting:
			if event is InputEventMouseMotion:
				var row: = maxi(0, floori(event.position.y / terminal.line_height))
				var column: = maxi(0, floori(event.position.x / terminal.char_width))

				p2 = Vector2i(column, row)

				var check = func(a, b):
					return a.y < b.y or (a.y == b.y and a.x < b.x)
				
				_selection_start = p1 if check.call(p1, p2) else p2
				_selection_end = p1 if check.call(p2, p1) else p2

				queue_redraw()
		
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed == false:
				_create_context_menu(event.global_position)


	var content: Array[Array] = []

	var content_modifiers: Dictionary = {}


	func add_color(color: Color, _at: Vector2i) -> void:
		var modifier_callable: = func(): _foreground_color = color

		var modifier: = Modifier.new([modifier_callable])
		modifier.name += ";fgr_color: %s" % color

		_modifier_queue.append(modifier)

	func add_background_color(color: Color, _at: Vector2i) -> void:
		var modifier_callable: = func(): _background_color = color
		
		var modifier: = Modifier.new([modifier_callable])
		modifier.name += ";bgr_color: %s" % color

		_modifier_queue.append(modifier)


	func _add_string_content_part(part: String, at: Vector2i) -> void:
		pass # print("Adding '%s' at %s" % [part.c_escape(), at])
		if at.x > content.size():
			for i in range(at.x - content.size()):
				content.append([])

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
				
				if line_part is String:
					if total + line_part.length() >= at.y:
						line_part[at.y-total-1] = part
						line_content[i] = line_part
						break
										
					# if we're on last i and we didnt add the text
					elif i == line_content.size()-1:

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
					# if we're not on the last one just skip it
					if i == line_content.size()-1:
						
						var padded: =  "".rpad(at.y-total, char(10240))
						padded[at.y-total-1] = part
						line_content.append(padded)
			
				line_content[i] = line_part
				

		content[at.x-1] = line_content
	

	func _add_modifier_content_part(part: Modifier, at: Vector2i) -> void:
		if at.x > content.size():
			for i in range(at.x - content.size()):
				content.append([])
		
		var line_content: Array = content[at.x-1]

		var total: = 0

		var last_modifier_part_idx: = -1
		for i in range(line_content.size()-1, -1, -1):
			if line_content[i] is Modifier:
				last_modifier_part_idx = i
				break
		
		if last_modifier_part_idx == -1:
			line_content.append(part)

		else:
			for i in range(line_content.size()):
				var line_part = line_content[i]
				
				if line_part is String:
					
					if total + line_part.length() >= at.y:			
						# check if we're on first char of the string, and just add modifier before it

						if at.y-total-1 == 0:
							line_content.insert(i, part)
							break

						# if this is the case, devide the string into two and insert the modifier inbetween
						var p1: String = line_part.substr(0, at.y-total-1)
						var p2: String = line_part.substr(at.y-total-1)

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

					total += line_part.length()
				
				elif line_part is Modifier:
					# if we're not on the last one just skip it
					if i == line_content.size()-1:
						if at.y-total > 0:
							line_content.append("".rpad(at.y-total-1))
							line_content.append(part)
						else:
							line_part.add_callable(part)

				line_content[i] = line_part
				

		content[at.x-1] = line_content

	func add_text(text: String, at: Vector2i) -> void:

		for mod in _modifier_queue:
			_add_modifier_content_part(mod, at)
		_modifier_queue.clear()
		
		_add_string_content_part(text, at)

		queue_redraw()
	

	## Erases everything displayed
	func erase_screen() -> void:
		content = []

		# remove all check buttons
		for ch in terminal._check_buttons_container.get_children(): ch.queue_free()

		queue_redraw()

	func erase(row: int, from: int, length: int = -1) -> void:
		pass # print("\nErasing.")
		pass # prints(row, from, length)

		# remove check buttons first
		for ch in terminal._check_buttons_container.get_children():
			if ch is CheckButton and ch.get_meta("row") == row-1:
				ch.queue_free()

		if row-1 > content.size()-1:
			pass # prints("Cant erase", row, content.size())		
			return

		
		if from == 1 and length == -1: # just delete the whole line right away
			pass # print("Deleting whole line ", content[row-1])
			content[row-1] = []
			queue_redraw()
			return


		from -= 1

		var line_content: = content[row-1]

		var _offset: = 0

		pass # print("offset: ", offset)
		pass # print("from: ", from)
		pass # print("length: ", length)

		pass # print("Erasing line content '%s'" % str(line_content))

		var total: = 0
		var delete_to: = -1 if length == -1 else from + length
		var deleting: = false

		for i in range(line_content.size()):
			var line_part = line_content[i]

			pass # print("line_part: ", line_part)

			if line_part is String:
				total += line_part.length()
				pass # print("Total is now %s" % total)

				# if we reach the point where we start deleting
				if not deleting and from < total-1:
					pass # print("Not deleting and from < total-1")
					var from_rel: int = from - (total - line_part.length())
					
					var actl = line_part.length()-from_rel if length == -1 else length

					if from_rel + actl >= line_part.length():
						pass # print("Must delete in next parts, deleting = true")
						var chars = max(0, line_part.length()-from_rel) if length == -1 else length
						line_part = line_part.erase(from_rel, chars)
						pass # print("line part is now '%s'" % line_part.c_escape())
						deleting = true
						line_content[i] = line_part
						continue
					else:
						var chars = max(0, line_part.length()-from_rel) if length == -1 else length
						
						line_part = line_part.erase(from_rel, chars)
						pass # print("line part is now '%s'" % line_part.c_escape())
						pass # print(from_rel, length)
						line_content[i] = line_part
						pass # print("break")
						break

				if deleting:
					pass # print("deleting...")
					if delete_to == -1:
						pass # print("Deleting the whole part")
						line_part = ""
					else:
						pass # print("Deleting part of string")
						if delete_to <= total-1:
							line_part = line_part.erase(0, total-1-delete_to)
							pass # print("line part is now '%s'" % line_part.c_escape())
						else:
							pass # print("Deleting whole string, deleting = false")
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

	func _draw() -> void:

		_foreground_color = Color.WHITE
		_background_color = Color.TRANSPARENT
		
		var pos: = Vector2(0, 1)  # Start at first line


		for line_parts in content:
			pass # print(line_parts)
			for part in line_parts:
				if part is String:
					var string_pos: = pos * Vector2(terminal.char_width, terminal.line_height)

					var start: = 0
					for i in range(part.length()):

						if part[i] == char(10240) or i == part.length()-1:
							if i > start+1:
								var background_rect: = Rect2(
									(pos + Vector2(start, 0)) * Vector2(terminal.char_width, terminal.line_height),
									Vector2((i-start+1)*terminal.char_width, -terminal.line_height)
								)
								
								draw_rect(background_rect, _background_color)
							start = i+1

					if pos.y-1 == _selection_start.y and pos.y-1 == _selection_end.y:
						var background_rect: = Rect2(
							(pos + Vector2(_selection_start.x, 0)) * Vector2(terminal.char_width, terminal.line_height),
							Vector2((_selection_end.x-_selection_start.x)*terminal.char_width, -terminal.line_height)
						)
						
						draw_rect(background_rect, _selection_background_color)
					
					# selection_end must be on another line down
					elif pos.y-1 == _selection_start.y:
						var background_rect: = Rect2(
							(Vector2(_selection_start.x, pos.y)) * Vector2(terminal.char_width, terminal.line_height),
							Vector2((max(0, part.length()-_selection_start.x))*terminal.char_width, -terminal.line_height)
						)
						
						draw_rect(background_rect, _selection_background_color)

					# selection_start must be on another line above
					elif pos.y-1 == _selection_end.y:
						var background_rect: = Rect2(
							(pos) * Vector2(terminal.char_width, terminal.line_height),
							Vector2((_selection_end.x)*terminal.char_width, -terminal.line_height)
						)
						
						draw_rect(background_rect, _selection_background_color)

					# we're inbetween the selection start and end
					elif pos.y-1 > _selection_start.y and pos.y-1 < _selection_end.y:
						var background_rect: = Rect2(
							(pos) * Vector2(terminal.char_width, terminal.line_height),
							Vector2((part.length())*terminal.char_width, -terminal.line_height)
						)
						
						draw_rect(background_rect, _selection_background_color)

					draw_string_outline(terminal.font, string_pos, part, HORIZONTAL_ALIGNMENT_LEFT, -1, terminal.font_size, 5, Color.BLACK)
					draw_string(terminal.font, string_pos, part, HORIZONTAL_ALIGNMENT_LEFT, -1, terminal.font_size, _foreground_color)
					
					
					pos.x += part.length()
				
				if part is Modifier:
					pass # print("Applying part: ", part)
					part.apply()

			pos.y += 1
			pos.x = 0
		
		custom_minimum_size.y = pos.y * terminal.line_height

	func _create_context_menu_item(text: String, keycode: Key, id: int, callback: Callable = Callable()):
		var shortcut: = Shortcut.new()
		var event: = InputEventKey.new()
		event.keycode = keycode
		event.ctrl_pressed = true
		shortcut.events.append(event)

		_context_menu.add_shortcut(shortcut, id)
		_context_menu.set_item_text(id, text)

		if callback.is_valid():
			_context_menu.id_pressed.connect(func(id_: int): if id_ == id: callback.call())
		

	var _context_menu: PopupMenu
	func _create_context_menu(at: Vector2) -> void:
		if not _context_menu:
			_context_menu = PopupMenu.new()
			_context_menu.initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
			add_child(_context_menu)

			_create_context_menu_item("Copy", KEY_CTRL, 0, func(): DisplayServer.clipboard_set(get_selected_text());reset_selection())
			_create_context_menu_item("Paste", KEY_V, 1, func(): terminal.terminal.write_input(DisplayServer.clipboard_get()))
			_create_context_menu_item("Zoom In", KEY_PLUS, 2, func(): terminal.font_size += 1; terminal._update_font_metrics(); queue_redraw())
			_create_context_menu_item("Zoom In", KEY_MINUS, 3, func(): terminal.font_size -= 1; terminal._update_font_metrics(); queue_redraw())

		_context_menu.popup()
		_context_menu.position = at + Vector2(0, _context_menu.size.y/2.0)

	func get_selected_text() -> String:
		var parts: = PackedStringArray()

		var line_total: = 0

		for i in range(_selection_start.y, _selection_end.y+1):
			var line_parts: = content[i]
			for part in line_parts:
				line_total = 0
				if part is String:
					for j in range(part.length()):
						line_total += 1
						
						if i == _selection_start.y and line_total < _selection_start.x:
							continue

						if i == _selection_end.y and line_total > _selection_end.x:
							break

						parts.append(part[j])
				parts.append("\n")

		return "".join(parts).strip_edges()
