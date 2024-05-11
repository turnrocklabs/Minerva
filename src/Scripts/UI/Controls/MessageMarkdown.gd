class_name MessageMarkdown
extends HBoxContainer

@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export var user_message_color: Color
@export var bot_message_color: Color

static func bot_message(message: BotResponse) -> MessageMarkdown:
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	msg.left_control.visible = true
	msg.left_control.get_node("PanelContainer/Label").text = "O4"
	msg.left_control.get_node("PanelContainer").tooltip_text = "gpt-4"
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.BLACK)
	
	var style: StyleBox = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.bot_message_color


	return msg

static func user_message(message: BotResponse) -> MessageMarkdown:
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	msg.right_control.visible = true
	msg.right_control.get_node("PanelContainer/Label").text = SingletonObject.get_user_initials()
	msg.right_control.get_node("PanelContainer").tooltip_text = SingletonObject.get_user_full_name()
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.WHITE)

	var style: StyleBoxFlat = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.user_message_color

	return msg


class TextSegment:
	var syntax: String
	var content: String

	func _init(content_: String, syntax_: String = ""):
		content = content_
		syntax = syntax_
	
	func _to_string():
		if syntax:
			return "%s: %s" % [syntax, content]
		else:
			return content


func _ready():
	var regex = RegEx.new()
	regex.compile(r"(\[code\])((.|\n)*?)(\[\/code\])")

	var text = label.text

	var mathces = regex.search_all(label.text)

	var text_segments: Array[TextSegment] = []

	for m in mathces:
		var code_text = m.get_string()
		var one_line = code_text.count("\n") == 0

		if one_line: continue

		var first_part_len = text.find(code_text)
		
		var second_part_start = first_part_len + code_text.length()
		var second_part_len = text.length()

		var ts1 = TextSegment.new(text.substr(0, first_part_len).strip_edges())

		var ts3 = TextSegment.new(text.substr(second_part_start, second_part_len).strip_edges())

		# first line of the markdown text eg. ```python
		var syntax = label.markdown_text.substr(first_part_len, code_text.length()).strip_edges().split("\n")[0]
		syntax = syntax.replace("`", "")

		var ts2 = TextSegment.new(code_text, syntax)

		text_segments.append(ts1)
		text_segments.append(ts2)
		text_segments.append(ts3)
	
	if not mathces: return

	# clear all children
	for ch in label.get_parent().get_children(): label.get_parent().remove_child(ch)
	for ts in text_segments:
		var node: Node

		if ts.syntax:
			node = CodeMarkdownLabel.create(ts.content, ts.syntax)
		else:
			node = RichTextLabel.new()
			node.fit_content = true
			node.bbcode_enabled = true
			node.text = ts.content
		
		%PanelContainer/v.add_child(node)
		
