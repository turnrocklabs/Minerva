class_name AutocoderCompactSubmit
extends VBoxContainer

signal mode_changed(mode: AutocoderMode)
signal submit_requested(prompt: String, mode: AutocoderMode, model: String, options: Dictionary)
signal artifact_browse_requested
signal session_selected(session_id: String)
signal new_session_requested

enum AutocoderMode {
	PLAN,
	CODER,
	REVIEW
}

@onready var _mode_option_button: OptionButton = %ModeOptionButton

@onready var _prompt_text_edit: TextEdit = %PromptTextEdit
@onready var _model_option_button: OptionButton = %ModelOptionButton

@onready var _auto_review_check_box: CheckBox = %AutoReviewCheckBox
@onready var _require_permission_check_box: CheckBox = %RequirePermissionCheckBox

@onready var _artifact_button: Button = %ArtifactButton
@onready var _artifact_label: Label = %ArtifactLabel

@onready var _submit_button: Button = %SubmitButton

# Session selector
@onready var _session_option_button: OptionButton = %SessionOptionButton

# Review agents container
@onready var _review_agents_container: Control = %ReviewAgentsContainer
@onready var _review_agents_list: VBoxContainer = %ReviewAgentsList

var current_mode: AutocoderMode = AutocoderMode.PLAN:
	set(value):
		if current_mode == value:
			return
		current_mode = value
		_update_mode_ui()
		_update_review_agents_visibility()
		mode_changed.emit(current_mode)

var selected_artifact_uri: String = ""
var selected_session_id: String = ""
var _available_review_agents: Array[AgentDefinition] = []
var _enabled_agent_ids: Array[String] = []

func _ready():
	# Connect mode dropdown
	if _mode_option_button:
		_mode_option_button.item_selected.connect(_on_mode_selected)
	
	# Connect submit button
	if _submit_button:
		_submit_button.pressed.connect(_on_submit_pressed)
	
	# Connect artifact button
	if _artifact_button:
		_artifact_button.pressed.connect(func(): artifact_browse_requested.emit())
	
	# Connect session selector
	if _session_option_button:
		_session_option_button.item_selected.connect(_on_session_selected)
	
	_update_mode_ui()
	_update_review_agents_visibility()
	_populate_models([])
	_populate_sessions([])

func _update_mode_ui():
	# Sync dropdown selection
	if _mode_option_button:
		_mode_option_button.select(current_mode as int)
	
	# Update submit button text based on mode and session
	if _submit_button:
		var is_new_session = selected_session_id.is_empty()
		match current_mode:
			AutocoderMode.PLAN:
				_submit_button.text = "Start Planning" if is_new_session else "Continue Planning"
			AutocoderMode.CODER:
				_submit_button.text = "Generate Code" if is_new_session else "Continue Coding"
			AutocoderMode.REVIEW:
				_submit_button.text = "Run Review"


func _on_mode_selected(index: int):
	match index:
		0:
			current_mode = AutocoderMode.PLAN
		1:
			current_mode = AutocoderMode.CODER
		2:
			current_mode = AutocoderMode.REVIEW


func _update_review_agents_visibility():
	# Show review agents for Coder and Review modes, hide for Plan
	var show_agents = current_mode != AutocoderMode.PLAN
	
	if _review_agents_container:
		_review_agents_container.visible = show_agents
	
	# Also show/hide auto-review checkbox (only relevant in Coder mode)
	if _auto_review_check_box:
		_auto_review_check_box.visible = current_mode == AutocoderMode.CODER


func _on_session_selected(index: int):
	if not _session_option_button:
		return
	
	if index == 0:
		# "New Session" selected
		selected_session_id = ""
		new_session_requested.emit()
	else:
		var meta = _session_option_button.get_item_metadata(index)
		if meta:
			selected_session_id = str(meta)
			session_selected.emit(selected_session_id)
	
	_update_mode_ui()

func _on_submit_pressed():
	var prompt = _prompt_text_edit.text.strip_edges() if _prompt_text_edit else ""
	var model = _get_selected_model_id()
	var options = {
		"auto_review": _auto_review_check_box.button_pressed if _auto_review_check_box else false,
		"require_permission": _require_permission_check_box.button_pressed if _require_permission_check_box else false,
		"artifact_uri": selected_artifact_uri,
		"session_id": selected_session_id,
		"review_agent_ids": _enabled_agent_ids.duplicate()
	}
	submit_requested.emit(prompt, current_mode, model, options)

func _get_selected_model_id() -> String:
	if not _model_option_button:
		return ""
	if _model_option_button.item_count == 0:
		return ""
	var index = _model_option_button.selected
	if index < 0:
		return ""
	var meta = _model_option_button.get_item_metadata(index)
	if meta == null:
		return ""
	return str(meta)

func _populate_models(models: Array[Dictionary]) -> void:
	if not _model_option_button:
		return
	
	var previous_id = _get_selected_model_id()
	
	_model_option_button.clear()
	_model_option_button.add_item("Auto (server default)")
	_model_option_button.set_item_metadata(0, "")
	
	var selected_index = 0
	var index = 1
	for model_data in models:
		if not (model_data is Dictionary):
			continue
		var model_id = str(model_data.get("id", ""))
		if model_id.is_empty():
			continue
		var model_name = str(model_data.get("name", ""))
		var label = model_name if not model_name.is_empty() else model_id
		if not model_name.is_empty() and model_name != model_id:
			label = "%s (%s)" % [model_name, model_id]
		_model_option_button.add_item(label)
		_model_option_button.set_item_metadata(index, model_id)
		if model_id == previous_id:
			selected_index = index
		index += 1
	
	_model_option_button.select(selected_index)
	_model_option_button.disabled = false

func set_models(models: Array[Dictionary]) -> void:
	_populate_models(models)

func set_artifact(uri: String, name: String) -> void:
	selected_artifact_uri = uri
	if _artifact_label:
		_artifact_label.text = name if not name.is_empty() else "No artifact selected"

func clear_artifact() -> void:
	selected_artifact_uri = ""
	if _artifact_label:
		_artifact_label.text = "No artifact selected"

func get_mode_name() -> String:
	match current_mode:
		AutocoderMode.PLAN:
			return "Plan"
		AutocoderMode.CODER:
			return "Coder"
		AutocoderMode.REVIEW:
			return "Review"
		_:
			return "Unknown"


# Session management

func _populate_sessions(sessions: Array[Dictionary]):
	if not _session_option_button:
		return
	
	_session_option_button.clear()
	_session_option_button.add_item("+ New Session")
	_session_option_button.set_item_metadata(0, "")
	
	var index = 1
	for session_data in sessions:
		if not (session_data is Dictionary):
			continue
		var session_id = str(session_data.get("session_id", ""))
		if session_id.is_empty():
			continue
		
		var status = str(session_data.get("status", "unknown"))
		var short_id = session_id.substr(0, 12) + "..." if session_id.length() > 15 else session_id
		var label = "%s (%s)" % [short_id, status]
		
		_session_option_button.add_item(label)
		_session_option_button.set_item_metadata(index, session_id)
		index += 1

func set_sessions(sessions: Array[Dictionary]):
	_populate_sessions(sessions)

func select_session(session_id: String):
	if not _session_option_button:
		return
	
	selected_session_id = session_id
	
	if session_id.is_empty():
		_session_option_button.select(0)
	else:
		for i in range(_session_option_button.item_count):
			if _session_option_button.get_item_metadata(i) == session_id:
				_session_option_button.select(i)
				break
	
	_update_mode_ui()


# Review agents management

func set_review_agents(agents: Array[AgentDefinition]):
	_available_review_agents = agents
	_rebuild_review_agents_ui()

func _rebuild_review_agents_ui():
	if not _review_agents_list:
		return
	
	# Clear existing
	for child in _review_agents_list.get_children():
		child.queue_free()
	
	# Build new checkboxes for each agent
	for agent in _available_review_agents:
		var agent_id = agent.agent_id
		var agent_name = agent.name if not agent.name.is_empty() else agent_id
		
		if agent_id.is_empty():
			continue
		
		var checkbox = CheckBox.new()
		checkbox.text = agent_name
		checkbox.button_pressed = agent_id in _enabled_agent_ids
		checkbox.toggled.connect(_on_agent_checkbox_toggled.bind(agent_id))
		
		# Style the checkbox
		checkbox.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		checkbox.add_theme_font_size_override("font_size", 12)
		
		_review_agents_list.add_child(checkbox)

func _on_agent_checkbox_toggled(toggled: bool, agent_id: String):
	if toggled:
		if agent_id not in _enabled_agent_ids:
			_enabled_agent_ids.append(agent_id)
	else:
		_enabled_agent_ids.erase(agent_id)

func get_enabled_agent_ids() -> Array[String]:
	return _enabled_agent_ids.duplicate()

func set_enabled_agent_ids(agent_ids: Array[String]):
	_enabled_agent_ids = agent_ids.duplicate()
	_rebuild_review_agents_ui()
