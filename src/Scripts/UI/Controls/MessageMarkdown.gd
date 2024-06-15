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

## Chat history item that this message node is rendering
var history_item: ChatHistoryItem:
	set(value):
		history_item = value
		if history_item:
			history_item.rendered_node = self
			_render_history_item()


var loading:= false:
	set(value):
		set_message_loading(value)
		loading = value

var editable:= false:
	set(value):
		editable = value
		%EditButton.visible = editable


func _ready():
	if history_item: _render_history_item()


func set_message_loading(loading_: bool):
	if loading_:
		label.markdown_text = "●︎●︎●︎"
	
	_toggle_controls(not loading_)


# This function will take the history item and render it as user or model message
func _render_history_item():
	if history_item.Role == ChatHistoryItem.ChatRole.USER: _setup_user_message()
	else: _setup_model_message()

	# create_code_labels()

func _toggle_controls(enabled:= true):
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




func _on_edit_button_pressed():
	var ep = SingletonObject.editor_container.editor_pane

	# if theres already open editor for this message, just switch to it
	for i in range(ep.Tabs.get_tab_count()):
		var tab_control = ep.Tabs.get_tab_control(i)

		if tab_control.get_meta("associated_object") == self:
			ep.Tabs.current_tab = i
			return

	var container: Editor = ep.add(Editor.TYPE.Text, null, "Chat Message")
	container.prompt_save = false

	container.set_meta("associated_object", self)

	container.code_edit.text = history_item.Message
	
	container.code_edit.text_changed.connect(
		func():
			history_item.Message = container.code_edit.text
			history_item = history_item
	)

	SingletonObject.main_ui.set_editor_pane_visible()


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


func create_code_labels():
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
	for ch in label.get_parent().get_children(): if label.get_parent(): label.get_parent().remove_child(ch)

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


