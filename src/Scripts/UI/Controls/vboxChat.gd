# Manages a single chat interaction
class_name VBoxChat
extends VBoxContainer

signal memorize_item(text_to_memorize:String)


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
	pass


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
	var scroll_container = get_parent() as ScrollContainer

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
