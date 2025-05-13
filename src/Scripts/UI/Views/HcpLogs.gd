extends PersistentWindow

@export var _rich_text_label: RichTextLabel
@export var _text_edit: TextEdit


var log_fa: = FileAccess.open("user://hcp.log", FileAccess.WRITE_READ)

func _ready() -> void:
	super()
	Core.client.message_received.connect(_on_message_received)

var _received_data: Array[Dictionary] = []

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
			color = Color.DARK_GREEN
		"request":
			color = Color.DARK_ORANGE

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
		_received_data.size(),
	]

	_received_data.append(msg)

	_rich_text_label.append_text(log_string)

	log_fa.store_line("%s - %s\n%s" % [time, log_line, JSON.stringify(msg, "\t")])


func _on_rich_text_label_meta_clicked(meta: Variant) -> void:
	var msg = _received_data[int(meta)]
	_text_edit.text = JSON.stringify(msg, "\t")

	_text_edit.visible = true
