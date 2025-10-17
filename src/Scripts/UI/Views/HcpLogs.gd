class_name HcpLogs
extends PersistentWindow

@export var _rich_text_label: RichTextLabel
@export var _details_container: Container
@export var _text_edit: TextEdit

enum LOG_TYPE {
	INFO,
	SUCCESS,
	WARNING,
	ERROR,
}

static var _log_color: Dictionary[LOG_TYPE, Color] = {
	LOG_TYPE.INFO: Color.DARK_BLUE,
	LOG_TYPE.SUCCESS: Color.DARK_GREEN,
	LOG_TYPE.WARNING: Color.YELLOW,
	LOG_TYPE.ERROR: Color.DARK_RED,
}

var log_fa: = FileAccess.open("user://hcp.log", FileAccess.WRITE_READ)

func _ready() -> void:
	super()
	Core.client.message_received.connect(_on_message_received)

var _details_data: Array[Dictionary] = []


func add_log_line(text: String, type: = LOG_TYPE.INFO, detailed_data: Dictionary = {}):
	
	var log_line: String

	var time = Time.get_datetime_string_from_system()

	var details_string: String

	if not detailed_data.is_empty():
		log_line = "[bgcolor=%s]%s[/bgcolor] - %s - [url=%s](raw)[/url]\n" % [
			_log_color[type].to_html(),
			time,
			text,
			_details_data.size()
		]

		details_string = JSON.stringify(detailed_data, "\t")
		_details_data.append(detailed_data)

	else:
		log_line = "[bgcolor=%s]%s[/bgcolor] - %s\n" % [
			_log_color[type].to_html(),
			time,
			text
		]


	log_fa.store_line("%s - %s\n%s" % [time, log_line, details_string])

	_rich_text_label.append_text(log_line)


func _on_message_received(msg: Dictionary) -> void:

	var cmd: String = msg.get("cmd", "NA")
	var topic: String = msg.get("topic", msg.get("entity_type", "NA"))
	var brief: String = ""
	var color: = _log_color[LOG_TYPE.INFO]


	match cmd:
		"error":
			brief = msg.get("params", {}).get("error", "Unknown error")
			color = _log_color[LOG_TYPE.ERROR]
		"response":
			color = _log_color[LOG_TYPE.SUCCESS]
		"request":
			color = _log_color[LOG_TYPE.INFO]

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
		_details_data.size(),
	]

	_details_data.append(msg)

	_rich_text_label.append_text(log_string)

	log_fa.store_line("%s - %s\n%s" % [time, log_line, JSON.stringify(msg, "\t")])



func _on_rich_text_label_meta_clicked(meta: Variant) -> void:
	var msg = _details_data[int(meta)]
	_text_edit.text = JSON.stringify(msg, "\t")

	_details_container.visible = true


func _on_close_details_button_pressed() -> void:
	_details_container.visible = false
