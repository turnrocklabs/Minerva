class_name AutocoderStreamToolCard
extends PanelContainer

@onready var _tool_name_label: Label = %ToolNameLabel
@onready var _description_label: Label = %DescriptionLabel
@onready var _status_label: Label = %StatusLabel
@onready var _output_label: Label = %OutputLabel
@onready var _output_container: Control = %OutputContainer

var _tool_name: String = ""
var _status: String = "running"

func _ready():
	if _output_container:
		_output_container.visible = false

func setup(tool_name: String, description: String, status: String = "running"):
	_tool_name = tool_name
	_status = status
	
	if _tool_name_label:
		_tool_name_label.text = tool_name
	if _description_label:
		_description_label.text = description
	
	_update_status_display()

func update_status(status: String, output: String = ""):
	_status = status
	_update_status_display()
	
	if not output.is_empty() and _output_label:
		_output_label.text = output
		if _output_container:
			_output_container.visible = true

func _update_status_display():
	if not _status_label:
		return
	
	match _status:
		"running":
			_status_label.text = "⏳"
			_status_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
		"completed":
			_status_label.text = "✓"
			_status_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6))
		"error":
			_status_label.text = "✕"
			_status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		_:
			_status_label.text = "•"
			_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
