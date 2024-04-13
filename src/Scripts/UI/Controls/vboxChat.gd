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
	var box:ChatBox = ChatBox.new(self, ChatBox.CHATTYPE.BOT)
	add_child(Message.bot_message(message))
	pass


func add_message():
	var user_turn:String = %txtMainUserInput.text
	pass


func add_user_message(message:BotResponse):
	add_child(Message.user_message(message))
	pass

func render_items():
	var order: int = 0 # the order of the items

	for item in chat_history.HistoryItemList:
		item.Order = order
