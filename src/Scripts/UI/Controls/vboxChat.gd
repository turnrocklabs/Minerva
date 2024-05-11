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

## create some sort of textbox and put the content in there.
func add_bot_message(message:BotResponse):
	var msg_node = MessageMarkdown.bot_message(message)
	add_child(msg_node)

	await get_tree().process_frame
	get_parent().ensure_control_visible(msg_node)


# func add_message():
# 	var user_turn:String = %txtMainUserInput.text
# 	pass


func add_user_message(message:BotResponse):
	var msg_node = MessageMarkdown.user_message(message)
	add_child(msg_node)
	
	await get_tree().process_frame
	get_parent().ensure_control_visible(msg_node)

func render_items():
	var order: int = 0 # the order of the items

	for item in chat_history.HistoryItemList:
		item.Order = order
