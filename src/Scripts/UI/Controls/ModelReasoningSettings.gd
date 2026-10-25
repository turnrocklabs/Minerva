class_name ModelReasoningSettings
extends VBoxContainer
## Scene presentation for the shared per-model generation layer.

@onready var _slider: HSlider = $Effort
@onready var _levels_label: Label = $Levels
@onready var _selection: Label = $Selection
@onready var _message: Label = $Message
var _provider: BaseProvider
var _schema: Dictionary = {}
var _stops: Array[String] = []
var _thinking_off: bool = false
var _loading: bool = false
var _model_key: String = ""
var _notice: String = ""
var levels: Array[String] = []
var default_effort: String = ""


func _ready() -> void:
	_slider.value_changed.connect(_on_effort_changed)


func refresh() -> void:
	if is_instance_valid(_provider):
		configure(_provider)


func configure(provider: BaseProvider) -> void:
	var key := provider.get_model_settings_key()
	if key != _model_key:
		_notice = ""
	_model_key = key
	_provider = provider
	_loading = true
	_schema = GenerationOptions.schema_for(provider)
	var resolved := GenerationOptions.for_provider(provider)
	if not resolved.success:
		_show_unavailable(str(resolved.error_message))
		return
	if not str(resolved.notice).is_empty():
		_notice = str(resolved.notice)
	var rule: Dictionary = _schema.get("reasoning_effort", {})
	var advertised_levels: Array = rule.get("enum", [])
	levels = ReasoningSelection.ordered_levels(advertised_levels)
	if levels.is_empty():
		_show_unavailable("This model does not offer reasoning controls." + ("\n" + _notice if not _notice.is_empty() else ""))
		return
	var thinking_rule: Dictionary = _schema.get("enable_thinking", {})
	var thinking_values: Array = thinking_rule.get("enum", [])
	_thinking_off = false in thinking_values
	_stops = levels.duplicate()
	default_effort = str(rule.get("default", ""))
	if _thinking_off and not "off" in _stops and not "none" in _stops:
		_stops.push_front("off")
	if _thinking_off and thinking_rule.get("default") == false:
		default_effort = "off"
	if default_effort.is_empty():
		_stops.push_front("") # Omit the field: the provider owns an unknown default.
	var labels: Array[String] = []
	for effort: String in _stops:
		labels.append(_label(effort))
	_levels_label.text = " · ".join(labels)
	var values: Dictionary = resolved.values
	var effective: String = str(values.get("reasoning_effort", ""))
	if _thinking_off and values.get("enable_thinking") == false:
		effective = "off"
	_slider.max_value = _stops.size() - 1
	_slider.tick_count = _stops.size()
	_slider.set_value_no_signal(_stops.find(effective))
	_selection.text = _label(effective)
	_slider.visible = true
	_levels_label.visible = true
	_selection.visible = true
	_message.text = _notice
	_loading = false


func _show_unavailable(message: String) -> void:
	levels.clear()
	_stops.clear()
	default_effort = ""
	_slider.visible = false
	_levels_label.visible = false
	_selection.visible = false
	_message.text = message
	_loading = false


func _label(effort: String) -> String:
	if effort.is_empty():
		return "Provider default"
	var label := "Off" if effort == "off" else "None" if effort == "none" else effort
	return label + (" (default)" if effort == default_effort else "")


func _on_effort_changed(value: float) -> void:
	if _loading or _provider == null:
		return
	var index := int(value)
	if index < 0 or index >= _stops.size():
		return
	var effort: String = _stops[index]
	var saved := GenerationOptions.saved_for(_provider)
	if effort.is_empty():
		saved.erase("reasoning_effort")
		saved.erase("enable_thinking")
	elif effort == "off" and _thinking_off and not effort in levels:
		saved.erase("reasoning_effort")
		saved["enable_thinking"] = false
	else:
		saved["reasoning_effort"] = effort
		if _thinking_off:
			saved["enable_thinking"] = true
	var result := GenerationOptions.save_model(_provider, saved)
	_notice = ""
	configure(_provider)
	if not result.success:
		_message.text = str(result.error_message)
