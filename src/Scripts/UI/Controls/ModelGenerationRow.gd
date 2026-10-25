class_name ModelGenerationRow
extends VBoxContainer
## One advertised number or boolean; the shared resolver owns validation.

signal edited(option: String, value: Variant, explicit: bool)

@onready var _title: Label = $Heading/Label
@onready var _custom: CheckButton = $Heading/Custom
@onready var _reset: Button = $Heading/Reset
@onready var _slider: HSlider = $Numeric/Slider
@onready var _spin: SpinBox = $Numeric/Value
@onready var _toggle: CheckButton = $Toggle
@onready var _default: Label = $Default
@onready var _numeric: HBoxContainer = $Numeric
var _option: String = ""
var _boolean: bool = false
var _loading: bool = false


func _ready() -> void:
	_custom.toggled.connect(func(pressed: bool) -> void: _submit(pressed))
	_reset.pressed.connect(func() -> void: _submit(false))
	_slider.value_changed.connect(func(value: float) -> void:
		_spin.set_value_no_signal(value)
		_submit(true))
	_spin.value_changed.connect(func(value: float) -> void:
		_slider.set_value_no_signal(value)
		_submit(true))
	_toggle.toggled.connect(func(_pressed: bool) -> void: _submit(true))


func configure(option: String, rule: Dictionary, value: Variant, explicit: bool) -> void:
	_loading = true
	_option = option
	_boolean = rule.type == "boolean"
	var writable: bool = rule.get("overridable", true)
	_title.text = option.capitalize() + (" (fixed)" if not writable else "")
	tooltip_text = str(rule.get("description", ""))
	_title.tooltip_text = tooltip_text
	_slider.tooltip_text = tooltip_text
	_spin.tooltip_text = tooltip_text
	_toggle.tooltip_text = tooltip_text
	_custom.set_pressed_no_signal(explicit)
	_custom.disabled = not writable
	_reset.disabled = not writable or not explicit
	_toggle.visible = _boolean
	_numeric.visible = not _boolean
	_toggle.disabled = not writable
	var enabled: bool = false
	if value is bool:
		enabled = value
	_toggle.set_pressed_no_signal(enabled)
	if not _boolean:
		var minimum: float = rule.get("minimum", 0.0)
		var maximum: float = rule.get("maximum", 2147483647.0)
		var step_size: float = 1.0 if rule.type == "integer" else 0.0
		for control: Range in [_slider, _spin]:
			control.min_value = minimum
			control.max_value = maximum
			control.step = step_size
		var displayed: float = minimum
		if value is int or value is float:
			displayed = value
		_spin.set_value_no_signal(displayed)
		_slider.set_value_no_signal(displayed)
		_spin.custom_arrow_step = 1.0 if rule.type == "integer" else 0.01
		_spin.editable = writable and explicit
		_slider.editable = writable and explicit
	var inherited: Variant = rule.get("default")
	var default_text: String = "Unspecified" if inherited == null else JSON.stringify(inherited)
	if rule.type == "number" and inherited != null and not "." in default_text and not "e" in default_text:
		default_text += ".0"
	_default.text = "Default: %s · Source: %s" % [default_text, str(rule.get("default_source", "service default")).replace("_", " ")]
	if rule.get("exclusive_minimum", false):
		_default.text += " · Must be greater than %s" % str(rule.minimum)
	_loading = false


func _submit(explicit: bool) -> void:
	if not _loading:
		var value: Variant = _spin.value
		if _boolean:
			value = _toggle.button_pressed
		edited.emit(_option, value, explicit)
