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

## Content of this message in markdown, returns `label.text`
## Setting this property will update the history item and rerender the note
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
		render()

## Setting this property to true will set the loading state for the message
## and hide any other content except the loading label
var loading:= false:
	set(value):
		set_message_loading(value)
		loading = value

## Enables the edit button for this node if it's displaying a user message.
## Changing this property for non user messages has no effect.
var editable:= false:
	set(value):
		editable = value
		%EditButton.visible = editable

## Returns all rendered chat images in this message
var images: Array[ChatImage]:
	get:
		var images_: Array[ChatImage] = []
		images_.assign(%ImagesGridContainer.get_children().filter(func(node: Node): return node is ChatImage))
		return images_


func _ready():
	render()

	# set the message for the edit popup
	edit_popup.message = self

## sets loading label visibility to `loading_` and toggles_controls
func set_message_loading(loading_: bool):
	%LoadingLabel.visible = loading_
	
	%MessageLabelsContainer.visible = not loading_
	%ImagesGridContainer.visible = not loading_

	_toggle_controls(not loading_)


## This function will rerender the messaged using set `history_item`.
## Either call this function or set the `history_item` whos setter will trigger it.
func render():
	if not (history_item and is_node_ready()): return

	if history_item.Role == ChatHistoryItem.ChatRole.USER: _setup_user_message()
	else: _setup_model_message()

	visible = history_item.Visible

	_update_tokens_cost()

	history_item.rendered_node = self

	_create_code_labels()


func _update_tokens_cost() -> void:
	var price = history_item.provider.token_cost * history_item.TokenCost

	tokens_cost.visible = true
	if history_item.EstimatedTokenCost:
		tokens_cost.text = "%s/%s" % [history_item.EstimatedTokenCost, history_item.TokenCost]
		tokens_cost.tooltip_text = "Estimated %s tokens, used %s (%s$)" % [history_item.EstimatedTokenCost, history_item.TokenCost, price]
	else:
		tokens_cost.text = "%s" % history_item.TokenCost
		tokens_cost.tooltip_text = "Used %s tokens (%s$)" % [history_item.TokenCost, price]


## Will disable/enable nodes in the `controls` group which contains all message buttons
func _toggle_controls(enabled:= true):
	if is_inside_tree():
		get_tree().call_group("controls", "set_disabled", not enabled)

func _setup_user_message():
	right_control.visible = true
	right_control.get_node("%AvatarName").text = SingletonObject.preferences_popup.get_user_initials()
	right_control.get_node("%MsgSenderAvatar").tooltip_text = SingletonObject.preferences_popup.get_user_full_name()
	label.markdown_text = history_item.Message
	label.set("theme_override_colors/default_color", Color.WHITE)

	%RegenerateButton.visible = true

	var style: StyleBoxFlat = get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = user_message_color


func _setup_model_message():
	left_control.visible = true

	left_control.get_node("PanelContainer/Label").text = history_item.ModelShortName
	left_control.get_node("PanelContainer").tooltip_text = history_item.ModelName

	for ch in %ImagesGridContainer.get_children(): ch.free()

	for image in history_item.Images:
		var texture_rect = TextureRect.new()
		texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		texture_rect.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
		texture_rect.texture = ImageTexture.create_from_image(image)

		var img_node = ChatImage.create(image)

		# tell the vBoxChat if image is activated
		img_node.image_active_state_changed.connect(
			func(active: bool):
				(get_parent() as VBoxChat).image_activated.emit(img_node, active)
		)

		%ImagesGridContainer.add_child(img_node)
	
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



# Continues the generation of the response
func _on_continue_button_pressed():
	if history_item:
		loading = true
		history_item = await SingletonObject.Chats.continue_response(history_item)
		loading = false



func _on_clip_button_pressed():
	DisplayServer.clipboard_set(label.markdown_text + "\n")


func _on_note_button_pressed():
	SingletonObject.NotesTab.add_note("Chat Note", label.markdown_text)
	SingletonObject.main_ui.set_notes_pane_visible(true)


func _on_delete_button_pressed():
	SingletonObject.Chats.remove_chat_history_item(history_item)

func _on_regenerate_button_pressed():
	SingletonObject.Chats.regenerate_response(history_item)


func _on_edit_button_pressed():
	edit_popup.popup_centered()

func _on_hide_button_pressed():
	SingletonObject.Chats.hide_chat_history_item(history_item, null, false)

# since auto scroll on text selection is kinda broken
# we made a workaround

# code below emits a `message_selection` signal when text selection starts or ends
# if mouse is not pressed emit false
# if mouse is pressed AND somoe of richtextlabels have selected text emit true

var _pressed: = false
func _on_gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		_pressed = event.is_pressed()
		if not _pressed:
			get_parent().message_selection.emit(self, false)
		return
	
	if event is InputEventMouseMotion:
		for ch in %MessageLabelsContainer.get_children(): # ch is either RichTextLabel or CodeMarkdownLabel
			if not ch.get_selected_text().is_empty():
				get_parent().message_selection.emit(self, true)



## Class that represents a message text segment
## If it has set syntax, it's treated like a code label
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


var _regex = RegEx.new()
func _extract_text_segments(text: TextSegment) -> Array[TextSegment]:
	_regex.compile(r"(\[code(?: syntax=(?P<syntax>.*?))?\])(?P<content>(.|\n)*?)(\[\/code\])")

	var found: Array[TextSegment] = []

	var keep_searching = true
	var offset = 0

	var match_: RegExMatch

	# keep searching until we find a code block that's not one line
	while keep_searching:
		match_ = _regex.search(text.content, offset)

		if not match_: return [text]

		# if it's one line code we'll just skip it by setting the offset and searching again
		if match_.get_string().count("\n") == 0:
			offset = match_.get_end()
			continue
		else:
			keep_searching = false

	# replace this text segment with extracted text segments from it
	# if theres no code blocks in it, it will just return array with this same element
	var new_ts1 = _extract_text_segments(TextSegment.new(text.content.substr(0, match_.get_start())))
	found.append_array(new_ts1)

	# if theres no syntax, just set it to anything but emty string
	# since empty string would mean it's not a code block
	var syntax = match_.get_string("syntax")
	if not syntax: syntax = "Plain Text"

	# place code block between them
	found.append(TextSegment.new(match_.get_string("content"), syntax))

	# same thing
	var new_ts2 = _extract_text_segments(TextSegment.new(text.content.substr(match_.get_end())))
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
			node.focus_mode = Control.FOCUS_NONE # disable auto scroll to bottom on focus
			node.mouse_filter = Control.MOUSE_FILTER_PASS

			# set the color for model message
			if history_item.Role != ChatHistoryItem.ChatRole.USER: node.set("theme_override_colors/default_color", Color.BLACK)
		
		%MessageLabelsContainer.add_child(node)


