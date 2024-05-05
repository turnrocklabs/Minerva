class_name MessageMarkdown
extends HBoxContainer

@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export var user_message_color: Color
@export var bot_message_color: Color

static func bot_message(message: BotResponse) -> MessageMarkdown:
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	msg.right_control.visible = true
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.BLACK)
	
	var style: StyleBox = msg.get_node("PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.bot_message_color


	return msg

static func user_message(message: BotResponse) -> MessageMarkdown:
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	msg.left_control.visible = true
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.WHITE)

	var style: StyleBox = msg.get_node("PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.user_message_color

	return msg


func _ready():
	var regex = RegEx.new()
	var err = regex.compile(r"(\[code\])((.|\n)*)(\[\/code\])")

	var matches = regex.search_all(label.text)
	for m in matches:
		var code_text = m.get_string()

		var first_part_len = label.text.find(code_text)
		
		var second_part_start = first_part_len + code_text.length()
		var second_part_len = label.text.length()

		var first_label = label.duplicate()
		first_label.text = label.text.substr(0, first_part_len).strip_edges()
		$PanelContainer/v.add_child(first_label)
		$PanelContainer/v.move_child(first_label, label.get_index())

		var second_label = label.duplicate()
		second_label.text = label.text.substr(second_part_start, second_part_len).strip_edges()
		$PanelContainer/v.add_child(second_label)
		$PanelContainer/v.move_child(second_label, label.get_index()+1)

		label.text = label.text.substr(first_part_len, code_text.length()).strip_edges()
		label.get_node("CopyButton").visible = true
		label.get_node("CopyButton").pressed.connect(func(): DisplayServer.clipboard_set(code_text))


func extract_code_block(source_text = "") -> String:

	var code_block = ""
	
	var lines = source_text.split("\n")
	var _indent_level = -1
	var iline := 0
	var within_backtick_block := false
	var within_tilde_block := false
	var within_code_block := false
	var current_code_block_char_count: int
	var _current_paragraph = 0
	var _line_break = true

	for line in lines:
		line = line.trim_suffix("\r")
		within_code_block = within_tilde_block or within_backtick_block
		if iline > 0 and _line_break:
			# _converted_text += "\n"
			_current_paragraph += 1
			_line_break = true
		iline+=1
		
		if not within_tilde_block and label._denotes_fenced_code_block(line,"`"):
			if within_backtick_block:
				if line.strip_edges().length() >= current_code_block_char_count:
					code_block = code_block.trim_suffix("\n")
					_current_paragraph -= 1
					# code_block += "[/code]"
					within_backtick_block = false
					continue
			else:
				# code_block += "[code]"
				within_backtick_block = true
				#current_code_block_char_count = line.strip_edges().length()
				current_code_block_char_count = label._get_codeblock_char_count(line, "`")
				continue
		elif not within_backtick_block and label._denotes_fenced_code_block(line,"~"):
			if within_tilde_block:
				if line.strip_edges().length() >= current_code_block_char_count:
					code_block = code_block.trim_suffix("\n")
					_current_paragraph -= 1
					# code_block += "[/code]"
					within_tilde_block = false
					continue
			else:
				# code_block += "[code]"
				within_tilde_block = true
				current_code_block_char_count = line.strip_edges().length()
				continue
		if within_code_block: #ignore any formatting inside code block
			code_block += label._escape_bbcode(line)
			continue
	
	return code_block

# func _on_markdown_label_gui_input(event:InputEvent):
# 	print(event)
