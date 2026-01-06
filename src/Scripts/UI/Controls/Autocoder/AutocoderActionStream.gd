class_name AutocoderActionStream
extends Control

signal question_answered(question_id: String, answer: String)

enum ActionType {
	TOOL_CALL,
	MESSAGE,
	QUESTION,
	ERROR
}

const TOOL_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamToolCard.tscn")
const MESSAGE_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamMessageCard.tscn")
const QUESTION_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamQuestionCard.tscn")

@onready var _scroll_container: ScrollContainer = %ScrollContainer
@onready var _actions_list: VBoxContainer = %ActionsList
@onready var _empty_label: Label = %EmptyLabel

var _tool_cards: Dictionary = {}  # action_id -> card
var _question_cards: Dictionary = {}  # question_id -> card
var _auto_scroll: bool = true

func _ready():
	_update_empty_state()
	
	# Load mock data for demonstration
	_load_mock_data()

func _load_mock_data():
	# Add some mock actions to demonstrate the UI
	add_message("Hello! I'll help you build your project. Let me analyze the requirements first.", "assistant")
	
	add_tool_call("analyze_codebase", "Analyzing project structure...", "act_001")
	await get_tree().create_timer(0.1).timeout
	update_tool_call("act_001", "completed", "Found 15 files in project")
	
	add_tool_call("read_file", "Reading main.py...", "act_002")
	await get_tree().create_timer(0.1).timeout
	update_tool_call("act_002", "completed", "File contents loaded (250 lines)")
	
	add_message("I've analyzed your codebase. I have a few questions before we proceed.", "assistant")
	
	add_question("q_001", "What programming language would you prefer for the new feature?", ["Python", "TypeScript", "Go", "Other"])
	
	add_tool_call("write_file", "Creating utils/helpers.py...", "act_003")

func add_tool_call(tool_name: String, description: String, action_id: String = "") -> void:
	if action_id.is_empty():
		action_id = "act_%d" % Time.get_ticks_msec()
	
	var card = TOOL_CARD_SCENE.instantiate()
	if _actions_list:
		_actions_list.add_child(card)
	card.setup(tool_name, description, "running")
	
	if not action_id.is_empty():
		_tool_cards[action_id] = card
	
	_update_empty_state()
	_scroll_to_bottom()

func update_tool_call(action_id: String, status: String, output: String = "") -> void:
	if not _tool_cards.has(action_id):
		return
	
	var card = _tool_cards[action_id]
	if card and is_instance_valid(card):
		card.update_status(status, output)

func add_message(content: String, role: String = "assistant") -> void:
	var card = MESSAGE_CARD_SCENE.instantiate()
	if _actions_list:
		_actions_list.add_child(card)
	card.setup(content, role)
	
	_update_empty_state()
	_scroll_to_bottom()

func add_question(question_id: String, question_text: String, options: Array = []) -> void:
	var card = QUESTION_CARD_SCENE.instantiate()
	if _actions_list:
		_actions_list.add_child(card)
	card.setup(question_id, question_text, options)
	card.answer_submitted.connect(_on_question_answered)
	
	_question_cards[question_id] = card
	
	_update_empty_state()
	_scroll_to_bottom()

func add_error(message: String) -> void:
	add_message("Error: " + message, "error")

func clear() -> void:
	if _actions_list:
		for child in _actions_list.get_children():
			child.queue_free()
	_tool_cards.clear()
	_question_cards.clear()
	_update_empty_state()

func _update_empty_state():
	if _empty_label:
		_empty_label.visible = _actions_list.get_child_count() == 0 if _actions_list else true

func _scroll_to_bottom():
	if not _auto_scroll or not _scroll_container:
		return
	
	# Wait for the next frame to ensure layout is updated
	await get_tree().process_frame
	_scroll_container.scroll_vertical = _scroll_container.get_v_scroll_bar().max_value

func _on_question_answered(question_id: String, answer: String):
	question_answered.emit(question_id, answer)
	
	# Remove the question card
	if _question_cards.has(question_id):
		var card = _question_cards[question_id]
		if card and is_instance_valid(card):
			card.queue_free()
		_question_cards.erase(question_id)
	
	# Add a message showing the answer
	add_message("You answered: " + answer, "user")
