class_name ModelContextSettings
extends VBoxContainer
## Scene-backed model budgets. Loading never persists a choice.

signal settings_changed
const ROWS: Dictionary[String, NodePath] = {"context_window": ^"Window", "auto_compact_at": ^"Compact", "max_output_tokens": ^"Output"}
@onready var _clear_button: Button = $Clear
@onready var _error: Label = $Error
@onready var _source: Label = $Source
var _provider: BaseProvider
var _loading: bool = false


func _ready() -> void:
	_clear_button.pressed.connect(_clear)
	for key: String in ROWS:
		var row: Node = get_node(ROWS[key])
		var spin: SpinBox = row.get_node("Value")
		var reset: Button = row.get_node("Reset")
		spin.value_changed.connect(func(value: float) -> void: _edit(key, int(value), false))
		reset.pressed.connect(func() -> void: _edit(key, 0, true))


func refresh(model_key: String = "") -> void:
	if is_instance_valid(_provider) and (model_key.is_empty() or model_key == _provider.get_model_settings_key()):
		configure(_provider)


func configure(provider: BaseProvider) -> void:
	_provider = provider
	_loading = true
	var resolved := GenerationOptions.context_for(provider)
	_error.text = "" if resolved.success else str(resolved.error_message)
	_source.text = str(resolved.get("output_notice", ""))
	var definitions: Dictionary = resolved.get("schema", {})
	var values: Dictionary = resolved.get("values", {})
	var explicit: Dictionary = resolved.get("explicit", {})
	for key: String in ROWS:
		var row: HBoxContainer = get_node(ROWS[key])
		row.visible = resolved.success and definitions.has(key)
		if not row.visible:
			continue
		var rule: Dictionary = definitions[key]
		var spin: SpinBox = row.get_node("Value")
		spin.min_value = rule.minimum
		spin.max_value = rule.maximum
		var value: float = values[key]
		spin.set_value_no_signal(value)
		var inherited: int = rule.default
		spin.tooltip_text = "Default: %d" % inherited
		var reset: Button = row.get_node("Reset")
		reset.disabled = not explicit.has(key)
	_loading = false


func _edit(key: String, value: int, reset: bool) -> void:
	if _loading or not is_instance_valid(_provider):
		return
	var saved := GenerationOptions.saved_for(_provider)
	if reset:
		saved.erase(key)
		if key == "max_output_tokens":
			saved.erase("max_tokens")
			if saved.get("options") is Dictionary:
				var aliases: Dictionary = saved.options
				aliases.erase("num_predict")
	else:
		saved[key] = value
	var result := GenerationOptions.save_model(_provider, saved)
	refresh()
	if result.success:
		_error.text = str(result.get("notice", ""))
		settings_changed.emit()
	else:
		_error.text = str(result.error_message)


func _clear() -> void:
	if not is_instance_valid(_provider):
		return
	var saved := GenerationOptions.saved_for(_provider)
	for key: String in ModelContextOptions.KEYS:
		saved.erase(key)
	saved.erase("max_tokens")
	if saved.get("options") is Dictionary:
		var aliases: Dictionary = saved.options
		aliases.erase("num_predict")
	var result := GenerationOptions.save_model(_provider, saved)
	refresh()
	if result.success:
		settings_changed.emit()
	else:
		_error.text = str(result.error_message)
