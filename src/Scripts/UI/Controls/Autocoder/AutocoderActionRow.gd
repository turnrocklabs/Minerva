class_name AutocoderActionRow
extends PanelContainer

@onready var _summary_label: Label = %SummaryLabel
@onready var _status_label: RichTextLabel = %StatusLabel
@onready var _secondary_label: Label = %SecondaryLabel


func setup(summary: String, status: String, secondary: String) -> void:
	_summary_label.text = summary
	_secondary_label.text = secondary
	_secondary_label.visible = not secondary.is_empty()

	_apply_status_style(status)


func update_status(status: String) -> void:
	"""Update only the status, keeping summary and secondary text"""
	_apply_status_style(status)


func _apply_status_style(status: String) -> void:
	_status_label.clear()

	var status_text = status.replace("_", " ")  # Remove underscores

	match status.to_lower():
		"in_progress":
			# Pulsing blue text for in progress
			_status_label.append_text("[pulse freq=2.0 color=#7fddff ease=-2.0]%s[/pulse]" % status_text)
		"complete", "success":
			# Green text for complete
			_status_label.push_color(Color(0.4, 1.0, 0.4))
			_status_label.append_text(status_text)
			_status_label.pop()
		"error", "failed":
			# Red text for errors
			_status_label.push_color(Color(1.0, 0.4, 0.4))
			_status_label.append_text(status_text)
			_status_label.pop()
		_:
			# Gray text for other states
			_status_label.push_color(Color(0.6, 0.6, 0.6))
			_status_label.append_text(status_text)
			_status_label.pop()
