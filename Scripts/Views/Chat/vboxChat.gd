# Manages a single chat interaction
class_name VBoxChat
extends VBoxContainer

signal memorize_item(text_to_memorize:String)

var chat_history: ChatHistory

## initialize the box
func _init():
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pass

## create some sort of textbox and put the content in there.
func add_bot_message(message:BotResponse):

	add_child(Message.bot_message(message))

	# var chars_per_line = 54.0
	# var vertical_ppi = 25.3
	# var number_lines = len(message.FullText) / chars_per_line
	# var vertical_res = vertical_ppi + number_lines * vertical_ppi
	# var min_size = Vector2(0.0, vertical_res)
	# var texty = TextEdit.new()
	# texty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# texty.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# texty.wrap_mode = 1
	# texty.autowrap_mode = TextServer.AUTOWRAP_WORD
	# texty.custom_minimum_size = min_size
	# texty.scroll_horizontal = false
	# texty.scroll_vertical = false
	# texty.text = message.FullText
	# add_child(texty)
	pass


func add_user_message(message:BotResponse):

	add_child(Message.user_message(message))

func render_items():
	var order: int = 0 # the order of the items

	for item in chat_history.HistoryItemList:
		item.Order = order
