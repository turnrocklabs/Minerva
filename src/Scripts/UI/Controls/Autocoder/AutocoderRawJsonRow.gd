class_name AutocoderRawJsonRow
extends PanelContainer

@onready var _title_label: Label = %TitleLabel
@onready var _json_text: TextEdit = %JsonTextEdit


func setup(title: String, data: Variant) -> void:
	_title_label.text = title
	_json_text.text = JSON.stringify(data, "  ")
