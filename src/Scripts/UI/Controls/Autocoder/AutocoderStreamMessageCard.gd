class_name AutocoderStreamMessageCard
extends PanelContainer

@onready var _icon_label: Label = %IconLabel
@onready var _content_label: Label = %ContentLabel

var _role: String = "assistant"

func _ready():
	pass

func setup(content: String, role: String = "assistant"):
	_role = role
	
	if _content_label:
		_content_label.text = content
	
	_update_style()

func _update_style():
	if not _icon_label:
		return
	
	match _role:
		"assistant":
			_icon_label.text = "🤖"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
		"user":
			_icon_label.text = "👤"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1))
		"error":
			_icon_label.text = "⚠️"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
		"system":
			_icon_label.text = "⚙️"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_:
			_icon_label.text = "💬"
