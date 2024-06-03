class_name MessageMarkdown
extends HBoxContainer

# Exported variables for UI components and colors
@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export var user_message_color: Color
@export var bot_message_color: Color
@export var error_message_color: Color

# Creates a MessageMarkdown instance for bot messages
static func bot_message(message: BotResponse) -> MessageMarkdown:
	# Instantiate a new MessageMarkdown scene
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	
	# Set visibility and text for the left control
	msg.left_control.visible = true
	msg.left_control.get_node("PanelContainer/Label").text = "O4"
	msg.left_control.get_node("PanelContainer").tooltip_text = "gpt-4"
	msg.label.set("theme_override_colors/default_color", Color.BLACK)
	
	# Get the style box for the panel container
	var style: StyleBox = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	
	# Check if there's an error in the message
	if message.Error:
		msg.label.text = "An error occurred:\n%s" % message.Error
		style.bg_color = msg.error_message_color
	else:
		msg.label.markdown_text = message.FullText
		style.bg_color = msg.bot_message_color

	return msg

# Creates a MessageMarkdown instance for user messages
static func user_message(message: BotResponse) -> MessageMarkdown:
	# Instantiate a new MessageMarkdown scene
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	
	# Set visibility and text for the right control
	msg.right_control.visible = true
	msg.right_control.get_node("PanelContainer/Label").text = SingletonObject.preferences_popup.get_user_initials()
	msg.right_control.get_node("PanelContainer").tooltip_text = SingletonObject.preferences_popup.get_user_full_name()
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.WHITE)

	# Get the style box for the panel container
	var style: StyleBoxFlat = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.user_message_color

	return msg

# A class representing a segment of text with optional syntax highlighting
class TextSegment:
	var syntax: String
	var content: String

	func _init(content_: String, syntax_: String = ""):
		content = content_
		syntax = syntax_

	func _to_string() -> String:
		if syntax:
			return "%s: %s" % [syntax, content]
		else:
			return content

# Called when the node is added to the scene
func _ready():
	# Compile a regex pattern to match [code]...[/code] blocks
	var regex = RegEx.new()
	regex.compile(r"(\[code\])((.|\n)*?)(\[\/code\])")

	# Get the text from the label
	var text = label.text

	# Find all matches of the regex in the text
	var matches = regex.search_all(text)

	# Array to hold segments of text
	var text_segments: Array[TextSegment] = []

	# Iterate over all matches
	for m in matches:
		var code_text = m.get_string()
		var one_line = code_text.count("\n") == 0

		# Skip single-line code segments
		if one_line:
			continue

		var first_part_len = text.find(code_text)
		var second_part_start = first_part_len + code_text.length()
		var second_part_len = text.length()

		# Create text segments before, during, and after the code block
		var ts1 = TextSegment.new(text.substr(0, first_part_len).strip_edges())
		var ts3 = TextSegment.new(text.substr(second_part_start, second_part_len).strip_edges())

		# Extract syntax from the first line of the markdown text
		var syntax = label.markdown_text.substr(first_part_len, code_text.length()).strip_edges().split("\n")[0]
		syntax = syntax.replace("`", "")

		# Include the [code] and [/code] tags in the content
		var ts2 = TextSegment.new(code_text, syntax)

		# Add the text segments to the array
		text_segments.append(ts1)
		text_segments.append(ts2)
		text_segments.append(ts3)

	# If there are no matches, return early
	if not matches:
		return

	# Clear all children of the label's parent
	for ch in label.get_parent().get_children():
		label.get_parent().remove_child(ch)

	# If there are no text segments, create a new RichTextLabel
	if len(text_segments) == 0:
		var node: Node = RichTextLabel.new()
		node.fit_content = true
		node.bbcode_enabled = true
		node.text = label.markdown_text
		get_node("%PanelContainer/v").add_child(node)
	else:
		# Otherwise, create nodes for each text segment
		for ts in text_segments:
			var node: Node
			if ts.syntax:
				node = CodeMarkdownLabel.create(ts.content, ts.syntax)
			else:
				node = RichTextLabel.new()
				node.fit_content = true
				node.bbcode_enabled = true
				node.text = ts.content

			# Add the node to the panel container
			get_node("%PanelContainer/v").add_child(node)
