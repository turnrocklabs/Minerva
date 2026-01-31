class_name AutocoderStreamMessageCard
extends PanelContainer

@onready var _icon_label: Label = %IconLabel
@onready var _content_label: Label = %ContentLabel

var _role: String = "assistant"
var _view_full_button: Button = null
var _full_content: String = ""

func _ready():
	pass

func setup(content: String, role: String = "assistant", full_content: String = ""):
	_role = role
	_full_content = full_content
	
	if _content_label:
		_content_label.text = content
	
	# Add view full content button if full content is available
	if not _full_content.is_empty() and _full_content != content:
		_add_view_full_button()
	
	_update_style()

func _add_view_full_button() -> void:
	"""Add a button to view full content"""
	if _view_full_button:
		return
	
	_view_full_button = Button.new()
	_view_full_button.text = "📄 View Full"
	_view_full_button.custom_minimum_size = Vector2(80, 24)
	_view_full_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN  # Don't expand horizontally
	_view_full_button.pressed.connect(_on_view_full_pressed)
	
	# Add button to the card
	var parent = _content_label.get_parent()
	if parent:
		parent.add_child(_view_full_button)

func _on_view_full_pressed() -> void:
	"""Open full content in a text editor or dialog"""
	if _full_content.is_empty():
		return
	
	# Create a simple text dialog to show full content
	var dialog = AcceptDialog.new()
	dialog.title = "Full LLM Content"
	dialog.size = Vector2(800, 600)
	
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var text_edit = TextEdit.new()
	text_edit.editable = false
	text_edit.text = _full_content
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	scroll.add_child(text_edit)
	dialog.add_child(scroll)
	
	get_tree().root.add_child(dialog)
	dialog.popup_centered()
	
	# Clean up when closed
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())

func update_content(content: String) -> void:
	if _content_label:
		_content_label.text = content

func set_role(role: String) -> void:
	"""Update the card's role and refresh its visual style"""
	_role = role
	_update_style()

func _update_style():
	if not _icon_label:
		return
	
	match _role:
		"assistant":
			_icon_label.text = "🤖"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
		"user":
			_icon_label.text = "👤"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1))
		"error":
			_icon_label.text = "⚠️"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
		"system":
			_icon_label.text = "⚙️"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		"llm":
			_icon_label.text = "💭"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
				# Enable autowrap and scrolling for long LLM content
				_content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		"request":
			_icon_label.text = "🚀"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))  # Green tint for requests
				_content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		"response":
			_icon_label.text = "✅"
			if _content_label:
				_content_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))  # Blue tint for responses
				_content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_:
			_icon_label.text = "💬"
