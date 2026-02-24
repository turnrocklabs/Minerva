class_name AutocoderStreamMessageCard
extends PanelContainer

@onready var _icon_label: Label = %IconLabel
@onready var _preview_label: Label = %PreviewLabel
@onready var _content_label: Label = %ContentLabel
@onready var _expand_control: Control = %ExpandControl
@onready var _expand_button: Button = %ExpandButton
@onready var _full_content_container: VBoxContainer = %FullContentContainer

var _role: String = "assistant"
var _full_content: String = ""
var _preview_text: String = ""
var _expanded: bool = false
var _expand_tween: Tween
var _has_full_content: bool = false
const EXPAND_DURATION: float = 0.3
const EXPAND_ICON_COLOR: Color = Color(0.16, 1.0, 1.0, 1.0)
const PREVIEW_MAX_CHARS: int = 120

func _ready():
	pass

func setup(content: String, role: String = "assistant", full_content: String = ""):
	_role = role
	_full_content = full_content if not full_content.is_empty() else content
	_preview_text = content

	# Determine if this card needs expand/collapse
	_has_full_content = not full_content.is_empty() and full_content != content
	if not _has_full_content and content.length() > PREVIEW_MAX_CHARS:
		_has_full_content = true
		_full_content = content

	# Set preview text (truncated for long content)
	if _preview_label:
		if _has_full_content and _preview_text.length() > PREVIEW_MAX_CHARS:
			_preview_label.text = _preview_text.substr(0, PREVIEW_MAX_CHARS) + "..."
		else:
			_preview_label.text = _preview_text

	# Set full content
	if _content_label:
		_content_label.text = _full_content

	# Show expand control only when there's content to expand
	if _expand_control:
		_expand_control.visible = _has_full_content

	_update_style()

func update_content(content: String) -> void:
	_preview_text = content
	if _preview_label:
		if _has_full_content and content.length() > PREVIEW_MAX_CHARS:
			_preview_label.text = content.substr(0, PREVIEW_MAX_CHARS) + "..."
		else:
			_preview_label.text = content
	if _content_label and not _has_full_content:
		_content_label.text = content

func set_role(role: String) -> void:
	_role = role
	_update_style()

## Called from AutocoderActionStream when full_content is set after creation
func _add_view_full_button() -> void:
	_has_full_content = true
	if _expand_control:
		_expand_control.visible = true


## --- Expand / Collapse ---

func _on_expand_button_pressed() -> void:
	_expanded = not _expanded
	if _expanded:
		_expand_content()
	else:
		_contract_content()


func _expand_content() -> void:
	if not _full_content_container:
		return
	# Update full content label with latest
	if _content_label:
		_content_label.text = _full_content
	_full_content_container.visible = true
	# Hide preview, show full
	if _preview_label:
		_preview_label.visible = false

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
		if _full_content_container:
			_full_content_container.visible = false
		if _preview_label:
			_preview_label.visible = true
	)


func _update_style():
	if not _icon_label:
		return

	match _role:
		"assistant":
			_icon_label.text = "🤖"
			_set_text_color(Color(0.75, 0.75, 0.8))
		"user":
			_icon_label.text = "👤"
			_set_text_color(Color(0.6, 0.8, 1))
		"error":
			_icon_label.text = "⚠️"
			_set_text_color(Color(0.9, 0.5, 0.5))
		"system":
			_icon_label.text = "⚙️"
			_set_text_color(Color(0.6, 0.6, 0.65))
		"llm":
			_icon_label.text = "💭"
			_set_text_color(Color(0.8, 0.8, 0.85))
		"request":
			_icon_label.text = "🚀"
			_set_text_color(Color(0.7, 0.85, 0.7))
		"response":
			_icon_label.text = "✅"
			_set_text_color(Color(0.7, 0.8, 0.9))
		_:
			_icon_label.text = "💬"


func _set_text_color(color: Color) -> void:
	if _preview_label:
		_preview_label.add_theme_color_override("font_color", color)
	if _content_label:
		_content_label.add_theme_color_override("font_color", color)
