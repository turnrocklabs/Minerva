class_name AutocoderIssueRow
extends PanelContainer

## Interactive issue row that displays review findings with expandable details

signal issue_clicked(file_path: String, line_number: String)

@onready var _location_label: Label = %LocationLabel
@onready var _severity_label: Label = %SeverityLabel
@onready var _summary_label: Label = %SummaryLabel
@onready var _excerpt_label: Label = %ExcerptLabel

var _file_path: String = ""
var _line_number: String = ""
var _has_fix: bool = false
var _is_expanded: bool = false
var _full_excerpt: String = ""


func _ready() -> void:
	# Make location label clickable
	if _location_label:
		_location_label.mouse_filter = Control.MOUSE_FILTER_STOP
		_location_label.gui_input.connect(_on_location_input)
		_location_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	# Make excerpt expandable
	if _excerpt_label:
		_excerpt_label.gui_input.connect(_on_excerpt_input)
		_excerpt_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func setup(location: String, severity: String, summary: String, excerpt: String, has_fix: bool) -> void:
	# Parse location to extract file path and line
	var loc_parts = location.split(":")
	if loc_parts.size() >= 1:
		_file_path = loc_parts[0]
	if loc_parts.size() >= 2:
		_line_number = loc_parts[1]
	
	_has_fix = has_fix
	_full_excerpt = excerpt
	
	_location_label.text = location
	_severity_label.text = severity if not severity.is_empty() else "info"
	_summary_label.text = summary

	if excerpt.is_empty():
		_excerpt_label.visible = false
	else:
		_excerpt_label.visible = true
		# Show truncated excerpt initially
		_update_excerpt_display()

	_apply_severity_style(severity, has_fix)


func _apply_severity_style(severity: String, has_fix: bool) -> void:
	var color = Color(0.7, 0.7, 0.7)
	var icon = "⚠️"
	
	match severity.to_lower():
		"critical", "high":
			color = Color(1.0, 0.4, 0.4)
			icon = "🔴"
		"medium":
			color = Color(1.0, 0.8, 0.4)
			icon = "🟠"
		"low":
			color = Color(0.6, 0.8, 1.0)
			icon = "🔵"
		"info":
			color = Color(0.7, 0.7, 0.7)
			icon = "ℹ️"
		_:
			color = Color(0.7, 0.7, 0.7)

	var severity_text = severity if not severity.is_empty() else "info"
	if has_fix:
		severity_text = "%s ✓fix" % severity_text

	_severity_label.text = severity_text
	_severity_label.add_theme_color_override("font_color", color)
	
	# Update the icon in the parent
	var icon_label = get_node_or_null("MarginContainer/VBoxContainer/Header/Icon")
	if icon_label:
		icon_label.text = icon


func _update_excerpt_display() -> void:
	"""Update excerpt display based on expanded state"""
	if _full_excerpt.is_empty():
		_excerpt_label.visible = false
		return
	
	_excerpt_label.visible = true
	
	if _is_expanded:
		_excerpt_label.text = _full_excerpt
	else:
		# Show truncated version with hint to expand
		var truncated = _full_excerpt
		if truncated.length() > 200:
			truncated = truncated.substr(0, 200) + "... [click to expand]"
		elif truncated.contains("\n"):
			var lines = truncated.split("\n")
			if lines.size() > 3:
				truncated = "\n".join(lines.slice(0, 3)) + "\n... [click to expand]"
		_excerpt_label.text = truncated


func _on_location_input(event: InputEvent) -> void:
	"""Handle click on location label - copy to clipboard"""
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var full_location = _file_path
			if not _line_number.is_empty():
				full_location += ":%s" % _line_number
			
			DisplayServer.clipboard_set(full_location)
			
			# Visual feedback
			var original_text = _location_label.text
			_location_label.text = "📋 Copied!"
			
			# Emit signal for potential navigation
			issue_clicked.emit(_file_path, _line_number)
			
			await get_tree().create_timer(1.0).timeout
			_location_label.text = original_text


func _on_excerpt_input(event: InputEvent) -> void:
	"""Handle click on excerpt label - toggle expand/collapse"""
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_is_expanded = not _is_expanded
			_update_excerpt_display()
