class_name AutocoderIssueRow
extends PanelContainer

@onready var _location_label: Label = %LocationLabel
@onready var _severity_label: Label = %SeverityLabel
@onready var _summary_label: Label = %SummaryLabel
@onready var _excerpt_label: Label = %ExcerptLabel


func setup(location: String, severity: String, summary: String, excerpt: String, has_fix: bool) -> void:
	_location_label.text = location
	_severity_label.text = severity if not severity.is_empty() else "info"
	_summary_label.text = summary

	if excerpt.is_empty():
		_excerpt_label.visible = false
	else:
		_excerpt_label.visible = true
		_excerpt_label.text = excerpt

	_apply_severity_style(severity, has_fix)


func _apply_severity_style(severity: String, has_fix: bool) -> void:
	var color = Color(0.7, 0.7, 0.7)
	match severity.to_lower():
		"critical", "high":
			color = Color(1.0, 0.4, 0.4)
		"medium":
			color = Color(1.0, 0.8, 0.4)
		"low":
			color = Color(0.6, 0.8, 1.0)
		_:
			color = Color(0.7, 0.7, 0.7)

	if has_fix:
		_severity_label.text = "%s (fix)" % _severity_label.text

	_severity_label.add_theme_color_override("font_color", color)
