# Manages a single chat interaction
class_name VBoxChat
extends VBoxContainer

signal memorize_item(text_to_memorize:String)

var _dummy_msg_node: Node
var loading_response := false:
	set(value):
		if value: _create_dummy_response()
		elif is_instance_valid(_dummy_msg_node): _dummy_msg_node.free()
		loading_response = value

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


func _create_dummy_response():
	var br = BotResponse.new()
	br.FullText = "●︎●︎●︎"
	_dummy_msg_node = await add_bot_message(br)


## create some sort of textbox and put the content in there.
func add_bot_message(message:BotResponse) -> MessageMarkdown:
	var msg_node = MessageMarkdown.bot_message(message)
	add_child(msg_node)

	await get_tree().process_frame
	get_parent().ensure_control_visible(msg_node)

	return msg_node


func add_user_message(message:BotResponse) -> MessageMarkdown:
	var msg_node = MessageMarkdown.user_message(message)
	add_child(msg_node)
	
	await get_tree().process_frame
	get_parent().ensure_control_visible(msg_node)

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
