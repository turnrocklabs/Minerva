class_name Message
extends HBoxContainer

@export var left_control: Control
@export var right_control: Control
@export var label: RichTextLabel

@export var user_message_color: Color
@export var bot_message_color: Color

static func bot_message(message: BotResponse) -> Message:
	var msg: Message = preload("res://Scripts/Views/Chat/Message.tscn").instantiate()
	msg.right_control.visible = true
	msg.label.text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.BLACK)
	
	
	var style: StyleBox = msg.get_node("PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.bot_message_color


	return msg

static func user_message(message: BotResponse) -> Message:
	var msg: Message = preload("res://Scripts/Views/Chat/Message.tscn").instantiate()
	msg.left_control.visible = true
	msg.label.text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.WHITE)

	var style: StyleBox = msg.get_node("PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.user_message_color

	return msg