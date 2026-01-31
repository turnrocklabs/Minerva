class_name AutocoderStreamQuestionCard
extends PanelContainer

signal answer_submitted(question_id: String, answer: String, session_id: String)

@onready var _question_label: Label = %QuestionLabel
@onready var _options_container: VBoxContainer = %OptionsContainer
@onready var _text_input: LineEdit = %TextInput
@onready var _submit_button: Button = %SubmitButton

var _question_id: String = ""
var _options: Array = []
var _session_id: String = ""

func _ready():
	if _submit_button:
		_submit_button.pressed.connect(_on_submit_pressed)
	if _text_input:
		_text_input.text_submitted.connect(func(_t): _on_submit_pressed())

func setup(question_id: String, question_text: String, options: Array = [], session_id: String = ""):
	_question_id = question_id
	_options = options
	_session_id = session_id
	
	if _question_label:
		_question_label.text = question_text
	
	_build_options()

func _build_options():
	if not _options_container:
		return
	
	# Clear existing options
	for child in _options_container.get_children():
		if child != _text_input and child != _submit_button:
			child.queue_free()
	
	if _options.is_empty():
		# Show text input for free-form answer
		if _text_input:
			_text_input.visible = true
		if _submit_button:
			_submit_button.visible = true
	else:
		# Show option buttons
		if _text_input:
			_text_input.visible = false
		if _submit_button:
			_submit_button.visible = false
		
		for option in _options:
			var btn = Button.new()
			btn.text = str(option)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.add_theme_font_size_override("font_size", 12)
			btn.pressed.connect(func(): _submit_answer(str(option)))
			_options_container.add_child(btn)
			_options_container.move_child(btn, 0)  # Add before input/submit

func _on_submit_pressed():
	if _text_input and not _text_input.text.strip_edges().is_empty():
		_submit_answer(_text_input.text.strip_edges())

func _submit_answer(answer: String):
	if has_meta("submitted"):
		return
	set_meta("submitted", true)
	if _submit_button:
		_submit_button.disabled = true
	if _text_input:
		_text_input.editable = false
	answer_submitted.emit(_question_id, answer, _session_id)
