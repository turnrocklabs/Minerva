class_name AutocoderActionStream
extends Control

signal question_answered(question_id: String, answer: String, session_id: String)
signal approval_action(session_id: String, action: String, feedback: String)
signal approval_extract(session_id: String)

enum ActionType {
	TOOL_CALL,
	MESSAGE,
	QUESTION,
	ERROR
}

const TOOL_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamToolCard.tscn")
const MESSAGE_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamMessageCard.tscn")
const QUESTION_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamQuestionCard.tscn")
const APPROVAL_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderStreamApprovalCard.tscn")

@onready var _scroll_container: ScrollContainer = %ScrollContainer
@onready var _actions_list: VBoxContainer = %ActionsList
@onready var _empty_label: Label = %EmptyLabel

var _tool_cards: Dictionary = {}  # action_id -> card
var _question_cards: Dictionary = {}  # question_id -> card
var _approval_cards: Dictionary = {}  # session_id -> card
var _auto_scroll: bool = true
var _llm_card = null  # AutocoderStreamMessageCard - type removed to avoid load order issues
var _llm_buffer: String = ""
# Removed LLM_MAX_CHARS - show ALL content, no truncation

func _ready():
	_update_empty_state()

# Removed _load_mock_data() - dummy data no longer needed
# Action stream will be populated with real planning/coding activity

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

func add_question(question_id: String, question_text: String, options: Array = [], session_id: String = "") -> void:
	# If question already exists and has been submitted, don't add it again
	if _question_cards.has(question_id):
		var existing_card = _question_cards[question_id]
		if existing_card and is_instance_valid(existing_card):
			if existing_card.has_meta("submitted"):
				print("[ActionStream] Question %s already submitted, ignoring duplicate" % question_id)
				return
			# Update existing card if it hasn't been submitted
			existing_card.setup(question_id, question_text, options, session_id)
			_scroll_to_bottom()
			return
	
	# Create new question card
	var card = QUESTION_CARD_SCENE.instantiate()
	if _actions_list:
		_actions_list.add_child(card)
	card.setup(question_id, question_text, options, session_id)
	card.answer_submitted.connect(_on_question_answered)
	
	_question_cards[question_id] = card
	
	_update_empty_state()
	_scroll_to_bottom()

func add_error(message: String) -> void:
	add_message("Error: " + message, "error")


func add_approval_card(session_id: String, archive_uri: String, patch_uri: String, review_summary: String, file_count: int, review_results: Array = []) -> void:
	# If card already exists and has been acted on, remove old and create fresh
	if _approval_cards.has(session_id):
		var existing = _approval_cards[session_id]
		if existing and is_instance_valid(existing):
			if existing.has_meta("acted"):
				existing.queue_free()
				_approval_cards.erase(session_id)
			else:
				# Update existing card that hasn't been acted on
				existing.setup(session_id, archive_uri, patch_uri, review_summary, file_count, review_results)
				_scroll_to_bottom()
				return

	var card = APPROVAL_CARD_SCENE.instantiate()
	if _actions_list:
		_actions_list.add_child(card)
	card.setup(session_id, archive_uri, patch_uri, review_summary, file_count, review_results)
	card.approved.connect(_on_approval_approved)
	card.rejected.connect(_on_approval_rejected)
	card.extract_requested.connect(_on_extract_requested)

	_approval_cards[session_id] = card

	_update_empty_state()
	_scroll_to_bottom()


func _on_approval_approved(session_id: String) -> void:
	var card = _approval_cards.get(session_id)
	if card and is_instance_valid(card):
		card.set_state("approved")
	approval_action.emit(session_id, "approve", "")


func _on_approval_rejected(session_id: String, feedback: String) -> void:
	var card = _approval_cards.get(session_id)
	if card and is_instance_valid(card):
		card.set_state("rejected")
	approval_action.emit(session_id, "reject", feedback)


func _on_extract_requested(session_id: String) -> void:
	approval_extract.emit(session_id)

func add_llm_progress(content: String) -> void:
	"""Add or update LLM streaming progress (shows model thinking) - shows ALL content, no truncation"""
	if content.is_empty():
		return
	if _llm_card and is_instance_valid(_llm_card):
		# Update existing card with new content
		# If new content is a continuation (starts with buffer), replace buffer
		# Otherwise append as new line
		if content.begins_with(_llm_buffer):
			_llm_buffer = content
		else:
			_llm_buffer += "\n" + content
		# NO TRUNCATION - show all content
		_llm_card.update_content("💭 " + _llm_buffer)
	else:
		# Create new LLM progress card
		_llm_buffer = content
		var card = MESSAGE_CARD_SCENE.instantiate()
		if _actions_list:
			_actions_list.add_child(card)
		card.setup("💭 " + content, "llm")
		
		# Add pulse animation to show it's "thinking"
		var tween = create_tween()
		tween.set_loops()
		tween.tween_property(card, "modulate:a", 0.6, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(card, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		
		# Store tween and mark as LLM card so it can be cleaned up when complete
		card.set_meta("llm_tween", tween)
		card.set_meta("is_llm_progress", true)
		_llm_card = card
	
	_update_empty_state()
	_scroll_to_bottom()

func add_llm_delta(delta: String) -> void:
	"""Add LLM content delta (streaming chunk) - accumulates into existing card"""
	if delta.is_empty():
		return
	# Accumulate delta into buffer
	_llm_buffer += delta
	# Update or create card
	if _llm_card and is_instance_valid(_llm_card):
		_llm_card.update_content("💭 " + _llm_buffer)
	else:
		# Create new LLM progress card
		var card = MESSAGE_CARD_SCENE.instantiate()
		if _actions_list:
			_actions_list.add_child(card)
		card.setup("💭 " + _llm_buffer, "llm")
		
		# Add pulse animation
		var tween = create_tween()
		tween.set_loops()
		tween.tween_property(card, "modulate:a", 0.6, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(card, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		
		card.set_meta("llm_tween", tween)
		card.set_meta("is_llm_progress", true)
		_llm_card = card
	
	_update_empty_state()
	_scroll_to_bottom()

func add_llm_progress_with_full_content(preview_content: String, full_content: String) -> void:
	"""Add LLM progress with preview and option to view full content"""
	if preview_content.is_empty():
		return
	if _llm_card and is_instance_valid(_llm_card):
		# Update existing card
		if preview_content.begins_with(_llm_buffer):
			_llm_buffer = preview_content
		else:
			_llm_buffer += "\n" + preview_content
		_llm_card.update_content("💭 " + _llm_buffer)
		# Update full content if available
		if not full_content.is_empty():
			_llm_card._full_content = full_content
			if not _llm_card._has_full_content:
				_llm_card._add_view_full_button()
	else:
		# Create new card with full content
		_llm_buffer = preview_content
		var card = MESSAGE_CARD_SCENE.instantiate()
		if _actions_list:
			_actions_list.add_child(card)
		card.setup("💭 " + preview_content, "llm", full_content)
		
		# Add pulse animation
		var tween = create_tween()
		tween.set_loops()
		tween.tween_property(card, "modulate:a", 0.6, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(card, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		
		card.set_meta("llm_tween", tween)
		card.set_meta("is_llm_progress", true)
		_llm_card = card
	
	_update_empty_state()
	_scroll_to_bottom()

func stop_llm_progress() -> void:
	"""Stop LLM progress animations and finalize cards (keeps them visible)"""
	if not _actions_list:
		return
	
	for child in _actions_list.get_children():
		if child.has_meta("is_llm_progress"):
			# Stop the tween animation
			if child.has_meta("llm_tween"):
				var tween = child.get_meta("llm_tween")
				if tween:
					tween.kill()
				child.remove_meta("llm_tween")
			# Restore full opacity (tween may have left it dimmed)
			child.modulate.a = 1.0
			# Remove the progress marker so the card is treated as regular content
			child.remove_meta("is_llm_progress")
	
	# Clear the reference so new LLM traffic creates a fresh card
	_llm_card = null
	_llm_buffer = ""

func clear() -> void:
	if _actions_list:
		for child in _actions_list.get_children():
			child.queue_free()
	_tool_cards.clear()
	_question_cards.clear()
	_approval_cards.clear()
	_update_empty_state()

func _update_empty_state():
	if _empty_label:
		_empty_label.visible = _actions_list.get_child_count() == 0 if _actions_list else true

func _scroll_to_bottom():
	if not _auto_scroll or not _scroll_container:
		return
	
	# Wait for the next frame to ensure layout is updated
	await get_tree().process_frame
	_scroll_container.scroll_vertical = int(_scroll_container.get_v_scroll_bar().max_value)

func _on_question_answered(question_id: String, answer: String, session_id: String):
	# Remove the question card IMMEDIATELY before emitting signal
	if _question_cards.has(question_id):
		var card = _question_cards[question_id]
		if card and is_instance_valid(card):
			# Mark as submitted to prevent re-adding
			card.set_meta("submitted", true)
			# Remove from UI immediately
			card.queue_free()
		_question_cards.erase(question_id)
	
	# Add a message showing the answer BEFORE emitting signal
	if not answer.is_empty():
		add_message("You answered: " + answer, "user")
	else:
		add_message("Question skipped", "user")
	
	# Emit signal to parent (after removing from UI)
	question_answered.emit(question_id, answer, session_id)
