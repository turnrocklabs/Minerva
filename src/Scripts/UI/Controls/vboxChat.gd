# Manages a single chat interaction
class_name VBoxChat
extends VBoxContainer

@warning_ignore("unused_signal")
signal memorize_item(text_to_memorize:String)

# emitted when text selection for any of rich text labels start or end
@warning_ignore("unused_signal")
signal message_selection(message: MessageMarkdown, active: bool)

## emitted when user activates a image for editing
## MessageMarkdown emits this signal
@warning_ignore("unused_signal")
signal image_activated(image: ChatImage, active: bool)


@onready var scroll_container = get_parent() as ScrollContainer

var chat_history: ChatHistory
var MainTabContainer

var Parent

## initialize the box
func _init(_parent):
	self.Parent = _parent
	self.MainTabContainer = _parent
	self.name = _parent.name + "_VBoxChat"
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pass

func _ready():
	self.size = self.Parent.size
	message_selection.connect(
		func(_msg: MessageMarkdown, active: bool):
			_text_selection = active
	)

	image_activated.connect(_on_image_activated)

	add_child(chat_history.provider)


func _notification(what):
	match what:
		NOTIFICATION_CHILD_ORDER_CHANGED:
			_messages_list_changed()


func _messages_list_changed():
	var last_message: MessageMarkdown

	# disalbe edit for all user messages
	for child in get_children():
		if child is MessageMarkdown:
			child.editable = false
			last_message = child
	
	if not last_message: return
	
	# if last_message is user message, enable edit for it
	if last_message.history_item.Role == ChatHistoryItem.ChatRole.USER:
		last_message.editable = true


func scroll_to_bottom():
	# wait for message to update the scroll container dimensions
	await scroll_container.get_v_scroll_bar().changed

	# scroll to bottom
	scroll_container.scroll_vertical =  scroll_container.get_v_scroll_bar().max_value


## Creates new `MessageMarkdown` and adds it to the hierarchy. Doesn't alter the history list 
func add_history_item(item: ChatHistoryItem) -> MessageMarkdown:
	var msg_node = MessageMarkdown.new_message()
	msg_node.history_item = item
	item.rendered_node = msg_node

	add_child(msg_node)

	scroll_to_bottom()

	# scroll_container.ensure_control_visible(msg_node)

	return msg_node

## Adds a program notification to the chat box
## This message is not saved on project save
func add_program_message(message: String) -> Label:
	var label = Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	add_child(label)
	return label


func render_items():
	var order: int = 0 # the order of the items

	for item in chat_history.HistoryItemList:
		item.Order = order



# region Auto Scroll

# code for auto scroll on message content selection

# determines how much to scroll the chat container scroll container
# 0 being no scroll
# this being a float insted of bool allows for faster
# scroll further the mouse is outside the control
var _scroll_factor:= 0.0
var _text_selection:= false


# will check if theres open chat tab and apply the scroll factor to selected tab
func _process(delta: float):
	if _text_selection: # only if text selection is active for any rich text label
		scroll_container.scroll_vertical += _scroll_factor*3*delta

func _input(event):
	if event is InputEventMouseButton: pass
		# scroll_container.visi

	if not event is InputEventMouseMotion: return

	# Check if is text *probably* being currently selected
	# by checking if mouse is currently pressed
	# and that mouse is outside of the chat tab control

	if (
		Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and
		not scroll_container.get_rect().has_point(scroll_container.get_local_mouse_position())
		and scroll_container.get_local_mouse_position().x > scroll_container.get_rect().position.x
		and scroll_container.get_local_mouse_position().x < scroll_container.get_rect().size.x
	):
		# mouse is outside of chat tab control
		# we check if it's under
		if scroll_container.get_local_mouse_position().y > scroll_container.get_rect().size.y:
			# scroll factor will be positive number thats difference in
			# mouse position and bottom of the chat tab
			_scroll_factor = scroll_container.get_local_mouse_position().y - scroll_container.get_rect().size.y
		# or above it
		else:
			_scroll_factor = scroll_container.get_local_mouse_position().y

	else:
		_scroll_factor = 0


## When image is activated, deactivate all other images as only one at the time can be active
func _on_image_activated(chat_image: ChatImage, active: bool):
	for chi in chat_history.HistoryItemList:
		# skip if there's no rendered node
		if not chi.rendered_node: continue

		for c_image: ChatImage in chi.rendered_node.images:
			if c_image == chat_image: c_image.active = active
			else: c_image.active = false
