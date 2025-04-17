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
	
	# When exiting it could happen we get a "Left operand if 'is' is a  previously freed instance"
	# so just check if it's still valid, if not we're exiting the program anyways so it doesn't matter
	if is_instance_valid(chat_history.provider) and chat_history.provider is HumanProvider:
		# We want to enable editing for all messages if using the Human Provider
		for child in get_children():
			if child is MessageMarkdown:
				child.editable = true
				child.regeneratable = false

		return

	var last_message: MessageMarkdown
	# disable edit for all user messages
	for child in get_children():
		if child is MessageMarkdown:
			child.editable = false
			last_message = child
	
	if not last_message: return
	
	last_message.editable = true

var scroll_tween: Tween
var scroll_time: float = 0.8

func kill_scroll_tween() -> void:
	if scroll_tween:
		scroll_tween.kill()

func scroll_to_bottom():
	# wait for message to update the scroll container dimensions
	await scroll_container.get_v_scroll_bar().changed
	# scroll to bottom
	kill_scroll_tween()
	scroll_tween = create_tween().set_ease(Tween.EASE_IN)
	scroll_tween.tween_property(scroll_container, "scroll_vertical", scroll_container.get_v_scroll_bar().max_value, scroll_time)


func scroll_to_top() -> void:
	# wait for message to update the scroll container dimensions
	await scroll_container.get_v_scroll_bar().changed
	# scroll to top
	kill_scroll_tween()
	scroll_tween = create_tween().set_ease(Tween.EASE_IN)
	scroll_tween.tween_property(scroll_container, "scroll_vertical", scroll_container.get_v_scroll_bar().min_value, scroll_time)


func ensure_node_is_visible(node: Control) -> void:
	
	# Wait for the scroll bar to update
	await scroll_container.get_v_scroll_bar().changed
	# Wait for the next frame to ensure the node is added to the scene
	await get_tree().process_frame
	var scroll_to: int = 0
	# Calculate the total height of all nodes above the target node
	for i in get_children():
		if node == i:
			break
		else:
			if i is Control:
				scroll_to += i.size.y
				
	var visible_height = scroll_container.size.y
	var node_height = node.size.y
	kill_scroll_tween()
	scroll_tween = create_tween().set_ease(Tween.EASE_IN)
	
	if node_height > visible_height:
		scroll_tween.tween_property(scroll_container, "scroll_vertical", scroll_to, scroll_time)
	else:
		var center_position = scroll_to - (visible_height - node_height) / 2
		# Clamp the scroll position between min and max values
		var max_scroll = scroll_container.get_v_scroll_bar().max_value
		scroll_tween.tween_property(scroll_container, "scroll_vertical", clamp(center_position, 0, max_scroll), scroll_time)



## Creates new `MessageMarkdown` and adds it to the hierarchy. Doesn't alter the history list 
func add_history_item(item: ChatHistoryItem) -> MessageMarkdown:
	var msg_node = MessageMarkdown.new_message()
	msg_node.history_item = item
	item.rendered_node = msg_node

	add_child(msg_node)

	#scroll_to_bottom()

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
# this being a float instead of bool allows for faster
# scroll further the mouse is outside the control
var _scroll_factor:= 0.0
var _text_selection:= false
# will check if theres open chat tab and apply the scroll factor to selected tab
func _process(delta: float):
	if _text_selection: # only if text selection is active for any rich text label
		scroll_container.scroll_vertical += _scroll_factor*(5*delta)


func _input(event):
	if event is InputEventMouseMotion: 
		if scroll_container.get_rect().has_point(event.position):
			_scroll_factor = 0
			return
		if ( _text_selection 
		and scroll_container.global_position.y > get_global_mouse_position().y 
		or scroll_container.global_position.y + scroll_container.size.y < get_global_mouse_position().y ):
			if scroll_container.get_local_mouse_position().y > scroll_container.position.y + scroll_container.get_rect().size.y:
				# scroll factor will be positive number thats difference in
				# mouse position and bottom of the chat tab
				_scroll_factor = scroll_container.get_local_mouse_position().y - scroll_container.get_rect().size.y 
			# or above it
			elif scroll_container.get_local_mouse_position().y < scroll_container.position.y:
				_scroll_factor = scroll_container.get_local_mouse_position().y
		return
	# Check if is text *probably* being currently selected
	# by checking if mouse is currently pressed
	# and that mouse is outside of the chat tab control
	
	elif event is InputEventMouseButton:
		if (
			event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed()
			and scroll_container.get_rect().has_point(scroll_container.get_local_mouse_position())
			and event.get_action_strength("draw") > 0.2
		):
			_text_selection = true
			_scroll_factor = 0
		elif event.button_index == MOUSE_BUTTON_LEFT and !event.is_pressed():
			_scroll_factor = 0
			_text_selection = false


## When image is activated, deactivate all other images as only one at the time can be active
func _on_image_activated(chat_image: ChatImage, active: bool):
	for chi in chat_history.HistoryItemList:
		# skip if there's no rendered node
		if not chi.rendered_node: continue

		for c_image: ChatImage in chi.rendered_node.images:
			if c_image == chat_image: c_image.active = active
			else: c_image.active = false
