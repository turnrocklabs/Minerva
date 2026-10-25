class_name SchemaGenerationSettings
extends VBoxContainer
## Native model profile presentation; all writes use GenerationOptions.

const ROW: PackedScene = preload("res://Scenes/controls/ModelGenerationRow.tscn")
@onready var _basic: VBoxContainer = $Basic
@onready var _advanced: VBoxContainer = $Advanced
@onready var _expand: CheckButton = $ExpandAdvanced
@onready var _error: Label = $Error
@onready var _clear_button: Button = $Clear
var _provider: BaseProvider
var _reasoning: ModelReasoningSettings
var _rows: Dictionary[String, ModelGenerationRow] = {}
var _model_key: String = ""
var _shape: Dictionary = {}


func _ready() -> void:
	_expand.toggled.connect(func(pressed: bool) -> void: _advanced.visible = pressed)
	_clear_button.pressed.connect(_clear)


func refresh(model_key: String = "") -> void:
	if is_instance_valid(_provider) and (model_key.is_empty() or model_key == _provider.get_model_settings_key()):
		configure(_provider, _reasoning)


func configure(provider: BaseProvider, reasoning: ModelReasoningSettings) -> void:
	_provider = provider
	_reasoning = reasoning
	var resolved := GenerationOptions.for_provider(provider)
	var profile: Dictionary = resolved.get("profile", {})
	visible = resolved.success and not profile.is_empty()
	if not visible:
		return
	var schema: Dictionary = resolved.schema
	var shape: Dictionary = profile.parameters
	var key := provider.get_model_settings_key()
	if key != _model_key or shape != _shape:
		for row: ModelGenerationRow in _rows.values():
			row.get_parent().remove_child(row)
			row.queue_free()
		_rows.clear()
		_model_key = key
		_shape = shape.duplicate(true)
		_expand.set_pressed_no_signal(false)
		_advanced.hide()
		for option: String in schema:
			if option == "reasoning_effort":
				continue
			var row := ROW.instantiate() as ModelGenerationRow
			row.name = option
			var rule: Dictionary = schema[option]
			var parent: VBoxContainer = _advanced if rule.get("advanced", false) else _basic
			parent.add_child(row)
			row.edited.connect(_edit)
			_rows[option] = row
	var values: Dictionary = resolved.values
	var explicit: Dictionary = GenerationOptions.saved_for(provider)
	for option: String in _rows:
		var rule: Dictionary = schema[option]
		_rows[option].configure(option, rule, values.get(option), explicit.has(option))
	_reasoning.configure(provider, true)
	_reasoning.visible = schema.has("reasoning_effort")
	var effort_rule: Dictionary = schema.get("reasoning_effort", {})
	var effort_parent: VBoxContainer = _advanced if effort_rule.get("advanced", false) else _basic
	if _reasoning.get_parent() != effort_parent:
		_reasoning.reparent(effort_parent)
	_expand.visible = _advanced.get_child_count() > 0
	_error.text = ""


func _edit(option: String, value: Variant, explicit: bool) -> void:
	var saved := GenerationOptions.saved_for(_provider)
	if explicit:
		saved[option] = value
	else:
		saved.erase(option)
	var result := GenerationOptions.save_model(_provider, saved)
	if result.success:
		refresh()
	else:
		_error.text = str(result.error_message)


func _clear() -> void:
	var result := GenerationOptions.save_model(_provider, {})
	if result.success:
		refresh()
	else:
		_error.text = str(result.error_message)
