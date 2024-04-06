class_name Message
extends HBoxContainer

@export var left_control: Control
@export var right_control: Control
@export var label: RichTextLabel


static func bot_message(message: BotResponse) -> Message:
	var msg: Message = preload("res://Scripts/Views/Chat/Message.tscn").instantiate()
	msg.left_control.visible = true
	msg.label.text = message.FullText
	return msg

static func user_message(message: BotResponse) -> Message:
	var msg: Message = preload("res://Scripts/Views/Chat/Message.tscn").instantiate()
	msg.right_control.visible = true
	msg.label.text = message.FullText
	return msg
