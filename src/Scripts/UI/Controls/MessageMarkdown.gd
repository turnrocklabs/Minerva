class_name MessageMarkdown
extends HBoxContainer

# Exported variables for UI components and colors
@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export var user_message_color: Color
@export var bot_message_color: Color
@export var error_message_color: Color

@onready var tokens_cost: Label = %TokensCostLabel
@onready var edit_popup: MessageEditPopup = %MessageEditPopup

var content: String:
	set(value):
		content = value
		history_item.Message = value
		history_item = history_item # so the setter is triggered
	get: return label.text


## Chat history item that this message node is rendering
var history_item: ChatHistoryItem:
	set(value):
		history_item = value
		_render_history_item()


var loading:= false:
	set(value):
		set_message_loading(value)
		loading = value

var editable:= false:
	set(value):
		editable = value
		%EditButton.visible = editable
		%RegenerateButton.visible = editable


func _ready():
	_render_history_item()

	# set the message for the edit popup
	edit_popup.message = self

func set_message_loading(loading_: bool):
	%LoadingLabel.visible = loading_
	
	_toggle_controls(not loading_)


# This function will take the history item and render it as user or model message
func _render_history_item():
	if not history_item: return

	if history_item.Role == ChatHistoryItem.ChatRole.USER: _setup_user_message()
	else: _setup_model_message()

	history_item.rendered_node = self

	_create_code_labels()

func _toggle_controls(enabled:= true):
	if is_inside_tree():
		get_tree().call_group("controls", "set_disabled", not enabled)

func _setup_user_message():
	right_control.visible = true
	right_control.get_node("PanelContainer/Label").text = SingletonObject.preferences_popup.get_user_initials()
	right_control.get_node("PanelContainer").tooltip_text = SingletonObject.preferences_popup.get_user_full_name()
	label.markdown_text = history_item.Message
	label.set("theme_override_colors/default_color", Color.WHITE)

	var style: StyleBoxFlat = get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = user_message_color


func _setup_model_message():
	left_control.visible = true

	left_control.get_node("PanelContainer/Label").text = history_item.ModelShortName
	left_control.get_node("PanelContainer").tooltip_text = history_item.ModelName
	
	label.set("theme_override_colors/default_color", Color.BLACK)
	
	var style: StyleBox = get_node("%PanelContainer").get("theme_override_styles/panel")

	var continue_btn = get_node("%ContinueButton") as Button	
	continue_btn.visible = not history_item.Complete

	# we can't edit model messages
	%EditButton.visible = false

	if history_item.Error:
		label.text = "An error occurred:\n%s" % history_item.Error
		style.bg_color = error_message_color
	else:
		label.markdown_text = history_item.Message
		style.bg_color = bot_message_color


## Instantiates new message node
static func new_message() -> MessageMarkdown:
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	return msg


func update_tokens_cost(estimated: int, correct: int) -> void:
	tokens_cost.visible = true
	tokens_cost.text = "%s/%s" % [estimated, correct]
	tokens_cost.tooltip_text = "Used %s tokens (estimated %s)" % [correct, estimated]


# Continues the generation of the response
func _on_continue_button_pressed():
	if history_item:
		loading = true
		history_item = await SingletonObject.Chats.continue_response(history_item)
		loading = false



func _on_clip_button_pressed():
	DisplayServer.clipboard_set(label.text)


func _on_note_button_pressed():
	SingletonObject.NotesTab.add_note("Chat Note", label.text)
	SingletonObject.main_ui.set_editor_pane_visible(true)


func _on_delete_button_pressed():
	SingletonObject.Chats.remove_chat_history_item(history_item)

func _on_regenerate_button_pressed():
	SingletonObject.Chats.regenerate_response()


func _on_edit_button_pressed():
	edit_popup.popup_centered()

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


func _extract_code_block_syntax(code_text: String) -> String:
	
	label.markdown_text.rfind("```")

	# Try to find where in markdown text is our parsed bbcode
	# so we can get the syntax
	var replace = {
		"[code]":  "",
		"[/code]":  "",
		"[lb]":  "[",
		"[rb]":  "]",
	}

	var to_find = code_text
	for key in replace:
		to_find = to_find.replace(key, replace[key])

	var idx = label.markdown_text.find(to_find)
	
	var syntax_idx = label.markdown_text.substr(0, idx).rfind("```")

	var syntax = label.markdown_text.substr(syntax_idx).split("\n")[0]
	syntax = syntax.replace("`", "")

	# if theres no syntax return space char, not empty string
	# empty string would meand it's a normal text segment
	return syntax if syntax else " "


var _regex = RegEx.new()
func _extract_text_segments(text: TextSegment) -> Array[TextSegment]:
	_regex.compile(r"(\[code\])((.|\n)*?)(\[\/code\])")

	var found: Array[TextSegment] = []

	var keep_searching = true
	var offset = 0

	var code_text: String

	while keep_searching:
		var match_: RegExMatch = _regex.search(text.content, offset)

		if not match_: return [text]

		# content between [code][/code]
		code_text = match_.get_string()

		# if it's one line code we'll just skip it by setting the offset and searching again
		if code_text.count("\n") == 0:
			offset = match_.get_end()
			continue
		else:
			keep_searching = false


	# index where code text starts, includes [code]
	var code_text_start = text.content.find(code_text)

	# replace this text segment with extracted text segments from it
	# if theres no code blocks in it, it will just return array with this same element
	var new_ts1 = _extract_text_segments(TextSegment.new(text.content.substr(0, code_text_start)))
	found.append_array(new_ts1)

	# place code block between them
	found.append(TextSegment.new(text.content.substr(code_text_start, code_text.length()), _extract_code_block_syntax(code_text)))

	# same thing
	var new_ts2 = _extract_text_segments(TextSegment.new(text.content.substr(code_text_start + code_text.length())))
	found.append_array(new_ts2)
		

	return found



func _create_code_labels():
	var segments: Array[TextSegment] = _extract_text_segments(TextSegment.new(label.text))

	# Hide the label since we're showing the message content in nodes below
	# but keep it so we can access the message content easily
	label.visible = false
	
	for child in %MessageLabelsContainer.get_children(): child.queue_free()

	for ts in segments:
		var node: Node

		if ts.syntax:
			node = CodeMarkdownLabel.create(ts.content, ts.syntax)
		else:
			# Maybe have this node as scene
			node = RichTextLabel.new()
			node.fit_content = true
			node.bbcode_enabled = true
			node.selection_enabled = true
			node.text = ts.content

			# set the color for model message
			if history_item.Role != ChatHistoryItem.ChatRole.USER: node.set("theme_override_colors/default_color", Color.BLACK)
		
		%MessageLabelsContainer.add_child(node)


