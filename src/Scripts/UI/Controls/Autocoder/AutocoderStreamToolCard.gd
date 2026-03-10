class_name AutocoderStreamToolCard
extends PanelContainer

@onready var _tool_name_label: Label = %ToolNameLabel
@onready var _description_label: Label = %DescriptionLabel
@onready var _status_label: Label = %StatusLabel
@onready var _output_label: Label = %OutputLabel
@onready var _output_container: Control = %OutputContainer
@onready var _expand_button: Button = %ExpandButton

var _tool_name: String = ""
var _status: String = "running"
var _expanded: bool = false
var _expand_tween: Tween
var _activity_tween: Tween
var _has_output: bool = false
const EXPAND_DURATION: float = 0.3
const EXPAND_ICON_COLOR: Color = Color(0.16, 1.0, 1.0, 1.0)

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
		_has_output = true
		# Auto-expand on completion if there's output
		if _expanded and _output_container:
			_output_container.visible = true

func _update_status_display():
	if not _status_label:
		return

	# Stop any existing activity pulse
	_stop_activity_pulse()

	match _status:
		"running":
			_status_label.text = "..."
			_status_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
			_start_activity_pulse()
		"completed":
			_status_label.text = "done"
			_status_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6))
		"error":
			_status_label.text = "err"
			_status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		_:
			_status_label.text = "..."
			_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))


## --- Activity Pulse ---

func _start_activity_pulse() -> void:
	if _activity_tween and _activity_tween.is_running():
		return
	_activity_tween = create_tween().set_loops()
	_activity_tween.tween_property(_status_label, "modulate:a", 0.3, 0.5).set_trans(Tween.TRANS_SINE)
	_activity_tween.tween_property(_status_label, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)


func _stop_activity_pulse() -> void:
	if _activity_tween and _activity_tween.is_running():
		_activity_tween.kill()
		_activity_tween = null
	if _status_label:
		_status_label.modulate.a = 1.0


## --- Expand / Collapse ---

func _on_expand_button_pressed() -> void:
	_expanded = not _expanded
	if _expanded:
		_expand_content()
	else:
		_contract_content()


func _expand_content() -> void:
	# Show output if we have it
	if _has_output and _output_container:
		_output_container.visible = true

	if _expand_tween and _expand_tween.is_running():
		_expand_tween.kill()
	_expand_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_expand_tween.set_parallel(true)
	if _expand_button:
		_expand_tween.tween_property(_expand_button, "rotation", 0.0, EXPAND_DURATION)
		_expand_tween.tween_property(_expand_button, "self_modulate", Color.WHITE, EXPAND_DURATION)


func _contract_content() -> void:
	if _expand_tween and _expand_tween.is_running():
		_expand_tween.kill()
	_expand_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_expand_tween.set_parallel(true)
	if _expand_button:
		_expand_tween.tween_property(_expand_button, "rotation", deg_to_rad(-90.0), EXPAND_DURATION)
		_expand_tween.tween_property(_expand_button, "self_modulate", EXPAND_ICON_COLOR, EXPAND_DURATION)
	_expand_tween.set_parallel(false)
	_expand_tween.tween_callback(func():
		if _output_container:
			_output_container.visible = false
	)
