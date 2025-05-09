extends PersistentWindow

@export var _rich_text_label: RichTextLabel
@export var _text_edit: TextEdit


var log_fa: = FileAccess.open("user://hcp.log", FileAccess.WRITE_READ)

func _ready() -> void:
	super()
	Core.client.message_received.connect(_on_message_received)


func _on_message_received(msg: Dictionary) -> void:

	var cmd: String = msg.get("cmd", "NA")
	var topic: String = msg.get("topic", "NA")
	var brief: String = ""
	var color: Color = Color.DARK_BLUE


	match cmd:
		"error":
			brief = msg.get("params", {}).get("error", "Unknown error")
			color = Color.DARK_RED
		"response":
			brief = msg.get("params", {}).get("result", {})
			color = Color.DARK_GREEN
		"request":
			brief = msg.get("params", {}).get("data", {})
			color = Color.DARK_ORANGE
		_:
			brief = ""

	var log_line = "%s from %s: %s" % [
		msg.get("cmd", "NA"),
		topic,
		brief,
	]

	var time = Time.get_datetime_string_from_system()

	var log_string = "[bgcolor=%s]%s[/bgcolor] - %s - [url=%s](raw)[/url]\n" % [
		color.to_html(),
		time,
		log_line,
		JSON.stringify(msg, "\t"),
	]

	_rich_text_label.append_text(log_string)

	log_fa.store_line("%s - %s" % [time, log_line])


func _on_rich_text_label_meta_clicked(meta: Variant) -> void:
	_text_edit.text = str(meta)

	_text_edit.visible = true
