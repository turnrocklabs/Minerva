class_name MessageMarkdown
extends HBoxContainer

# Exported variables for UI components and colors
@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export_category("Message Container Colors")
@export var user_message_color: Color
@export var bot_message_color: Color
@export var error_message_color: Color

@export_category("Expand Animation Stats")
@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color.WHITE
@export var custom_starting_size: = 740.0
@export var max_message_size_limit: float = 400.0
@export var min_message_size_limit: float = 30.0

@export_category("Code Label vars")
@export var max_lines_expanded_code_segment: int = 6

@onready var expand_button: Button = %ExpandButton
@onready var resize_scroll_container: VBoxContainer = %ResizeScrollContainer
@onready var message_labels_container: VBoxContainer = %MessageLabelsContainer
@onready var resize_drag_control: Control = %ResizeDragControl
@onready var images_grid_container: GridContainer = %ImagesGridContainer
@onready var v_box_container: VBoxContainer = %MainVBoxContainer

@onready var tokens_cost: Label = %TokensCostLabel
@onready var text_edit: TextEdit = %MessageTextEdit
@onready var text_message_container: HBoxContainer = %TextMessageHBoxContainer

var is_unsplit_edit = false

var _expanded: bool = true:
	set(value):
		if history_item:
			history_item.Expanded = value
		_expanded = value

var _last_custom_size_y: float = 0.0:
	set(value):
		if value > 0:
			_last_custom_size_y = value
			if history_item:
				history_item.LastYSize = value

var first_time_message: bool = true

## Content of this message in markdown, returns `label.text`
## Setting this property will update the history item and rerender the note
var content: String:
	set(value):
		#replacing All underscores to avoid but that transform all text to itelic when we using underscors (_text_text)
		value = value.replace("_",r"\_")
		content = value
		history_item.Message = value
		history_item = history_item # so the setter is triggered
		_update_sizes()
	get: return label.text


## Chat history item that this message node is rendering
var history_item: ChatHistoryItem:
	set(value):
		history_item = value
		if value.LinkedMemories.has("0"):
			linked_memory_item_UUID = value.LinkedMemories.get("0")
		render()

var linked_memory_item_UUID: String = "":
	set(value):
		linked_memory_item_UUID = value
		if history_item:
			history_item.LinkedMemories["0"] = value

## Setting this property to true will set the loading state for the message
## and hide any other content except the loading label
var loading:= false:
	set(value):
		set_message_loading(value)
		loading = value
		_update_sizes()

## Enables the edit button for this node if it's displaying a user message.
## Changing this property for non user messages has no effect.
var editable:= false:
	set(value):
		editable = value
		%EditButton.visible = editable

## Whether the messages can be regenerated.[br]
## Controls the visibility of the regenerate button.
var regeneratable: = true:
	set(value):
		regeneratable = value

		if not regeneratable and %RegenerateButton.visible:
			%RegenerateButton.visible = false

## Returns all rendered chat images in this message
var images: Array[ChatImage]:
	get:
		var images_: Array[ChatImage] = []
		images_.assign(%ImagesGridContainer.get_children().filter(func(node: Node): return node is ChatImage))
		return images_


func _ready() -> void:
	if  history_item.isMerged:
		%UnsplitButton.visible = true
	render()
	
	await get_tree().process_frame
	v_box_container.resized.connect(_update_scroll_container_size)
	if get_parent() is SliderContainer:
		%LeftCardButton.visible = true
		%RightCardButton.visible = true
		right_control.visible = false
		left_control.visible = false
		if v_box_container.size.y > custom_starting_size:
			max_message_size_limit = custom_starting_size
		else:
			max_message_size_limit = v_box_container.size.y
	else:
		resize_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	
	await get_tree().process_frame
	_setup_sizes()
	
	# Make  the controls invisible if they are empty
	if images_grid_container.get_child_count() == 0:
		images_grid_container.visible = false
	if message_labels_container.get_child_count() == 0:
		message_labels_container.visible = false
	_expanded = history_item.Expanded
	if !_expanded:
		resize_scroll_container.custom_minimum_size.y = 0.0
		expand_button.rotation = deg_to_rad(-90.0)
		expand_button.modulate = expand_icon_color
		resize_scroll_container.visible = false
		resize_drag_control.visible = false
	
	
	await get_tree().create_timer(0.005).timeout
	_update_sizes()
	_enable_input()


## sets loading label visibility to `loading_` and toggles_controls
func set_message_loading(loading_: bool):
	%LoadingLabel.visible = loading_
	
	%MessageLabelsContainer.visible = not loading_
	%ImagesGridContainer.visible = not loading_

	_toggle_controls(not loading_)
	await get_tree().process_frame
	_update_sizes()


## This function will rerender the messaged using set `history_item`.
## Either call this function or set the `history_item` which setter will trigger it.
func render() -> void:
	if history_item.isMerged:
		%UnsplitButton.visible = true
	else:
		%UnsplitButton.visible = false
	if not (history_item and is_node_ready()): return

	if history_item.Role == ChatHistoryItem.ChatRole.USER: 
		_setup_user_message()
		
	else: 
		_setup_model_message()

	visible = history_item.Visible

	_update_tokens_cost()

	history_item.rendered_node = self

	_create_code_labels()
	


func set_edit(on: = true) -> void:
	if on:
		await get_tree().process_frame
		message_labels_container.visible = false
		text_message_container.visible = true
		%SetTextButton.visible = true
		text_edit.text = history_item.Message  # Pre-populate with current content
		text_edit.grab_focus()
	else:
		_exit_edit_mode()

func _exit_edit_mode():
	text_message_container.visible = false
	%SetTextButton.visible = false
	message_labels_container.visible = true

func _update_tokens_cost() -> void:
	var price = 0.0
	if history_item.provider:
		price = history_item.provider.token_cost * history_item.TokenCost

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

func _setup_user_message() -> void:
	#%LeftMarginControl.visible = true
	right_control.visible = true
	right_control.get_node("%AvatarName").text = SingletonObject.preferences_popup.get_user_initials()
	right_control.get_node("%MsgSenderAvatar").tooltip_text = SingletonObject.preferences_popup.get_user_full_name()
	label.markdown_text = history_item.Message
	label.set("theme_override_colors/default_color", Color.WHITE)

	if regeneratable:
		%RegenerateButton.visible = true

	var style: StyleBoxFlat = get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = user_message_color
	


func _setup_model_message():
	#%RightMarginControl.visible = true
	if get_parent() is not SliderContainer:
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
	
	if history_item.Error:
		label.text = "An error occurred:\n%s" % history_item.Error
		style.bg_color = error_message_color
	else:
		label.markdown_text = history_item.Message
		style.bg_color = bot_message_color
	#await get_tree().process_frame


## Instantiates new message node
static var message_scene = preload("res://Scenes/MessageMarkdown.tscn")
static func new_message() -> MessageMarkdown:
	var msg: MessageMarkdown = message_scene.instantiate()
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
	if history_item.Images.size() > 0:
		var caption_title: String = history_item.Images[0].get_meta("caption", "")
		if caption_title.length() > 24:
			caption_title = caption_title.substr(0, 15) + "..."
		
		if linked_memory_item_UUID == "":
			linked_memory_item_UUID = SingletonObject.NotesTab.\
										add_image_note(caption_title, history_item.Images[0], history_item.Images[0].get_meta("caption", "")).UUID
			
		else:
			var return_memory = SingletonObject.NotesTab.update_note(linked_memory_item_UUID, history_item.Images[0])
			if return_memory == null:
				linked_memory_item_UUID = SingletonObject.NotesTab.\
										add_image_note(caption_title, history_item.Images[0], history_item.Images[0].get_meta("caption", "")).UUID
	else:
		if linked_memory_item_UUID == "":
			linked_memory_item_UUID = SingletonObject.NotesTab.\
										add_note("Chat Note", label.markdown_text,history_item.Complete).UUID
		else:
			var return_memory = SingletonObject.NotesTab.update_note(linked_memory_item_UUID, label.markdown_text)
			if return_memory == null:
				linked_memory_item_UUID = SingletonObject.NotesTab.\
										add_note("Chat Note",label.markdown_text,history_item.Complete).UUID
	SingletonObject.main_ui.set_notes_pane_visible(true)


func _on_delete_button_pressed():
	SingletonObject.Chats.remove_chat_history_item(history_item)
	
func _on_regenerate_button_pressed():
	SingletonObject.Chats.regenerate_response(history_item)


func _on_edit_button_pressed():
	set_edit()


func _on_hide_button_pressed():
	SingletonObject.Chats.hide_chat_history_item(history_item, null, false)

# since auto scroll on text selection is kinda broken
# we made a workaround

# code below emits a `message_selection` signal when text selection starts or ends
# if mouse is not pressed emit false
# if mouse is pressed AND some of richtext labels have selected text emit true

var _pressed: = false
func _on_gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		_pressed = event.is_pressed()
		#if not _pressed:
			#get_parent().message_selection.emit(self, false)
		return


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
	_regex.compile(r"(\[code(?: syntax=(?P<syntax>.*?))?\])(?P<content>(.|\-{3}&\n|\n)*?)(\[\/code\])")

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

	# if theres no syntax, just set it to anything but empty string
	# since empty string would mean it's not a code block
	var syntax = match_.get_string("syntax")
	if not syntax: syntax = "Plain Text"

	# place code block between them
	found.append(TextSegment.new(match_.get_string("content"), syntax))

	# same thing
	var new_ts2 = _extract_text_segments(TextSegment.new(text.content.substr(match_.get_end())))
	found.append_array(new_ts2)
		

	return found


func update_linked_dict(dict_index: String, UUID: String) -> void:
	history_item.LinkedMemories[dict_index] = UUID


func update_expanded(dict_index: String, is_expanded: bool) -> void:
	history_item.CodeLabelsState[dict_index] = is_expanded

#signal code_labels_updated
func _create_code_labels():
	var segments: Array[TextSegment] = _extract_text_segments(TextSegment.new(label.text))

	# Hide the label since we're showing the message content in nodes below
	# but keep it so we can access the message content easily
	label.visible = false
	
	for child in message_labels_container.get_children(): child.queue_free()
	
	var indexes: int = history_item.Images.size()
	indexes += 1
	
	for ts in segments:
		var node: Node

		if ts.syntax:
			var temp_UUID: String = ""
			var temp_expanded: bool = true
			if history_item.LinkedMemories.has(str(indexes)):
				temp_UUID = history_item.LinkedMemories.get(str(indexes))
			if history_item.CodeLabelsState.has(str(indexes)):
				temp_expanded = history_item.CodeLabelsState.get(str(indexes))
				first_time_message = false
			elif first_time_message and ts.content.split("\n").size() >= max_lines_expanded_code_segment:
				temp_expanded = false
			node = CodeMarkdownLabel.create(ts.content, ts.syntax, str(indexes), temp_UUID, temp_expanded)
			node.created_text_note.connect(update_linked_dict)
			node.update_expanded.connect(update_expanded)
			indexes += 1
		else:
			# Maybe have this node as scene
			node = RichTextLabel.new()
			node.threaded = true
			node.fit_content = true
			node.bbcode_enabled = true
			node.selection_enabled = true
			node.text = ts.content
			node.context_menu_enabled = true
			node.mouse_filter = Control.MOUSE_FILTER_PASS

			# set the color for model message
			if history_item.Role != ChatHistoryItem.ChatRole.USER: node.set("theme_override_colors/default_color", Color.BLACK)
		
		message_labels_container.add_child(node)


func _on_expand_button_pressed() -> void:
	_expanded = !_expanded
	if _expanded:
		expand_message()
	else:
		contract_message()


var expand_tween: Tween
func expand_message() -> void:
	_animate_called_from_button = true
	if v_box_container.size.y > max_message_size_limit:
			max_message_size_limit = v_box_container.size.y
	if _last_custom_size_y == 0 or _last_custom_size_y < 100:
		_last_custom_size_y = max_message_size_limit
	resize_scroll_container.visible = true
	resize_drag_control.visible = true
	_animate_expand(_last_custom_size_y, 0.0, Color.WHITE)
	_animate_called_from_button = false


func contract_message() -> void:
	_animate_called_from_button = true
	_animate_expand(0.0, -90.0, expand_icon_color)
	await get_tree().create_timer(expand_anim_duration- 0.24).timeout
	resize_scroll_container.visible = false
	resize_drag_control.visible = false
	_animate_called_from_button = false


var _animate_called_from_button: bool = false
func _animate_expand(new_size: float, new_rotation: float, new_icon_color: Color) -> Tween:
	if expand_tween and expand_tween.is_running():
			expand_tween.kill()
	expand_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	expand_tween.finished.connect(_enable_expand_button)
	expand_tween.tween_property(resize_scroll_container, "custom_minimum_size:y", new_size, expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button,"rotation", deg_to_rad(new_rotation), expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button, "modulate", new_icon_color, expand_anim_duration)
	return expand_tween


func _enable_expand_button() -> void:
	expand_button.disabled = false


func _on_unsplit_button_pressed() -> void:
	# Set the current message in the SingletonObject
	SingletonObject.current_message = self
	
	# Get references to the UnsplitedChatMessages and MessagesHolder nodes
	var unsplit_messages_container = get_unsplit_messages_container()
	var messages_holder = unsplit_messages_container.find_child("MessagesHolder")
	
	# Clear existing children in MessagesHolder (optional, depending on your use case)
	clear_messages_holder(messages_holder)
	
	# Handle text messages if they exist
	if history_item.Message:
		split_and_display_text_messages(history_item.Message, messages_holder)
	# Handle images if they exist
	if history_item.Images:
		split_and_display_images(history_item.Images, messages_holder)
	
	# Make the UnsplitedChatMessages section visible
	unsplit_messages_container.visible = true


# Helper function to get the UnsplitedChatMessages container
func get_unsplit_messages_container() -> Node:
	return get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().find_child("UnsplitedChatMessages")


# Helper function to clear all children in the MessagesHolder
func clear_messages_holder(messages_holder: Node) -> void:
	for child in messages_holder.get_children():
		child.queue_free()


# Helper function to split and display text messages
func split_and_display_text_messages(message: String, messages_holder: Node) -> void:
	var split_parts: Array = message.split("\u200B\u200C\u200D", false)  # Split by the invisible separator
	for part in split_parts:
		var message_instance = create_message_instance()
		var new_history_item = create_history_item_for_text(part.strip_edges())
		message_instance.history_item = new_history_item
		messages_holder.add_child(message_instance)
		if part == " ":
			print("epty part is: ", part)
			message_instance.visible = false


# Helper function to split and display images
func split_and_display_images(images_list: Array, messages_holder: Node) -> void:
	for image in images_list:
		var message_instance = create_message_instance()
		var new_history_item = create_history_item_for_image(image)
		message_instance.history_item = new_history_item
		messages_holder.add_child(message_instance)


# Helper function to create a new message instance
func create_message_instance() -> Node:
	var message_instance = message_scene.instantiate()
	message_instance.find_child("UnsplitButton").visible = false
	message_instance.find_child("HideButton").visible = false
	message_instance.find_child("PanelContainer").size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return message_instance


# Helper function to create a ChatHistoryItem for text
func create_history_item_for_text(text: String) -> ChatHistoryItem:
	var new_history_item = ChatHistoryItem.new()
	new_history_item.Message = text
	new_history_item.Role = history_item.Role
	new_history_item.ModelName = history_item.ModelName
	new_history_item.ModelShortName = history_item.ModelShortName
	return new_history_item


# Helper function to create a ChatHistoryItem for an image
func create_history_item_for_image(image) -> ChatHistoryItem:
	var new_history_item = ChatHistoryItem.new()
	new_history_item.Images.append(image)
	new_history_item.Role = history_item.Role
	new_history_item.ModelName = history_item.ModelName
	new_history_item.ModelShortName = history_item.ModelShortName
	return new_history_item

func _on_extract_editor_button_pressed() -> void:
	SingletonObject.editor_pane.update_current_text_tab("chat response" , history_item.Message)


func _on_left_card_button_pressed() -> void:
	var slider = get_parent() as SliderContainer
	slider.previous_child()


func _on_right_card_button_pressed() -> void:
	var slider = get_parent() as SliderContainer
	slider.next_child()


func _block_input() -> void:
	%BlockInputControl.visible = true
	%BlockInputControl.mouse_filter = MOUSE_FILTER_STOP


func _enable_input() -> void:
	%BlockInputControl.visible = false
	%BlockInputControl.mouse_filter = MOUSE_FILTER_IGNORE


var _resize_dragging: bool = false
var _last_mouse_posistion_y: float = 0.0
func _on_resize_control_gui_input(event: InputEvent) -> void:
	if _last_mouse_posistion_y == 0:
		_last_mouse_posistion_y = get_global_mouse_position().y
	if _expanded:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
				_resize_dragging = true
			elif event.button_index == MOUSE_BUTTON_LEFT and !event.is_pressed():
				_resize_dragging = false
	if event is InputEventMouseMotion and _resize_dragging:
		_resize_vertical(get_global_mouse_position().y, _last_mouse_posistion_y)
	
	_last_mouse_posistion_y = get_global_mouse_position().y


func _resize_vertical(current_mouse_pos_y: float, last_mouse_pos_y: float) -> void:
	var difference: float = current_mouse_pos_y - last_mouse_pos_y
	
	if resize_scroll_container.custom_minimum_size.y + difference < min_message_size_limit and min_message_size_limit != 0:
		resize_scroll_container.custom_minimum_size.y = min_message_size_limit
	elif resize_scroll_container.custom_minimum_size.y + difference > max_message_size_limit and max_message_size_limit != 0:
		resize_scroll_container.custom_minimum_size.y = max_message_size_limit
	else:
		resize_scroll_container.custom_minimum_size.y += difference
		_last_custom_size_y = resize_scroll_container.custom_minimum_size.y


func _setup_sizes() -> void:
	# This resizes the scroll container
	max_message_size_limit = v_box_container.size.y
	if !first_time_message:
		if _last_custom_size_y != 0:
			resize_scroll_container.custom_minimum_size.y = _last_custom_size_y
		else:
			resize_scroll_container.custom_minimum_size.y = custom_starting_size
			_last_custom_size_y = custom_starting_size
		return
	
	_last_custom_size_y = v_box_container.size.y
	if message_labels_container.get_child_count() > 0:
		for i in message_labels_container.get_children():
			if i is CodeMarkdownLabel:
				_last_custom_size_y = _last_custom_size_y - i.size.y
	resize_scroll_container.custom_minimum_size.y = v_box_container.size.y


func _update_sizes() -> void:
	var new_size: = v_box_container.size.y
	if message_labels_container.get_child_count() > 0:
		for i in message_labels_container.get_children():
			if i is CodeMarkdownLabel:
				new_size = new_size - i.size.y
	resize_scroll_container.custom_minimum_size.y = new_size
	
	if v_box_container.size.y < max_message_size_limit:
		max_message_size_limit = _last_custom_size_y
	resize_scroll_container.custom_minimum_size.y = v_box_container.size.y

func _update_scroll_container_size() -> void:
	if !_animate_called_from_button and !_resize_dragging:
		_animate_expand(v_box_container.size.y +1, expand_button.rotation, expand_button.modulate)

func _on_message_text_edit_text_set() -> void:
	if !text_edit.text.is_empty():
		history_item.Message = text_edit.text
		text_edit.text = ""
		text_message_container.visible = false
		%SetTextButton.visible = false
		await get_tree().process_frame
		render()
		
		message_labels_container.visible = true
		_update_sizes()
	else:
		text_message_container.visible = false
		%SetTextButton.visible = false
		message_labels_container.visible = false
