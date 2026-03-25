class_name ActivityLogEntry
extends VBoxContainer
## A single tool call entry in the Activity Log.

var _tool_name: String
var _arguments: Dictionary
var _result: Dictionary
var _expanded: bool = false
var _details: VBoxContainer
var _toggle_btn: Button

func _init(tool_name: String, arguments: Dictionary, result: Dictionary) -> void:
	_tool_name = tool_name
	_arguments = arguments
	_result = result

func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	# Header row: toggle button + summary
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	add_child(header)

	_toggle_btn = Button.new()
	_toggle_btn.text = "▶"
	_toggle_btn.flat = true
	_toggle_btn.custom_minimum_size = Vector2(24, 20)
	_toggle_btn.add_theme_font_size_override("font_size", 11)
	_toggle_btn.pressed.connect(_toggle_details)
	header.add_child(_toggle_btn)

	# Timestamp
	var time_label := Label.new()
	var time_dict := Time.get_time_dict_from_system()
	time_label.text = "%02d:%02d:%02d" % [time_dict.hour, time_dict.minute, time_dict.second]
	time_label.add_theme_font_size_override("font_size", 11)
	time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	header.add_child(time_label)

	# Tool name
	var name_label := Label.new()
	name_label.text = _tool_name.replace("minerva_", "")
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
	header.add_child(name_label)

	# Key arg
	var arg_text := _get_key_arg()
	if not arg_text.is_empty():
		var arg_label := Label.new()
		arg_label.text = arg_text
		arg_label.add_theme_font_size_override("font_size", 11)
		arg_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		arg_label.clip_text = true
		arg_label.size_flags_horizontal = SIZE_EXPAND_FILL
		header.add_child(arg_label)

	# Result summary
	var result_label := Label.new()
	result_label.text = _get_result_summary()
	result_label.add_theme_font_size_override("font_size", 11)
	var success = _result.get("success", null)
	result_label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4) if success else Color(1.0, 0.4, 0.4))
	header.add_child(result_label)

	# Details container (hidden by default)
	_details = VBoxContainer.new()
	_details.visible = false
	_details.add_theme_constant_override("separation", 1)
	add_child(_details)

	# Populate details
	_build_details()

	# Separator
	add_child(HSeparator.new())

func _get_key_arg() -> String:
	for key in ["path", "pattern", "command"]:
		if _arguments.has(key):
			var val: String = str(_arguments[key])
			if val.length() > 60:
				val = val.substr(0, 57) + "..."
			return val
	return ""

func _get_result_summary() -> String:
	var success = _result.get("success", null)
	if success == null:
		return ""
	if success:
		for key in ["bytes_written", "replacements", "total_matches", "lines_read"]:
			if _result.has(key):
				return "→ %s %s" % [str(_result[key]), key.replace("_", " ")]
		return "→ ok"
	else:
		var err: String = str(_result.get("error", "failed"))
		if err.length() > 40:
			err = err.substr(0, 37) + "..."
		return "→ %s" % err

func _build_details() -> void:
	var indent := "    "
	for key in _arguments:
		var val: String = str(_arguments[key])
		if val.length() > 200:
			val = val.substr(0, 197) + "..."
		val = val.replace("\n", "\\n")
		var lbl := Label.new()
		lbl.text = "%s%s: %s" % [indent, key, val]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		_details.add_child(lbl)

	for key in _result:
		var val: String = str(_result[key])
		if val.length() > 200:
			val = val.substr(0, 197) + "..."
		val = val.replace("\n", "\\n")
		var lbl := Label.new()
		lbl.text = "%s%s = %s" % [indent, key, val]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.6, 0.5))
		_details.add_child(lbl)

func _toggle_details() -> void:
	_expanded = not _expanded
	_details.visible = _expanded
	_toggle_btn.text = "▼" if _expanded else "▶"
