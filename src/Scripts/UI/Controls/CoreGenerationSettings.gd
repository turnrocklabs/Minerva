class_name CoreGenerationSettings
extends VBoxContainer
## Scene-backed editor for explicit chat/model layers. Loading never writes settings.

const ROWS := {"temperature": "Temperature", "max_tokens": "MaxTokens", "num_ctx": "Context", "num_gpu": "Gpu"}
var _provider: CoreProvider
var _history: ChatHistory
var _loading := false


func _ready() -> void:
	$Scope.add_item("This chat")
	$Scope.add_item("Model defaults")
	$Scope.item_selected.connect(func(_index): _load_values())
	$Clear.pressed.connect(_clear_layer)
	for option in ROWS:
		var row := get_node(ROWS[option])
		row.get_node("Override").toggled.connect(func(_pressed): _edit(option))
		row.get_node("Value").value_changed.connect(func(_value): _edit(option))


func configure(provider: CoreProvider, history: ChatHistory = null) -> void:
	_provider = provider
	_history = history
	$Scope.set_item_disabled(0, history == null)
	if history == null:
		$Scope.select(1)
	_load_values()


func _load_values() -> void:
	_loading = true
	var model_layer: bool = $Scope.selected == 1
	var explicit := GenerationOptions.saved_for(_provider) if model_layer else _history.GenerationOverrides
	var request := {} if model_layer else {GenerationOptions.CHAT_LAYER: explicit}
	var resolved := GenerationOptions.for_provider(_provider, request)
	$Error.text = "" if resolved.success else resolved.error_message
	for option in ROWS:
		var row := get_node(ROWS[option]) as HBoxContainer
		row.visible = resolved.success and resolved.schema.has(option)
		if not row.visible:
			continue
		var rule: Dictionary = resolved.schema[option]
		var spin := row.get_node("Value") as SpinBox
		spin.min_value = float(rule.get("minimum", 0))
		spin.max_value = float(rule.get("maximum", 2147483647))
		spin.step = 0.01 if rule.type == "number" else 1.0
		spin.set_value_no_signal(resolved.values.get(option, spin.min_value))
		var selected := explicit.has(option)
		(row.get_node("Override") as CheckButton).set_pressed_no_signal(selected)
		spin.editable = selected
		spin.tooltip_text = "Source: %s" % resolved.sources.get(option, "service default")
	_loading = false


func _edit(option: String) -> void:
	if _loading or _provider == null:
		return
	var model_layer: bool = $Scope.selected == 1
	var explicit := GenerationOptions.saved_for(_provider) if model_layer else _history.GenerationOverrides.duplicate(true)
	var row := get_node(ROWS[option])
	if row.get_node("Override").button_pressed:
		explicit[option] = row.get_node("Value").value
	else:
		explicit.erase(option)
	var result := GenerationOptions.save_model(_provider, explicit) if model_layer else GenerationOptions.set_chat(_history, explicit)
	if not result.success:
		$Error.text = result.error_message
		return
	_load_values()


func _clear_layer() -> void:
	if _loading or _provider == null:
		return
	var result := GenerationOptions.save_model(_provider, {}) if $Scope.selected == 1 else GenerationOptions.set_chat(_history, {})
	if not result.success:
		$Error.text = result.error_message
		return
	_load_values()
