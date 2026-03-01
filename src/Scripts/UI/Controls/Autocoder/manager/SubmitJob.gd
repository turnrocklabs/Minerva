class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
@onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

@onready var _clear_resources_button: Button = %ClearInputResourcesButton
@onready var _attach_folder_button: Button = %AttachFolderButton
@onready var _set_source_folder_button: Button = %SetSourceFolderButton
@onready var _download_latest_button: Button = %DownloadLatestButton
@onready var _extract_latest_button: Button = %ExtractLatestButton
@onready var _download_patch_button: Button = %DownloadPatchButton

@onready var _selected_artifact_name_label: Label = %SelectedArtifactNameLabel
@onready var _selected_artifact_uri_label: Label = %SelectedArtifactURILabel

@onready var _prompt_text_edit: TextEdit = %PromptTextEdit

@onready var _model_option_button: OptionButton = %ModelOptionButton
@onready var _clear_text_button: Button = %ClearTextButton
@onready var _microphone_button: Button = %MicrophoneButton
@onready var _stop_button: Button = %StopButton

@onready var _resource_popup: PersistentWindow = %ResourcePopup
@onready var _resource_button: Button = %ResourceButton
@onready var _phase_model_settings_button: Button = %PhaseModelSettingsButton
@onready var _phase_model_popup: PersistentWindow = %PhaseModelPopup
@onready var _review_agents_button: Button = %ReviewAgentsButton
@onready var _review_agents_popup: PersistentWindow = %ReviewAgentsPopup
@onready var _plan_model_option: OptionButton = %PlanModelOption
@onready var _generate_model_option: OptionButton = %GenerateModelOption
@onready var _review_model_option: OptionButton = %ReviewModelOption

@onready var _auto_generate_check_box: CheckBox = %AutoGenerateCheckBox

@onready var _require_permission_check_box: CheckBox = %RequirePermissionCheckBox
@onready var _browse_models_button: Button = %BrowseModelsButton
@onready var _clear_user_models_button: Button = %ClearUserModelsButton
@onready var _model_management_status_label: Label = %ModelManagementStatusLabel
@onready var _review_agents_refresh_button: Button = %ReviewAgentsRefreshButton
@onready var _agent_checkbox_list: VBoxContainer = %AgentCheckboxList
@onready var _review_agents_empty_label: Label = %ReviewAgentsEmptyLabel
@onready var _review_agents_clear_button: Button = %ReviewAgentsClearButton
@onready var _select_all_button: Button = %SelectAllButton
@onready var _preset_option_button: OptionButton = %PresetOptionButton
@onready var _save_preset_button: Button = %SavePresetButton

@onready var _session_option_button: OptionButton = %SessionOptionButton
@onready var _new_session_check_box: CheckBox = %NewSessionCheckBox
@onready var _continue_session_check_box: CheckBox = %ContinueSessionCheckBox

@onready var _submit_job_button: Button = %SubmitJobButton
@onready var _select_package_button: Button = %SelectPackageButton

## Keep AutocoderMode as static const for MCP backward compatibility
enum AutocoderMode {
	PLAN = 0,
	CODER = 1,
	REVIEW = 2
}

enum JobState {
	IDLE,
	PLANNING,
	AWAITING_QUESTIONS,
	GENERATING,
	AWAITING_USER,
	ERROR
}

var _job_state: JobState = JobState.IDLE
var _auto_promote_session_id: String = ""

@onready var _session_history_container: Container = %SessionHistoryContainer

@onready var _action_stream = %ActionStream  # AutocoderActionStream - type removed for load order

var _session_history_browser  # SessionHistoryBrowser - type removed for load order

## Track sessions currently processing to prevent concurrent requests
var _processing_sessions: Dictionary = {}  # session_id -> bool

var selected_artifact: Artifact = null:
	set(value):
		if selected_artifact == value:
			return
		selected_artifact = value

		if _clear_resources_button:
			_clear_resources_button.visible = selected_artifact != null

		if selected_artifact:
			if _selected_artifact_name_label:
				_selected_artifact_name_label.text = selected_artifact.filename
			if _selected_artifact_uri_label:
				_selected_artifact_uri_label.text = selected_artifact.artifact_uri
		else:
			if _selected_artifact_name_label:
				_selected_artifact_name_label.text = "No files attached"
		_update_resource_labels()

## The local source directory path associated with the selected artifact (if created from local files)
var _pending_source_dir: String = ""
var _latest_archive_by_session: Dictionary = {}  # session_id -> archive_uri
var _latest_patch_by_session: Dictionary = {}  # session_id -> patch_uri
var _source_dir_by_session: Dictionary = {}  # session_id -> source dir
const SOURCE_DIR_SECTION = "AutocoderSourceDirs"
var _submitted_questions: Dictionary = {}  # question_id -> true

# User-selected custom models from OpenRouter browse
var _user_selected_models: Array = []  # [{id, name}, ...]

# Planning action buttons (Add Context / Inject Notes)
var _planning_actions_row: HBoxContainer = null
var _add_context_button: Button = null
var _inject_notes_button: Button = null
var _context_popup: Window = null
var _context_text_edit: TextEdit = null


func _ready() -> void:
	SingletonObject.load_config_file()
	# Create and setup session history browser
	var SessionHistoryBrowserClass = load("res://Scripts/UI/Controls/Autocoder/SessionHistoryBrowser.gd")
	_session_history_browser = SessionHistoryBrowserClass.new()
	_session_history_browser.session_view_requested.connect(_on_session_view_requested)
	_session_history_browser.session_resume_requested.connect(_on_session_resume_requested)

	if _session_history_container:
		_session_history_container.add_child(_session_history_browser)

	_populate_models([])
	_populate_review_agents([])
	
	# Connect action stream question answers and approval actions
	if _action_stream:
		_action_stream.question_answered.connect(_on_question_answered)
		_action_stream.approval_action.connect(_on_approval_action)
		_action_stream.approval_extract.connect(_on_approval_extract)

	# Initialize job state
	_set_job_state(JobState.IDLE)

	# Create planning action buttons (Add Context / Inject Notes)
	_create_planning_actions_row()

	# Note: Session loading and model loading are now handled by AutocoderManager
	# calling _refresh_session_history() and _refresh_models() after the autocoder_adapter is ready.
	# No need to connect to Core directly or attempt early loading.
	
	# Review agents can still be loaded on demand
	_refresh_review_agents.call_deferred()

	if _phase_model_settings_button:
		_phase_model_settings_button.pressed.connect(_on_phase_model_settings_pressed)
	if _browse_models_button:
		_browse_models_button.pressed.connect(_on_browse_models_pressed)
	if _clear_user_models_button:
		_clear_user_models_button.pressed.connect(_on_clear_user_models_pressed)
	if _review_agents_button:
		_review_agents_button.pressed.connect(_on_review_agents_button_pressed)
	if _resource_button and _resource_popup:
		_resource_button.pressed.connect(func(): _resource_popup.popup_centered())

	_clear_text_button.pressed.connect(_on_clear_text_button_pressed)
	_microphone_button.pressed.connect(_on_microphone_button_pressed)
	_stop_button.pressed.connect(_on_stop_button_pressed)
	_review_agents_refresh_button.pressed.connect(_on_review_agents_refresh_pressed)
	_review_agents_clear_button.pressed.connect(_on_review_agents_clear_pressed)
	_select_all_button.pressed.connect(_on_select_all_pressed)
	_preset_option_button.item_selected.connect(_on_preset_selected)
	_save_preset_button.pressed.connect(_on_save_preset_pressed)

	# Load presets after adapter is ready
	_refresh_presets.call_deferred()

	if _attach_folder_button and not _attach_folder_button.pressed.is_connected(_on_attach_folder_button_pressed):
		_attach_folder_button.pressed.connect(_on_attach_folder_button_pressed)
	if _set_source_folder_button and not _set_source_folder_button.pressed.is_connected(_on_set_source_folder_pressed):
		_set_source_folder_button.pressed.connect(_on_set_source_folder_pressed)
	if _download_latest_button and not _download_latest_button.pressed.is_connected(_on_download_latest_pressed):
		_download_latest_button.pressed.connect(_on_download_latest_pressed)
		_download_latest_button.disabled = true
	if _extract_latest_button and not _extract_latest_button.pressed.is_connected(_on_extract_latest_pressed):
		_extract_latest_button.pressed.connect(_on_extract_latest_pressed)
		_extract_latest_button.disabled = true
	if _download_patch_button and not _download_patch_button.pressed.is_connected(_on_download_patch_pressed):
		_download_patch_button.pressed.connect(_on_download_patch_pressed)
		_download_patch_button.disabled = true
	
	# Allow refreshing models by opening the dropdown when it only has "Auto (server default)"
	_model_option_button.item_selected.connect(func(_index):
		# If user clicks on dropdown and only sees "Auto", try refreshing
		if _model_option_button.item_count == 1:
			print("[SubmitJob] Only default model available, attempting refresh...")
			_refresh_models()
	)

	# Connections moved from .tscn to code for reparenting resilience
	if _select_package_button and not _select_package_button.pressed.is_connected(_on_select_package_button_pressed):
		_select_package_button.pressed.connect(_on_select_package_button_pressed)
	if _clear_resources_button and not _clear_resources_button.pressed.is_connected(_on_clear_input_resources_button_pressed):
		_clear_resources_button.pressed.connect(_on_clear_input_resources_button_pressed)
	if _submit_job_button and not _submit_job_button.pressed.is_connected(_on_submit_job_button_pressed):
		_submit_job_button.pressed.connect(_on_submit_job_button_pressed)
	if _continue_session_check_box and not _continue_session_check_box.toggled.is_connected(_on_continue_session_check_box_toggled):
		_continue_session_check_box.toggled.connect(_on_continue_session_check_box_toggled)

	if _new_session_check_box and not _new_session_check_box.toggled.is_connected(_on_new_session_toggled):
		_new_session_check_box.toggled.connect(_on_new_session_toggled)
	if _session_option_button and not _session_option_button.item_selected.is_connected(_on_session_option_selected):
		_session_option_button.item_selected.connect(_on_session_option_selected)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and event.ctrl_pressed:
			if _submit_job_button and not _submit_job_button.disabled:
				get_viewport().set_input_as_handled()
				_on_submit_job_button_pressed()




## Programmatic entry point for MCP-initiated sessions.
## Syncs the UI to track a session started externally, so it behaves
## identically to one started from the Submit button.
func setup_mcp_session(session_id: String, prompt: String, mode: AutocoderMode, input_archive_uri: String = "") -> void:
	if session_id.is_empty():
		return

	# Clear action stream and show prompt
	if _action_stream:
		_action_stream.clear()
	if _action_stream and not prompt.is_empty():
		_action_stream.add_message("📝 Prompt:\n\n" + prompt, "user")

	# Map AutocoderMode to JobState for the unified UI
	match mode:
		AutocoderMode.PLAN:
			_set_job_state(JobState.PLANNING)
		AutocoderMode.CODER:
			_set_job_state(JobState.GENERATING)
		AutocoderMode.REVIEW:
			_set_job_state(JobState.GENERATING)

	# Fill prompt field
	if _prompt_text_edit:
		_prompt_text_edit.text = prompt

	# Set input archive if provided
	if not input_archive_uri.is_empty():
		var ArtifactClass = load("res://Scripts/Services/ArtifactRegistry/Artifact.gd")
		if ArtifactClass:
			var artifact = ArtifactClass.new()
			artifact.artifact_uri = input_archive_uri
			artifact.filename = input_archive_uri.get_file()
			selected_artifact = artifact

	# Store session for auto-promote tracking
	_auto_promote_session_id = session_id

	# Ensure session appears in dropdown and is selected
	_ensure_session_option(session_id, "processing")
	_select_session_in_dropdown(session_id)

	# Switch to "Continue Session" mode so the dropdown is active
	if _continue_session_check_box:
		_continue_session_check_box.button_pressed = true
		_session_option_button.disabled = false

	# Start full monitoring (kanban board + all topic subscriptions)
	var user_id = Core.client.client_id
	if SingletonObject.autocoder_manager:
		SingletonObject.autocoder_manager.monitor_session(user_id, session_id)

	print("[SubmitJob] MCP session synced to UI: %s (mode=%d)" % [session_id, mode])


func _refresh_session_history():
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		print("[SubmitJob] Cannot refresh session history - autocoder not available")
		return

	_session_history_browser.show_loading()
	print("[SubmitJob] Loading sessions...")
	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()
	print("[SubmitJob] Loaded %d sessions" % sessions.size())
	_session_history_browser.set_sessions(sessions)
	_populate_session_options(sessions)


func _ensure_session_option(session_id: String, status: String = "unknown") -> void:
	if session_id.is_empty() or not _session_option_button:
		return
	for i in range(_session_option_button.item_count):
		var meta = _session_option_button.get_item_metadata(i)
		if str(meta) == session_id:
			return
	var label = "%s %s" % [_status_emoji(status), session_id]
	_session_option_button.add_item(label, _session_option_button.item_count)
	_session_option_button.set_item_metadata(_session_option_button.item_count - 1, session_id)


func _refresh_models() -> void:
	"""Refresh the model dropdown - called by AutocoderManager when adapter is ready"""
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		print("[SubmitJob] Cannot refresh models - autocoder manager or adapter not available")
		_populate_models([])
		return

	print("[SubmitJob] Starting model refresh...")
	_model_option_button.disabled = true
	_model_option_button.clear()
	_model_option_button.add_item("Loading models...")

	var models = await SingletonObject.autocoder_manager.autocoder_adapter.list_generation_models()
	print("[SubmitJob] Received %d models from adapter" % models.size())
	_populate_models(models)
	_populate_phase_model_dropdowns()

	# Update user model count status
	_update_user_model_status()


func _refresh_review_agents() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		_populate_review_agents([])
		return

	_review_agents_refresh_button.disabled = true
	# Clear existing checkboxes
	for child in _agent_checkbox_list.get_children():
		child.queue_free()

	var loading_label = Label.new()
	loading_label.text = "Loading review agents..."
	loading_label.add_theme_font_size_override("font_size", 17)
	loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 1))
	_agent_checkbox_list.add_child(loading_label)

	var agents = await SingletonObject.autocoder_manager.autocoder_adapter.list_review_agents()
	_populate_review_agents(agents)
	_review_agents_refresh_button.disabled = false


func _populate_models(models: Array[Dictionary]) -> void:
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

	if models.size() == 1:
		var only_id = str(models[0].get("id", ""))
		if not only_id.is_empty():
			_model_option_button.set_item_text(0, "Forced model: %s" % only_id)
		selected_index = 1 if _model_option_button.item_count > 1 else 0
		_model_option_button.disabled = true
	else:
		_model_option_button.disabled = false

	_model_option_button.select(selected_index)
	_model_option_button.disabled = false


func _on_phase_model_settings_pressed() -> void:
	if _phase_model_popup:
		_phase_model_popup.popup_centered()


func _on_review_agents_button_pressed() -> void:
	if _review_agents_popup:
		_review_agents_popup.popup_centered()


func _populate_phase_model_dropdowns() -> void:
	"""Populate phase model dropdowns mirroring the main model dropdown, with '(Use Default)' as first item"""
	for option_button in [_plan_model_option, _generate_model_option, _review_model_option]:
		if not option_button:
			continue
		var previous_id = ""
		if option_button.item_count > 0 and option_button.selected >= 0:
			var meta = option_button.get_item_metadata(option_button.selected)
			if meta != null:
				previous_id = str(meta)

		option_button.clear()
		option_button.add_item("(Use Default)")
		option_button.set_item_metadata(0, "")

		# Copy items from main model dropdown (skip the "Auto (server default)" entry)
		var selected_index = 0
		for i in range(1, _model_option_button.item_count):
			var label = _model_option_button.get_item_text(i)
			var model_id = str(_model_option_button.get_item_metadata(i))
			var index = option_button.item_count
			option_button.add_item(label)
			option_button.set_item_metadata(index, model_id)
			if model_id == previous_id and not previous_id.is_empty():
				selected_index = index

		option_button.select(selected_index)


func _get_phase_models() -> Dictionary:
	"""Returns {planning: String, generation: String, review: String} where empty string means 'use default'"""
	var result = {"planning": "", "generation": "", "review": ""}

	if _plan_model_option and _plan_model_option.selected >= 0:
		var meta = _plan_model_option.get_item_metadata(_plan_model_option.selected)
		if meta != null:
			result["planning"] = str(meta)

	if _generate_model_option and _generate_model_option.selected >= 0:
		var meta = _generate_model_option.get_item_metadata(_generate_model_option.selected)
		if meta != null:
			result["generation"] = str(meta)

	if _review_model_option and _review_model_option.selected >= 0:
		var meta = _review_model_option.get_item_metadata(_review_model_option.selected)
		if meta != null:
			result["review"] = str(meta)

	return result


func _restore_phase_models_from_session(session_info: Dictionary) -> void:
	"""Restore per-phase model dropdown selections from session metadata"""
	var planning_model = str(session_info.get("planning_model", ""))
	var generation_model = str(session_info.get("generation_model", ""))
	var review_model = str(session_info.get("review_model", ""))

	_select_phase_model_by_id(_plan_model_option, planning_model)
	_select_phase_model_by_id(_generate_model_option, generation_model)
	_select_phase_model_by_id(_review_model_option, review_model)


func _select_phase_model_by_id(option_button: OptionButton, model_id: String) -> void:
	"""Select a model in a phase dropdown by its metadata ID"""
	if not option_button or model_id.is_empty():
		return
	for i in range(option_button.item_count):
		var meta = option_button.get_item_metadata(i)
		if meta != null and str(meta) == model_id:
			option_button.select(i)
			return


func _populate_review_agents(agents: Array[Dictionary]) -> void:
	# Clear existing checkboxes
	for child in _agent_checkbox_list.get_children():
		child.queue_free()
	_review_agents_empty_label.visible = false

	if agents.is_empty():
		_review_agents_empty_label.visible = true
		return

	var sorted_agents = agents.duplicate()
	sorted_agents.sort_custom(
		func(a, b):
			var order_a = int(a.get("order", 0))
			var order_b = int(b.get("order", 0))
			if order_a == order_b:
				return str(a.get("name", "")) < str(b.get("name", ""))
			return order_a < order_b
	)

	for agent in sorted_agents:
		if not (agent is Dictionary):
			continue
		var agent_id = str(agent.get("agent_id", ""))
		if agent_id.is_empty():
			continue
		var name_ = str(agent.get("name", "Unnamed Agent"))
		var model = str(agent.get("model", ""))
		var tools_enabled = bool(agent.get("tools_enabled", false))
		var tools_tag = " \U0001F6E0" if tools_enabled else ""
		var label = "%s%s" % [name_, tools_tag]
		if not model.is_empty():
			label = "%s (%s)" % [label, model]

		var cb = CheckBox.new()
		cb.text = label
		cb.add_theme_font_size_override("font_size", 17)
		cb.set_meta("agent_id", agent_id)
		_agent_checkbox_list.add_child(cb)


func _set_job_state(new_state: JobState) -> void:
	_job_state = new_state
	if not _submit_job_button:
		return

	var is_continue = _continue_session_check_box.button_pressed

	match _job_state:
		JobState.IDLE:
			_submit_job_button.tooltip_text = "Continue Session" if is_continue else "Start Job"
			_submit_job_button.disabled = false
		JobState.PLANNING:
			_submit_job_button.tooltip_text = "Planning..."
			_submit_job_button.disabled = true
		JobState.AWAITING_QUESTIONS:
			_submit_job_button.tooltip_text = "Awaiting Answers..."
			_submit_job_button.disabled = true
		JobState.GENERATING:
			_submit_job_button.tooltip_text = "Generating..."
			_submit_job_button.disabled = true
		JobState.AWAITING_USER:
			_submit_job_button.tooltip_text = "Awaiting Approval"
			_submit_job_button.disabled = true
		JobState.ERROR:
			_submit_job_button.tooltip_text = "Retry"
			_submit_job_button.disabled = false

	# Show/hide planning action buttons
	if _planning_actions_row:
		_planning_actions_row.visible = (
			_job_state == JobState.PLANNING or _job_state == JobState.AWAITING_QUESTIONS
		)


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


func _get_selected_review_agent_ids() -> Array[String]:
	var ids: Array[String] = []
	for child in _agent_checkbox_list.get_children():
		if child is CheckBox and child.button_pressed:
			var agent_id = str(child.get_meta("agent_id", ""))
			if not agent_id.is_empty():
				ids.append(agent_id)
	return ids


func _populate_session_options(sessions: Array[Dictionary]) -> void:
	"""Populate session dropdown with all sessions (most recent first)"""
	print("[SubmitJob] _populate_session_options called with %d sessions" % sessions.size())
	_session_option_button.clear()
	_session_option_button.add_item("Select a session")
	_session_option_button.set_item_metadata(0, "")

	# Sort sessions by created_at (newest first)
	var sorted_sessions = sessions.duplicate()
	sorted_sessions.sort_custom(func(a, b): return a.get("created_at", "") > b.get("created_at", ""))

	var index = 1
	for session in sorted_sessions:
		if not (session is Dictionary):
			print("[SubmitJob] Skipping non-dictionary session: %s" % str(session))
			continue
		var session_id = str(session.get("session_id", ""))
		if session_id.is_empty():
			print("[SubmitJob] Skipping session with empty ID: %s" % str(session))
			continue
		
		# Display all sessions with UUID and status
		var status = str(session.get("status", "unknown")).to_lower()
		var label = "%s %s" % [_status_emoji(status), session_id]
		
		print("[SubmitJob] Adding session to dropdown: %s" % label)
		_session_option_button.add_item(label)
		_session_option_button.set_item_metadata(index, session_id)
		index += 1

	print("[SubmitJob] Populated %d session(s) in dropdown (total items: %d)" % [index - 1, _session_option_button.item_count])
	_session_option_button.select(0)
	_session_option_button.disabled = not _continue_session_check_box.button_pressed or index == 1


func _get_selected_session_id() -> String:
	if _session_option_button.item_count == 0:
		return ""
	var index = _session_option_button.selected
	if index < 0:
		return ""
	var meta = _session_option_button.get_item_metadata(index)
	if meta == null:
		return ""
	return str(meta)


func _get_session_status(session_id: String) -> String:
	"""Get the current status of a session"""
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return "unknown"
	
	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()
	for session in sessions:
		if session is Dictionary and str(session.get("session_id", "")) == session_id:
			return str(session.get("status", "unknown")).to_lower()
	
	return "unknown"


func _select_session_in_dropdown(session_id: String) -> void:
	"""Select a session in the dropdown without reloading history or re-monitoring.
	Used when we've just started a session and don't want to reload."""
	if session_id.is_empty():
		return
	
	# Find the session in the dropdown
	var found_index = -1
	for i in range(_session_option_button.item_count):
		var meta = _session_option_button.get_item_metadata(i)
		if str(meta) == session_id:
			found_index = i
			break
	
	if found_index >= 0:
		# Select this session
		_session_option_button.select(found_index)
		
		# Check the "Continue Session" checkbox
		if _continue_session_check_box:
			_continue_session_check_box.button_pressed = true
			_session_option_button.disabled = false
		
		print("[SubmitJob] Selected session in dropdown: %s" % session_id)
		_restore_source_dir_for_session(session_id)
		_update_download_latest_button()
	else:
		push_warning("[SubmitJob] Could not find session %s in dropdown" % session_id)


func _auto_select_session(session_id: String) -> void:
	"""Auto-select a session in the dropdown and enable continue mode.
	This reloads session history - use for resuming existing sessions, not for newly started ones."""
	if session_id.is_empty():
		return
	
	# Ensure sessions are refreshed first
	await _refresh_session_history()
	
	# Ensure the session exists in the dropdown (add it if not present)
	_ensure_session_option(session_id, "active")
	
	# Find the session in the dropdown
	var found_index = -1
	for i in range(_session_option_button.item_count):
		var meta = _session_option_button.get_item_metadata(i)
		if str(meta) == session_id:
			found_index = i
			break
	
	if found_index >= 0:
		# Select this session
		_session_option_button.select(found_index)
		
		# Check the "Continue Session" checkbox
		if _continue_session_check_box:
			_continue_session_check_box.button_pressed = true
			_session_option_button.disabled = false
		
		print("[SubmitJob] Auto-selected session: %s" % session_id)
		
		# Open kanban + subscribe to notifications for this session
		var user_id = Core.client.client_id
		if SingletonObject.autocoder_manager:
			SingletonObject.autocoder_manager.monitor_session(user_id, session_id)
		_restore_source_dir_for_session(session_id)
		
		# Load historical session data into action stream
		await _load_session_history_to_action_stream(session_id)
		
		# Show toast to inform user
		SingletonObject.create_toast_notification(
			"Session selected - ready to continue",
			ToastNotification.Type.INFO
		)
		_update_download_latest_button()
	else:
		push_warning("[SubmitJob] Could not find session %s in dropdown after refresh" % session_id)


func _load_session_history_to_action_stream(session_id: String) -> void:
	"""Load historical session data (prompt, questions) into the action stream"""
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return
	
	print("[SubmitJob] Loading session history for: %s" % session_id)
	
	var session_info = await SingletonObject.autocoder_manager.autocoder_adapter.get_session_info(session_id)
	if session_info.is_empty():
		print("[SubmitJob] No session history available for: %s" % session_id)
		return
	
	print("[SubmitJob] session_info keys: %s" % str(session_info.keys()))
	print("[SubmitJob] session_info.plan type: %s" % typeof(session_info.get("plan", {})))

	# Restore per-phase model selections from session metadata
	_restore_phase_models_from_session(session_info)

	# Only clear action stream if this is a fresh load (not continuing an active session)
	# Don't clear if we're just loading history to view - preserve existing content
	var is_continuing = _continue_session_check_box and _continue_session_check_box.button_pressed
	if _action_stream and not is_continuing:
		# Only clear if action stream is empty or we're starting fresh
		if _action_stream._actions_list.get_child_count() == 0:
			_action_stream.clear()
	_submitted_questions.clear()
	
	# Get session metadata
	var prompt = session_info.get("prompt", "")
	var plan = session_info.get("plan", {})
	print("[SubmitJob] plan keys: %s" % str(plan.keys() if plan is Dictionary else "NOT A DICT"))
	var questions = plan.get("questions", []) if plan is Dictionary else []
	var tasks = plan.get("tasks", []) if plan is Dictionary else []
	var iterations = session_info.get("iterations", [])

	# Restore latest artifact info from session history
	if iterations is Array and iterations.size() > 0:
		var last_iter = iterations[iterations.size() - 1]
		if last_iter is Dictionary:
			var archive_uri = str(last_iter.get("output_archive_uri", ""))
			var patch_uri = str(last_iter.get("patch_uri", ""))
			if not archive_uri.is_empty():
				set_latest_archive_uri(session_id, archive_uri)
			if not patch_uri.is_empty():
				set_latest_patch_uri(session_id, patch_uri)
	
	# Check if Kanban board has tasks (from local storage)
	var kanban_board = _get_kanban_board_for_session(session_id)
	var kanban_task_count = 0
	if kanban_board and kanban_board.task_store:
		kanban_task_count = kanban_board.task_store.get_all_tasks().size()
	
	# Add initial prompt to action stream
	if not prompt.is_empty():
		_action_stream.add_message("📝 Initial Prompt:\n\n" + prompt, "user")
	else:
		_action_stream.add_message("ℹ️ Session Information\n\nNo prompt found - this might be an older session", "system")
	
	# Add planning result
	var session_status = session_info.get("status", "unknown")
	if tasks.size() > 0:
		_action_stream.add_message("✓ Planning Complete\n\nGenerated %d tasks - view them on the Kanban board" % tasks.size(), "system")
		var kanban_editor = _get_or_create_kanban_board(session_id)
		if kanban_editor and kanban_editor.kanban_board and kanban_editor.kanban_board.task_store:
			var task_store = kanban_editor.kanban_board.task_store
			if task_store.session_id.is_empty():
				task_store.session_id = session_id
			_populate_kanban_from_plan(tasks, task_store)
	elif kanban_task_count > 0:
		# Kanban has tasks but backend doesn't - this is normal during active coder sessions
		# Backend plan will sync via planning notifications
		if session_status in ["processing", "active", "in_progress"]:
			_action_stream.add_message("📋 Tasks\n\n%d tasks loaded - coder mode active" % kanban_task_count, "system")
		else:
			_action_stream.add_message("📋 Kanban Board\n\n%d tasks loaded from local storage" % kanban_task_count, "system")
	elif plan is Dictionary and not plan.is_empty():
		# Plan exists but has no tasks yet
		_action_stream.add_message("⏳ Planning Session\n\nPlanning in progress or awaiting question answers", "system")
	
	# Add questions if any
	if questions.size() > 0:
		print("[SubmitJob] Processing %d question(s) from session history" % questions.size())
		for question_data in questions:
			if question_data is Dictionary:
				var question_text = question_data.get("question", "")
				var question_id = question_data.get("id", "")
				var answered = question_data.get("answered", false)
				var answer = question_data.get("answer", "")
				var options = question_data.get("options", [])
				var _required = question_data.get("required", false)
				
				print("[SubmitJob]   Question %s: answered=%s, answer='%s', options=%s" % [question_id, str(answered), answer, str(options)])
				
				# Check if question is actually answered (be lenient with checking)
				var is_answered = answered == true or (not answer.is_empty() and answer != "null")
				
				if is_answered:
					var display_answer = answer if not answer.is_empty() else "(Skipped)"
					_action_stream.add_message("💬 Question:\n%s\n\n✓ Answered: %s" % [question_text, display_answer], "assistant")
				else:
					if _submitted_questions.has(question_id):
						_action_stream.add_message("💬 Question:\n%s\n\n✓ Answered: (recent)" % question_text, "assistant")
						continue
					# Show unanswered questions as interactive WITH OPTIONS
					if not question_id.is_empty():
						print("[SubmitJob]   Adding interactive question card with %d options" % options.size())
						_action_stream.add_question(question_id, question_text, options, session_id)
	
	# Load LLM traffic events for display (if available)
	var llm_events = session_info.get("llm_traffic_events", [])
	if llm_events is Array and llm_events.size() > 0:
		print("[SubmitJob] Loading %d LLM traffic events from session history" % llm_events.size())
		for event in llm_events:
			if event is Dictionary:
				var event_type = str(event.get("type", ""))
				var content = str(event.get("content", ""))
				var model = str(event.get("model", ""))
				
				if event_type == "request":
					var preview = "🚀 Request"
					if not model.is_empty():
						preview += " → %s" % model
					var data = event.get("data", {})
					if data is Dictionary:
						var prompt_preview = str(data.get("prompt_preview", ""))
						if not prompt_preview.is_empty():
							preview += "\n📝 " + (prompt_preview.substr(0, 100) + "..." if prompt_preview.length() > 100 else prompt_preview)
					_action_stream.add_message(preview, "request")
				elif event_type == "response_complete":
					var preview = "✅ Response"
					if not model.is_empty():
						preview += " ← %s" % model
					if not content.is_empty():
						preview += "\n" + (content.substr(0, 150) + "..." if content.length() > 150 else content)
					_action_stream.add_message(preview, "response")
	
	# Show approval card if session is awaiting user action
	var status_lower = str(session_status).to_lower()
	if status_lower in ["awaiting_user", "in_review"] and iterations is Array and iterations.size() > 0:
		var last_iter = iterations[iterations.size() - 1]
		if last_iter is Dictionary:
			var iter_status = str(last_iter.get("status", "")).to_lower()
			if iter_status == "awaiting_user" or status_lower == "awaiting_user":
				print("[SubmitJob] Session is awaiting user - showing approval card")
				add_approval_card(session_id, last_iter)

	print("[SubmitJob] Loaded session history: backend_tasks=%d, backend_questions=%d, kanban_tasks=%d, llm_events=%d" % [tasks.size(), questions.size(), kanban_task_count, llm_events.size() if llm_events is Array else 0])


func _status_emoji(status: String) -> String:
	match status.to_lower():
		"complete":
			return "✅"
		"in_review", "awaiting_user":
			return "🟡"
		"processing", "active":
			return "🟢"
		"error":
			return "🔴"
		_:
			return "⚪"


func _format_timestamp(timestamp: String) -> String:
	if timestamp.is_empty():
		return "unknown"
	if timestamp.length() >= 16:
		var date_part = timestamp.substr(0, 10)
		var time_part = timestamp.substr(11, 5)
		return "%s %s" % [date_part, time_part]
	return timestamp


func _on_session_view_requested(session_id: String) -> void:
	if not SingletonObject.autocoder_manager:
		return

	_auto_select_session(session_id)


func _on_session_resume_requested(session_id: String) -> void:
	"""Handle resuming a session - switch to Jobs tab and select the session"""
	if session_id.is_empty():
		return
	
	# Check if session is currently ongoing (processing/active)
	var session_status = await _get_session_status(session_id)
	var ongoing_statuses = ["processing", "active", "in_review"]
	
	if session_status in ongoing_statuses:
		# Don't switch tabs for ongoing sessions, just monitor
		var user_id = Core.client.client_id
		SingletonObject.autocoder_manager.monitor_session(user_id, session_id)
		SingletonObject.create_toast_notification(
			"Session is currently ongoing - monitoring it now",
			ToastNotification.Type.INFO
		)
		return
	
	# Switch to Jobs tab (index 0)
	var tab_container = get_parent()
	if tab_container is TabContainer:
		tab_container.current_tab = 0
	
	# Auto-select the session in the dropdown
	_auto_select_session(session_id)
	
	SingletonObject.create_toast_notification(
		"Session selected - ready to continue",
		ToastNotification.Type.SUCCESS
	)


func _on_select_package_button_pressed() -> void:

	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't fetch", "Please connect to core first!")
		return

	# Prefer private artifacts first
	var artifacts: = await SingletonObject.autocoder_manager.artifact_registry_adapter.list_mine()
	_artifact_browser.set_artifacts(artifacts)

	_artifact_browser_popup.size = DisplayServer.screen_get_size() * 0.9
	_artifact_browser_popup.popup_centered()


func _on_attach_folder_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't upload", "Please connect to core first!")
		return
	
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Select Folder to Attach"
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)
	
	var selected_dir = await dialog.dir_selected
	dialog.queue_free()
	
	if selected_dir.is_empty():
		return
	
	_set_pending_source_dir(selected_dir)
	SingletonObject.create_toast_notification("Packaging folder...", ToastNotification.Type.INFO)
	
	var dir_name = selected_dir.get_file()
	var metadata := {
		"filename": "%s.tar.gz" % (dir_name if not dir_name.is_empty() else "artifact"),
		"description": "Uploaded from Submit Job",
		"visibility": "private"
	}
	
	var local_artifact: = Artifact.create_from_dir(selected_dir, metadata)
	if not local_artifact:
		SingletonObject.ErrorDisplay("Can't create", "Failed to package selected folder")
		return
	
	var artifact: = await SingletonObject.autocoder_manager.artifact_registry_adapter.upload(local_artifact)
	if not artifact:
		SingletonObject.ErrorDisplay("Can't upload", "Failed to upload artifact")
		return
	
	selected_artifact = artifact
	SingletonObject.create_toast_notification("Folder attached successfully", ToastNotification.Type.SUCCESS)
	_update_download_latest_button()


func _on_set_source_folder_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Select Source Folder"
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)
	
	var selected_dir = await dialog.dir_selected
	dialog.queue_free()
	
	if selected_dir.is_empty():
		return
	
	_set_pending_source_dir(selected_dir)
	var session_id = _get_selected_session_id()
	if not session_id.is_empty():
		_save_source_dir_for_session(session_id, selected_dir)
	SingletonObject.create_toast_notification("Source folder set", ToastNotification.Type.SUCCESS)
	_update_download_latest_button()


func set_latest_archive_uri(session_id: String, archive_uri: String) -> void:
	if session_id.is_empty() or archive_uri.is_empty():
		return
	_latest_archive_by_session[session_id] = archive_uri
	_update_download_latest_button()


func set_latest_patch_uri(session_id: String, patch_uri: String) -> void:
	if session_id.is_empty() or patch_uri.is_empty():
		return
	_latest_patch_by_session[session_id] = patch_uri
	_update_download_latest_button()


func _update_download_latest_button() -> void:
	if not _download_latest_button:
		return
	var session_id = _get_selected_session_id()
	var archive_uri = _latest_archive_by_session.get(session_id, "")
	var patch_uri = _latest_patch_by_session.get(session_id, "")
	var source_dir = _source_dir_by_session.get(session_id, "")
	_download_latest_button.disabled = archive_uri.is_empty()
	if _extract_latest_button:
		_extract_latest_button.disabled = archive_uri.is_empty() or source_dir.is_empty()
	if _download_patch_button:
		_download_patch_button.disabled = patch_uri.is_empty()
	_update_resource_labels()


func _update_resource_labels() -> void:
	if not _selected_artifact_uri_label:
		return
	if selected_artifact:
		_selected_artifact_uri_label.text = selected_artifact.artifact_uri
		return
	var session_id = _get_selected_session_id()
	var source_dir = _source_dir_by_session.get(session_id, "")
	if source_dir.is_empty():
		_selected_artifact_uri_label.text = "-"
	else:
		_selected_artifact_uri_label.text = "Source folder: %s" % source_dir


func _save_source_dir_for_session(session_id: String, path: String) -> void:
	if session_id.is_empty() or path.is_empty():
		return
	_source_dir_by_session[session_id] = path
	SingletonObject.save_to_config_file(SOURCE_DIR_SECTION, session_id, path)


func _restore_source_dir_for_session(session_id: String) -> void:
	if session_id.is_empty():
		return
	if _source_dir_by_session.has(session_id):
		return
	var stored = SingletonObject.get_config_file_value(SOURCE_DIR_SECTION, session_id)
	if stored is String and not String(stored).is_empty():
		_source_dir_by_session[session_id] = String(stored)


func _set_pending_source_dir(path: String) -> void:
	if path.is_empty():
		return
	_pending_source_dir = path
	var session_id = _get_selected_session_id()
	if not session_id.is_empty() and _continue_session_check_box.button_pressed:
		_save_source_dir_for_session(session_id, path)
	_update_resource_labels()


func _on_download_latest_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't download", "Please connect to core first!")
		return
	var session_id = _get_selected_session_id()
	var archive_uri = _latest_archive_by_session.get(session_id, "")
	if archive_uri.is_empty():
		SingletonObject.create_toast_notification("No artifact available yet for this session", ToastNotification.Type.INFO)
		return
	await SingletonObject.autocoder_manager.artifact_registry_adapter.download(archive_uri)


func _on_extract_latest_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't extract", "Please connect to core first!")
		return
	var session_id = _get_selected_session_id()
	var archive_uri = _latest_archive_by_session.get(session_id, "")
	if archive_uri.is_empty():
		SingletonObject.create_toast_notification("No artifact available yet for this session", ToastNotification.Type.INFO)
		return
	_restore_source_dir_for_session(session_id)
	var source_dir = _source_dir_by_session.get(session_id, "")
	if source_dir.is_empty():
		SingletonObject.ErrorDisplay("Missing source folder", "Attach a folder first to set the destination.")
		return
	await SingletonObject.autocoder_manager.artifact_registry_adapter.download_and_extract(archive_uri, source_dir)


func _on_download_patch_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't download", "Please connect to core first!")
		return
	var session_id = _get_selected_session_id()
	var patch_uri = _latest_patch_by_session.get(session_id, "")
	if patch_uri.is_empty():
		SingletonObject.create_toast_notification("No patch available yet for this session", ToastNotification.Type.INFO)
		return
	await SingletonObject.autocoder_manager.artifact_registry_adapter.download(patch_uri)


## Open artifact browser and select a specific artifact by URI
func open_artifact_browser_with_selection(artifact_uri: String) -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't open browser", "Please connect to core first!")
		return

	_artifact_browser_popup.size = DisplayServer.screen_get_size() * 0.9
	_artifact_browser_popup.popup_centered()

	# Refresh and select the artifact
	await _artifact_browser.refresh_and_select(artifact_uri)



func _on_artifact_browser_selection_canceled() -> void:
	_artifact_browser_popup.hide()

func _on_artifact_browser_artifact_selected(artifact: Artifact) -> void:
	selected_artifact = artifact
	_artifact_browser_popup.hide()



func _on_clear_input_resources_button_pressed() -> void:
	selected_artifact = null
	_pending_source_dir = ""
	_update_download_latest_button()

func _on_create_package_button_pressed() -> void:
	var editor: = SingletonObject.editor_pane.add(Editor.Type.PACKAGE)

	# Capture source directory when user selects a folder
	editor.package_editor.directory_selected.connect(
		func(path: String):
			_set_pending_source_dir(path)
	)

	editor.package_editor.artifact_uploaded.connect(
		func(artifact: Artifact):
			selected_artifact = artifact
	)


func _on_continue_session_check_box_pressed() -> void:
	pass # Replace with function body.


func _on_continue_session_check_box_toggled(toggled_on: bool) -> void:
	_session_option_button.disabled = not toggled_on or _session_option_button.item_count <= 1
	_set_job_state(_job_state)


func _on_new_session_toggled(_toggled_on: bool) -> void:
	_session_option_button.disabled = not _continue_session_check_box.button_pressed or _session_option_button.item_count <= 1
	_set_job_state(_job_state)


func _on_session_option_selected(_index: int) -> void:
	var session_id = _get_selected_session_id()
	if not session_id.is_empty():
		if _continue_session_check_box:
			_continue_session_check_box.button_pressed = true
			_session_option_button.disabled = false
		var user_id = Core.client.client_id
		if SingletonObject.autocoder_manager:
			SingletonObject.autocoder_manager.monitor_session(user_id, session_id)
	_restore_source_dir_for_session(session_id)
	_update_download_latest_button()


func _on_review_agents_refresh_pressed() -> void:
	_refresh_review_agents()


func _on_review_agents_clear_pressed() -> void:
	for child in _agent_checkbox_list.get_children():
		if child is CheckBox:
			child.button_pressed = false
	# Reset preset selector to "no preset"
	if _preset_option_button.item_count > 0:
		_preset_option_button.select(0)


func _on_select_all_pressed() -> void:
	for child in _agent_checkbox_list.get_children():
		if child is CheckBox:
			child.button_pressed = true


## Cached preset data: Array of { preset_id, name, agent_ids }
var _cached_presets: Array[Dictionary] = []


func _refresh_presets() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		_populate_presets([])
		return
	var presets = await SingletonObject.autocoder_manager.autocoder_adapter.list_review_presets()
	_populate_presets(presets)


func _populate_presets(presets: Array[Dictionary]) -> void:
	_cached_presets.clear()
	_preset_option_button.clear()
	_preset_option_button.add_item("No Preset")
	_preset_option_button.set_item_metadata(0, "")

	for preset in presets:
		if not (preset is Dictionary):
			continue
		var preset_id = str(preset.get("preset_id", ""))
		if preset_id.is_empty():
			continue
		var preset_name = str(preset.get("name", "Unnamed Preset"))
		var agent_ids = preset.get("agent_ids", [])
		var count = agent_ids.size() if agent_ids is Array else 0
		var label = "%s (%d agents)" % [preset_name, count]
		var index = _preset_option_button.item_count
		_preset_option_button.add_item(label)
		_preset_option_button.set_item_metadata(index, preset_id)
		_cached_presets.append(preset)

	_preset_option_button.select(0)


func _on_preset_selected(index: int) -> void:
	if index <= 0:
		return  # "No Preset" selected — don't change checkboxes

	var preset_id = str(_preset_option_button.get_item_metadata(index))
	if preset_id.is_empty():
		return

	# Find the preset in cache
	var target_ids: Array = []
	for preset in _cached_presets:
		if str(preset.get("preset_id", "")) == preset_id:
			target_ids = preset.get("agent_ids", [])
			break

	if target_ids.is_empty():
		return

	# Uncheck all, then check matching agents
	for child in _agent_checkbox_list.get_children():
		if child is CheckBox:
			var agent_id = str(child.get_meta("agent_id", ""))
			child.button_pressed = agent_id in target_ids


func _on_save_preset_pressed() -> void:
	var selected_ids = _get_selected_review_agent_ids()
	if selected_ids.is_empty():
		SingletonObject.create_toast_notification("Select at least one agent first", ToastNotification.Type.WARNING)
		return

	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.create_toast_notification("AutoCoder not connected", ToastNotification.Type.ERROR)
		return

	# Use a simple input dialog via LineEdit popup
	var dialog = AcceptDialog.new()
	dialog.title = "Save Preset"
	dialog.dialog_text = "Enter a name for this preset:"
	var line_edit = LineEdit.new()
	line_edit.placeholder_text = "e.g. Godot Review Suite"
	dialog.add_child(line_edit)
	add_child(dialog)
	dialog.popup_centered(Vector2i(350, 120))

	await dialog.confirmed

	var preset_name = line_edit.text.strip_edges()
	dialog.queue_free()

	if preset_name.is_empty():
		SingletonObject.create_toast_notification("Preset name cannot be empty", ToastNotification.Type.WARNING)
		return

	var preset_id = await SingletonObject.autocoder_manager.autocoder_adapter.create_review_preset(preset_name, selected_ids)
	if not preset_id.is_empty():
		SingletonObject.create_toast_notification("Preset '%s' saved" % preset_name, ToastNotification.Type.SUCCESS)
		_refresh_presets()
	else:
		SingletonObject.create_toast_notification("Failed to save preset", ToastNotification.Type.ERROR)


func _on_submit_job_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.ErrorDisplay("Can't start", "Please connect to core first!")
		return

	var session_id = ""
	var is_continue = _continue_session_check_box.button_pressed

	if is_continue:
		session_id = _get_selected_session_id()
		if session_id.is_empty():
			SingletonObject.ErrorDisplay("Continue Session", "Select a session to continue.")
			return

	# Check for concurrent requests on same session
	if not session_id.is_empty() and _processing_sessions.get(session_id, false):
		SingletonObject.create_toast_notification(
			"Session is already processing a request. Please wait.",
			ToastNotification.Type.WARNING
		)
		return

	# Mark session as processing
	if not session_id.is_empty():
		_processing_sessions[session_id] = true

	var user_id = Core.client.client_id
	var model_id = _get_selected_model_id()
	var phase_models = _get_phase_models()
	var prompt_with_notes = _build_prompt_with_notes()

	# Disable injected notes now that their content is captured
	_disable_injected_notes()

	# Resolve per-phase models (non-empty override wins, else fall back to main dropdown)
	var planning_model = phase_models["planning"] if not phase_models["planning"].is_empty() else model_id

	# Disable prompt while processing
	_set_prompt_enabled(false)

	# If continuing a session that already has a plan, skip planning and go straight to generate
	if is_continue and not session_id.is_empty():
		var session_status = await _get_session_status(session_id)
		# Sessions that completed planning or are awaiting_user can skip to generate
		if session_status in ["planning_complete", "awaiting_user", "complete", "completed"]:
			print("[SubmitJob] Session already planned, skipping to generation...")
			_auto_promote_session_id = session_id
			_auto_promote_generate(session_id, model_id)
			return

	# Start planning phase
	_set_job_state(JobState.PLANNING)
	SingletonObject.create_toast_notification("Starting planning...", ToastNotification.Type.INFO)

	var planning_action_id = "planning_%d" % Time.get_ticks_msec()
	add_tool_call("🤖 AI Planning", "Generating development plan and breaking down tasks...", planning_action_id)

	# Get current Kanban board state for synchronization
	var kanban_board = _get_kanban_board_for_session(session_id)
	var kanban_state = {}
	var kanban_hash = ""

	if kanban_board and kanban_board.task_store:
		kanban_state = kanban_board.task_store.serialize()
		kanban_hash = kanban_board.task_store.calculate_hash()
		print("[SubmitJob] Sending Kanban state with %d tasks, hash: %s" % [kanban_board.task_store.get_all_tasks().size(), kanban_hash.substr(0, 8)])

	var planning_output = await SingletonObject.autocoder_manager.autocoder_adapter.plan(
		prompt_with_notes,
		session_id,
		selected_artifact.artifact_uri if selected_artifact else "",
		planning_model,
		"",  # modify_request
		kanban_state,
		kanban_hash
	)

	if not planning_output:
		update_tool_call(planning_action_id, "failed", "Planning failed - check logs for details")
		if not session_id.is_empty():
			_processing_sessions[session_id] = false
		_set_prompt_enabled(true)
		_set_job_state(JobState.ERROR)
		return

	var task_count = planning_output.tasks.size()
	print("[SubmitJob] Planning response received with %d tasks" % task_count)

	if task_count > 0:
		update_tool_call(planning_action_id, "completed", "Plan generated with %d tasks" % task_count)
	else:
		update_tool_call(planning_action_id, "completed", "Planning in progress - tasks will appear shortly...")

	var output = {
		"session_id": planning_output.session_id,
		"message": planning_output.message,
		"notification_topics": planning_output.notification_topics,
		"status": planning_output.status,
		"user_id": planning_output.user_id,
		"iteration": 0.0,
		"tasks": planning_output.tasks,
		"questions": planning_output.questions
	}

	SingletonObject.create_toast_notification(output.message, ToastNotification.Type.SUCCESS)

	var effective_session_id = session_id if not session_id.is_empty() else output.session_id
	_auto_promote_session_id = effective_session_id

	if not session_id.is_empty() and output.session_id != session_id:
		print("[SubmitJob] WARNING: Backend returned different session_id. Original: %s, Returned: %s" % [session_id, output.session_id])

	# Handle planning results (kanban board)
	if output.has("tasks"):
		_handle_planning_results(output)

	# Save source directory association if we have one
	if not _pending_source_dir.is_empty():
		_save_source_dir_for_session(effective_session_id, _pending_source_dir)
		_pending_source_dir = ""

	# Ensure session is monitored
	if not SingletonObject.autocoder_manager._monitoring_sessions.has(effective_session_id):
		SingletonObject.autocoder_manager.monitor_session(
			output.user_id,
			effective_session_id,
			output.notification_topics
		)

	# Refresh session dropdown
	await _refresh_session_history()
	_ensure_session_option(effective_session_id, output.status)
	_select_session_in_dropdown(effective_session_id)

	# Release processing flag (planning phase done, generate will re-acquire)
	if not effective_session_id.is_empty():
		_processing_sessions[effective_session_id] = false

	# Do NOT reset state to IDLE here - wait for on_planning_turn_complete() to auto-promote
	# The prompt stays disabled until generation completes


## Auto-promote: start code generation after planning completes
func _auto_promote_generate(session_id: String, model_id: String = "") -> void:
	_set_job_state(JobState.GENERATING)

	if model_id.is_empty():
		model_id = _get_selected_model_id()

	# Resolve per-phase models
	var phase_models = _get_phase_models()
	var generation_model = phase_models["generation"] if not phase_models["generation"].is_empty() else model_id
	var review_model = phase_models["review"]  # Empty string means use default on backend

	# Collect per-task model overrides from kanban board
	var task_overrides: Dictionary = {}
	var kanban_board = _get_kanban_board_for_session(session_id)
	if kanban_board and kanban_board.task_store:
		for task in kanban_board.task_store.get_all_tasks():
			if not task.assigned_model.is_empty():
				task_overrides[task.id] = task.assigned_model

	var review_agent_ids: Array = _get_selected_review_agent_ids()
	var auto_review = not review_agent_ids.is_empty()
	var require_permission = _require_permission_check_box.button_pressed
	var user_id = Core.client.client_id

	print("[SubmitJob] Auto-promote: generating for session %s (model=%s, review_model=%s, task_overrides=%d, auto_review=%s, agents=%s)" % [session_id, generation_model, review_model, task_overrides.size(), auto_review, review_agent_ids])

	# Clean workspace before generation
	SingletonObject.create_toast_notification("Preparing workspace...", ToastNotification.Type.INFO)
	var cleanup_success = await SingletonObject.autocoder_manager.autocoder_adapter.cleanup(true)
	if not cleanup_success:
		SingletonObject.ErrorDisplay("Cleanup Failed", "Failed to clean workspace. Cannot start generation.")
		_set_job_state(JobState.ERROR)
		_set_prompt_enabled(true)
		return

	# Set up monitoring BEFORE generate call
	if not session_id.is_empty():
		SingletonObject.autocoder_manager.monitor_session(user_id, session_id)
		_get_or_create_kanban_board(session_id)

	# Mark session as processing
	_processing_sessions[session_id] = true

	var output = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
		"",  # No additional prompt - plan tasks are the instructions
		session_id,
		selected_artifact.artifact_uri if selected_artifact else "",
		require_permission,
		generation_model,
		review_agent_ids,
		true,  # use_plan_tasks = true
		[],
		auto_review,
		review_model,
		task_overrides
	)

	# Release processing flag
	_processing_sessions[session_id] = false

	if not output:
		_set_job_state(JobState.ERROR)
		_set_prompt_enabled(true)
		return

	SingletonObject.create_toast_notification(output.message, ToastNotification.Type.SUCCESS)

	# Re-enable prompt and clear text
	_set_prompt_enabled(true)
	_prompt_text_edit.text = ""

	# State will transition to AWAITING_USER or ERROR via _handle_iteration_notification
	# For now, remain in GENERATING until notified


# Action Stream helpers

func add_tool_call(tool_name: String, description: String, action_id: String = "") -> void:
	if _action_stream:
		_action_stream.add_tool_call(tool_name, description, action_id)

func update_tool_call(action_id: String, status: String, output: String = "") -> void:
	if _action_stream:
		_action_stream.update_tool_call(action_id, status, output)

func add_message(content: String, role: String = "assistant") -> void:
	if _action_stream:
		_action_stream.add_message(content, role)


func add_iteration_message(_session_id: String, payload: Dictionary) -> void:
	if not _action_stream:
		return
	var status = str(payload.get("status", "unknown")).to_lower()
	var message = str(payload.get("message", ""))
	var summary = str(payload.get("summary", ""))
	var file_count = int(payload.get("file_count", 0))
	var archive_uri = str(payload.get("output_archive_uri", ""))
	if archive_uri.is_empty():
		archive_uri = str(payload.get("archive_uri", ""))
	var patch_uri = str(payload.get("patch_uri", ""))
	var lines: Array[String] = []
	lines.append("📦 Iteration update (%s)" % status)
	if not message.is_empty():
		lines.append("Message: %s" % message)
	if not summary.is_empty():
		lines.append("Summary: %s" % summary)
	if file_count > 0:
		lines.append("Files: %d" % file_count)
	if not archive_uri.is_empty():
		lines.append("Archive: %s" % archive_uri)
	if not patch_uri.is_empty():
		lines.append("Patch: %s" % patch_uri)
	_action_stream.add_message("\n".join(lines), "system")

func add_approval_card(session_id: String, payload: Dictionary) -> void:
	"""Add an approval card to the action stream for awaiting_user sessions"""
	if not _action_stream:
		return
	var archive_uri = str(payload.get("output_archive_uri", ""))
	if archive_uri.is_empty():
		archive_uri = str(payload.get("archive_uri", ""))
	var patch_uri = str(payload.get("patch_uri", ""))
	var review_summary = str(payload.get("ai_review_summary", ""))
	if review_summary.is_empty():
		review_summary = str(payload.get("summary", ""))
	var file_count = int(payload.get("files_changed_count", payload.get("file_count", 0)))

	# Extract individual review results
	var review_results: Array = []
	var review_result = payload.get("review_result", {})
	if review_result is Dictionary:
		var reviews = review_result.get("reviews", [])
		if reviews is Array:
			review_results = reviews

	# Store archive/patch URIs for download buttons
	if not archive_uri.is_empty():
		set_latest_archive_uri(session_id, archive_uri)
	if not patch_uri.is_empty():
		set_latest_patch_uri(session_id, patch_uri)

	_action_stream.add_approval_card(session_id, archive_uri, patch_uri, review_summary, file_count, review_results)


func _on_approval_action(session_id: String, action: String, feedback: String) -> void:
	"""Handle approve/reject from approval card"""
	var autocoder_manager = SingletonObject.autocoder_manager
	if not autocoder_manager or not autocoder_manager.autocoder_adapter:
		SingletonObject.create_toast_notification("Autocoder not connected", ToastNotification.Type.WARNING)
		return

	var user_id = Core.client.client_id
	var success := false

	match action:
		"approve":
			success = await autocoder_manager.autocoder_adapter.approve(user_id, session_id)
			if success:
				SingletonObject.create_toast_notification("Session approved", ToastNotification.Type.SUCCESS)
				_set_job_state(JobState.IDLE)
				_set_prompt_enabled(true)
			else:
				SingletonObject.create_toast_notification("Failed to approve session", ToastNotification.Type.WARNING)
		"reject":
			success = await autocoder_manager.autocoder_adapter.request_revision(user_id, session_id, feedback)
			if success:
				SingletonObject.create_toast_notification("Revision requested", ToastNotification.Type.SUCCESS)
				_set_job_state(JobState.GENERATING)
			else:
				SingletonObject.create_toast_notification("Failed to request revision", ToastNotification.Type.WARNING)


func _on_approval_extract(session_id: String) -> void:
	"""Handle extract request from approval card"""
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't extract", "Please connect to core first!")
		return

	var archive_uri = _latest_archive_by_session.get(session_id, "")
	if archive_uri.is_empty():
		SingletonObject.create_toast_notification("No artifact available for this session", ToastNotification.Type.WARNING)
		return

	_restore_source_dir_for_session(session_id)
	var source_dir = _source_dir_by_session.get(session_id, "")

	if not source_dir.is_empty():
		# Source folder already set - extract directly
		await SingletonObject.autocoder_manager.artifact_registry_adapter.download_and_extract(archive_uri, source_dir)
	else:
		# Show directory picker
		var dialog := FileDialog.new()
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dialog.title = "Select folder to extract generated code"
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		add_child(dialog)
		dialog.popup_centered_ratio(0.6)

		var selected_dir = await dialog.dir_selected
		dialog.queue_free()

		if selected_dir.is_empty():
			return

		_save_source_dir_for_session(session_id, selected_dir)
		await SingletonObject.autocoder_manager.artifact_registry_adapter.download_and_extract(archive_uri, selected_dir)


func add_llm_progress(content: String) -> void:
	"""Route LLM traffic to action stream for visibility"""
	add_llm_traffic("", content)


func add_llm_traffic(_session_id: String, content: String) -> void:
	if not _action_stream or content.is_empty():
		return
	_action_stream.add_llm_progress(content)

func add_llm_delta(_session_id: String, delta: String) -> void:
	"""Add LLM content delta (streaming chunk) - accumulates into existing card"""
	if not _action_stream or delta.is_empty():
		return
	_action_stream.add_llm_delta(delta)

func add_llm_traffic_with_full_content(_session_id: String, preview_content: String, full_content: String) -> void:
	"""Add LLM traffic with preview and full content option"""
	if not _action_stream or preview_content.is_empty():
		return
	_action_stream.add_llm_progress_with_full_content(preview_content, full_content)


func add_llm_request(_session_id: String, preview_content: String, full_content: String) -> void:
	"""Add LLM request event to action stream (for OpenCode/OpenRouter requests)"""
	if not _action_stream or preview_content.is_empty():
		return
	# Use same display method but could use different styling in the future
	_action_stream.add_llm_progress_with_full_content(preview_content, full_content)


func stop_llm_stream() -> void:
	if _action_stream:
		_action_stream.stop_llm_progress()

func add_question(question_id: String, question_text: String, options: Array = [], session_id: String = "") -> void:
	if _action_stream:
		_action_stream.add_question(question_id, question_text, options, session_id)

func skip_question(question_id: String) -> void:
	"""Skip a question by providing empty answer (autocoder will determine best answer)"""
	if _action_stream:
		var session_id = _get_selected_session_id()
		_on_question_answered(question_id, "", session_id)


func on_session_id_changed(old_session_id: String, new_session_id: String) -> void:
	"""Handle session ID change when transitioning from planning to coder mode.
	The backend creates a new OpenCode session, so we need to update our references."""
	print("[SubmitJob] 🔄 Session ID changed: %s -> %s" % [old_session_id, new_session_id])
	
	# Migrate tracking data from old session to new session
	if _processing_sessions.has(old_session_id):
		_processing_sessions[new_session_id] = _processing_sessions[old_session_id]
		_processing_sessions.erase(old_session_id)
	
	if _latest_archive_by_session.has(old_session_id):
		_latest_archive_by_session[new_session_id] = _latest_archive_by_session[old_session_id]
		_latest_archive_by_session.erase(old_session_id)
	
	if _latest_patch_by_session.has(old_session_id):
		_latest_patch_by_session[new_session_id] = _latest_patch_by_session[old_session_id]
		_latest_patch_by_session.erase(old_session_id)
	
	if _source_dir_by_session.has(old_session_id):
		_source_dir_by_session[new_session_id] = _source_dir_by_session[old_session_id]
		_source_dir_by_session.erase(old_session_id)
		# Also update the config file
		var source_dir = _source_dir_by_session[new_session_id]
		SingletonObject.save_to_config_file(SOURCE_DIR_SECTION, new_session_id, source_dir)
	
	# Update kanban board session ID if it exists
	var kanban_board = _get_kanban_board_for_session(old_session_id)
	if kanban_board:
		kanban_board.set_meta("session_id", new_session_id)
		if kanban_board.task_store:
			kanban_board.task_store.session_id = new_session_id
		print("[SubmitJob] Updated kanban board session ID to: %s" % new_session_id)
	
	# Update the session dropdown if it has the old session
	if _session_option_button:
		for i in range(_session_option_button.item_count):
			var item_text = _session_option_button.get_item_text(i)
			if old_session_id in item_text:
				var new_label = item_text.replace(old_session_id, new_session_id)
				_session_option_button.set_item_text(i, new_label)
				print("[SubmitJob] Updated session dropdown: %s" % new_label)
				break

func _on_question_answered(question_id: String, answer: String, session_id: String = "") -> void:
	"""Handle question answer and forward to backend"""
	var autocoder_manager = SingletonObject.autocoder_manager
	if not autocoder_manager or not autocoder_manager.autocoder_adapter:
		push_warning("[SubmitJob] Cannot answer question - autocoder not available")
		return
	
	var resolved_session_id = session_id
	if resolved_session_id.is_empty():
		# Fallback to session dropdown if the card did not provide it
		resolved_session_id = _get_selected_session_id()
	if resolved_session_id.is_empty():
		push_warning("[SubmitJob] Cannot answer question - no session selected")
		return
	
	print("[SubmitJob] ========== ANSWERING QUESTION ==========")
	print("[SubmitJob] Session: %s" % resolved_session_id)
	print("[SubmitJob] Question ID: %s" % question_id)
	print("[SubmitJob] Answer: %s" % (answer if not answer.is_empty() else "(skipped)"))
	if _submitted_questions.has(question_id):
		print("[SubmitJob] Skipping duplicate answer for question: %s" % question_id)
		return
	_submitted_questions[question_id] = true
	
	# Show progress BEFORE the await - the backend response only arrives after
	# the follow-up planning is complete, so add the spinner now while we wait
	_action_stream.add_llm_progress("Continuing planning with your answers...")
	_set_prompt_enabled(false)
	
	# Forward to autocoder adapter (await it since it's async)
	# NOTE: The backend sends the planning_complete notification BEFORE returning
	# the response, so on_planning_turn_complete() may have already run by the
	# time this returns. We call stop_llm_progress() here as a safety net.
	var success = await autocoder_manager.autocoder_adapter.answer_question(resolved_session_id, question_id, answer)
	
	print("[SubmitJob] Answer submission result: %s" % ("SUCCESS" if success else "FAILED"))
	
	# Always stop the spinner after the await returns (safety net in case
	# on_planning_turn_complete fired before the spinner was created)
	if _action_stream:
		_action_stream.stop_llm_progress()
	
	if success:
		SingletonObject.create_toast_notification(
			"Answer submitted - plan updated",
			ToastNotification.Type.INFO
		)
		print("[SubmitJob] Now waiting for planning notification on topic: autocoder-orchestrator/planning/%s/%s" % [Core.client.client_id, resolved_session_id])
	else:
		_set_prompt_enabled(true)
		SingletonObject.create_toast_notification(
			"Answer submission failed - please retry if needed",
			ToastNotification.Type.WARNING
		)

func clear_action_stream() -> void:
	if _action_stream:
		_action_stream.clear()

func on_planning_turn_complete(session_id: String, planning_status: String) -> void:
	"""Called when a planning turn completes (from AutocoderManager)"""
	print("[SubmitJob] Planning turn complete for session %s (status: %s, job_state: %d)" % [session_id, planning_status, _job_state])

	# Stop LLM progress animations
	if _action_stream:
		_action_stream.stop_llm_progress()
	_submitted_questions.clear()

	match planning_status:
		"complete":
			# Auto-promote: if we were planning or awaiting questions, auto-start generation
			if _job_state == JobState.PLANNING or _job_state == JobState.AWAITING_QUESTIONS:
				if _auto_generate_check_box.button_pressed:
					if _action_stream:
						_action_stream.add_message("✓ Planning Complete — auto-starting generation...", "system")

					SingletonObject.create_toast_notification(
						"Planning complete — starting code generation...",
						ToastNotification.Type.SUCCESS
					)

					var model_id = _get_selected_model_id()
					var promote_session_id = session_id if not session_id.is_empty() else _auto_promote_session_id
					_auto_promote_generate(promote_session_id, model_id)
				else:
					# Auto-generate off — pause so user can review tasks / set per-task models
					if _action_stream:
						_action_stream.add_message("✓ Planning Complete\n\nReview tasks and click Start Generation when ready.", "system")
					SingletonObject.create_toast_notification(
						"Planning complete — review tasks, then start generation.",
						ToastNotification.Type.SUCCESS
					)
					_set_job_state(JobState.IDLE)
					_set_prompt_enabled(true)
					# Override button text to clarify the next action
					if _submit_job_button:
						_submit_job_button.tooltip_text = "Start Generation"
			else:
				# Planning completed outside of auto-promote flow (e.g. resumed session)
				if _action_stream:
					_action_stream.add_message("✓ Planning Complete\n\nClick Start Job to generate code", "system")
				_set_job_state(JobState.IDLE)
				_set_prompt_enabled(true)

		"awaiting_answers":
			_set_job_state(JobState.AWAITING_QUESTIONS)
			_set_prompt_enabled(true)
			SingletonObject.create_toast_notification(
				"Planning paused — answer questions to continue",
				ToastNotification.Type.INFO
			)

func on_planning_error(session_id: String, error_msg: String) -> void:
	"""Called when planning fails (e.g. LLM timeout). Resets UI so user isn't stuck."""
	print("[SubmitJob] Planning error for session %s: %s" % [session_id, error_msg])

	# Stop LLM progress animations
	if _action_stream:
		_action_stream.stop_llm_progress()
		_action_stream.add_message("Planning failed: %s" % error_msg, "error")

	# Release processing flag
	if not session_id.is_empty():
		_processing_sessions[session_id] = false

	# Re-enable controls
	_set_prompt_enabled(true)
	_set_job_state(JobState.ERROR)

	SingletonObject.create_toast_notification(
		"Planning failed: %s" % error_msg.substr(0, 100),
		ToastNotification.Type.WARNING
	)


func _set_prompt_enabled(enabled: bool) -> void:
	"""Enable or disable the prompt input"""
	if _prompt_text_edit:
		_prompt_text_edit.editable = enabled
		if enabled:
			_prompt_text_edit.placeholder_text = "Enter additional instructions, modifications, or questions..."
		else:
			_prompt_text_edit.placeholder_text = "Processing..."

# ============================================================================
# Clear / Voice Input / Stop
# ============================================================================

func _on_clear_text_button_pressed() -> void:
	_prompt_text_edit.text = ""


func _on_microphone_button_pressed() -> void:
	if SingletonObject.AtT._StartConverting() != OK:
		return
	SingletonObject.AtT.FieldForFilling = _prompt_text_edit
	SingletonObject.AtT.btn = _microphone_button
	_microphone_button.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = _stop_button


func _on_stop_button_pressed() -> void:
	# Stop any active voice transcription
	SingletonObject.AtT._StopConverting()

	# Stop any active autocoder job
	if _job_state == JobState.PLANNING or _job_state == JobState.GENERATING:
		if _action_stream:
			_action_stream.stop_llm_progress()
			_action_stream.add_message("Stopped by user.", "system")
		SingletonObject.create_toast_notification("Job stopped", ToastNotification.Type.INFO)
		_set_job_state(JobState.IDLE)
		_set_prompt_enabled(true)


# ============================================================================
# Planning Action Buttons (Add Context / Inject Notes)
# ============================================================================

func _create_planning_actions_row() -> void:
	"""Create the planning action buttons row and add it to the action stream"""
	if not _action_stream:
		return

	_planning_actions_row = HBoxContainer.new()
	_planning_actions_row.visible = false
	_planning_actions_row.add_theme_constant_override("separation", 8)

	_add_context_button = Button.new()
	_add_context_button.text = "Add Context"
	_add_context_button.flat = true
	_add_context_button.add_theme_font_size_override("font_size", 16)
	_add_context_button.add_theme_color_override("font_color", Color(0.5, 0.75, 1.0, 1.0))
	_add_context_button.pressed.connect(_on_add_context_pressed)
	_planning_actions_row.add_child(_add_context_button)

	_inject_notes_button = Button.new()
	_inject_notes_button.text = "Inject Notes"
	_inject_notes_button.flat = true
	_inject_notes_button.add_theme_font_size_override("font_size", 16)
	_inject_notes_button.add_theme_color_override("font_color", Color(0.5, 0.75, 1.0, 1.0))
	_inject_notes_button.pressed.connect(_on_inject_notes_pressed)
	_planning_actions_row.add_child(_inject_notes_button)

	# Add to top of action stream's actions list
	if _action_stream._actions_list:
		_action_stream._actions_list.add_child(_planning_actions_row)
		_action_stream._actions_list.move_child(_planning_actions_row, 0)


func _on_add_context_pressed() -> void:
	"""Open a popup for the user to type additional context"""
	var session_id = _auto_promote_session_id
	if session_id.is_empty():
		session_id = _get_selected_session_id()
	if session_id.is_empty():
		SingletonObject.create_toast_notification("No active planning session", ToastNotification.Type.WARNING)
		return

	# Create popup window
	if _context_popup and is_instance_valid(_context_popup):
		_context_popup.queue_free()

	_context_popup = Window.new()
	_context_popup.title = "Add Context to Planning"
	_context_popup.size = Vector2i(500, 350)
	_context_popup.unresizable = false
	_context_popup.close_requested.connect(func(): _context_popup.hide())

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_context_popup.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var label = Label.new()
	label.text = "Enter additional context or instructions:"
	label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(label)

	_context_text_edit = TextEdit.new()
	_context_text_edit.placeholder_text = "e.g., This should be a Godot 4 project using GDScript, not a web page..."
	_context_text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_context_text_edit.add_theme_font_size_override("font_size", 15)
	vbox.add_child(_context_text_edit)

	var button_row = HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_END
	button_row.add_theme_constant_override("separation", 8)
	vbox.add_child(button_row)

	var cancel_button = Button.new()
	cancel_button.text = "Cancel"
	cancel_button.pressed.connect(func(): _context_popup.hide())
	button_row.add_child(cancel_button)

	var send_button = Button.new()
	send_button.text = "Send"
	send_button.pressed.connect(_on_context_send_pressed.bind(session_id))
	button_row.add_child(send_button)

	add_child(_context_popup)
	_context_popup.popup_centered()
	_context_text_edit.grab_focus()


func _on_context_send_pressed(session_id: String) -> void:
	"""Send the typed context to the backend"""
	if not _context_text_edit or _context_text_edit.text.strip_edges().is_empty():
		SingletonObject.create_toast_notification("Please enter some context", ToastNotification.Type.WARNING)
		return

	var content = _context_text_edit.text.strip_edges()
	_context_popup.hide()

	var autocoder_manager = SingletonObject.autocoder_manager
	if not autocoder_manager or not autocoder_manager.autocoder_adapter:
		SingletonObject.create_toast_notification("Autocoder not connected", ToastNotification.Type.WARNING)
		return

	if _action_stream:
		_action_stream.add_message("Context added:\n\n%s" % content, "user")

	SingletonObject.create_toast_notification("Injecting context...", ToastNotification.Type.INFO)
	var success = await autocoder_manager.autocoder_adapter.inject_context(session_id, content, "text")

	if success:
		SingletonObject.create_toast_notification("Context injected successfully", ToastNotification.Type.SUCCESS)
	else:
		SingletonObject.create_toast_notification("Failed to inject context", ToastNotification.Type.WARNING)


func _on_inject_notes_pressed() -> void:
	"""Inject enabled notes into the planning session"""
	var session_id = _auto_promote_session_id
	if session_id.is_empty():
		session_id = _get_selected_session_id()
	if session_id.is_empty():
		SingletonObject.create_toast_notification("No active planning session", ToastNotification.Type.WARNING)
		return

	var notes_text = _collect_enabled_notes_text()
	if notes_text.is_empty():
		SingletonObject.create_toast_notification("No enabled notes to inject", ToastNotification.Type.WARNING)
		return

	var autocoder_manager = SingletonObject.autocoder_manager
	if not autocoder_manager or not autocoder_manager.autocoder_adapter:
		SingletonObject.create_toast_notification("Autocoder not connected", ToastNotification.Type.WARNING)
		return

	if _action_stream:
		_action_stream.add_message("Notes injected into planning session", "user")

	SingletonObject.create_toast_notification("Injecting notes...", ToastNotification.Type.INFO)
	var success = await autocoder_manager.autocoder_adapter.inject_context(session_id, notes_text, "notes")

	if success:
		SingletonObject.create_toast_notification("Notes injected successfully", ToastNotification.Type.SUCCESS)
	else:
		SingletonObject.create_toast_notification("Failed to inject notes", ToastNotification.Type.WARNING)


# ============================================================================
# Notes Injection
# ============================================================================

func _collect_enabled_notes_text() -> String:
	"""Collect text content from all enabled text notes across both containers"""
	var blocks: Array[String] = []

	for container in [SingletonObject.notes_container, SingletonObject.drawer_notes_container]:
		if not container:
			continue
		for tab_idx in range(container.get_tab_count()):
			var notes = container.get_notes(tab_idx)
			for note in notes:
				if note.enabled and note.type == Note.Type.TEXT:
					var controls = note.get_controls_container()
					if controls is NoteTextControls and not controls.content.strip_edges().is_empty():
						blocks.append("### %s\n%s" % [note.title, controls.content])

	return "\n\n".join(blocks)


func _build_prompt_with_notes() -> String:
	"""Build the final prompt by injecting enabled notes before the user prompt"""
	var notes_text = _collect_enabled_notes_text()
	var prompt = _prompt_text_edit.text

	if notes_text.is_empty():
		return prompt

	return "### Reference Notes ###\n%s\n### End Reference Notes ###\n\n%s" % [notes_text, prompt]


func _disable_injected_notes() -> void:
	"""Turn off note inject switches after content has been captured into the prompt"""
	for container in [SingletonObject.notes_container, SingletonObject.drawer_notes_container]:
		if not container:
			continue
		for i in container.get_tab_count():
			container.disable_notes(i)
	SingletonObject.detached_note_proxies.map(func(proxy: Note.Proxy): (await proxy.create_note(true)).enabled = false)
	SingletonObject.detached_note_proxies.clear()


# ============================================================================
# Planning Mode Handlers
# ============================================================================

func _handle_planning_results(output: Dictionary) -> void:
	"""Handle planning results and populate kanban board"""
	var session_id = output.get("session_id", "")
	var tasks = output.get("tasks", [])
	var questions = output.get("questions", [])
	var plan_hash = output.get("plan_hash", "")
	
	if session_id.is_empty():
		push_warning("[SubmitJob] No session_id in planning results")
		return
	
	# Open or get kanban board for this session
	var kanban_editor = _get_or_create_kanban_board(session_id)
	if not kanban_editor or not kanban_editor.kanban_board:
		push_warning("[SubmitJob] Failed to get kanban board for planning results")
		return
	
	var kanban_board = kanban_editor.kanban_board
	var task_store = kanban_board.task_store
	
	# Set session_id on task store if not set
	if task_store and task_store.session_id.is_empty():
		task_store.session_id = session_id
	
	# Update backend hash for state synchronization
	if task_store and not plan_hash.is_empty():
		task_store.last_backend_hash = plan_hash
		print("[SubmitJob] Updated task_store with backend hash: %s" % plan_hash.substr(0, 8))
	
	# Populate kanban board with tasks
	_populate_kanban_from_plan(tasks, task_store)
	
	# Handle questions - remove answered ones, add new ones
	_handle_planning_questions(questions, session_id)
	
	SingletonObject.create_toast_notification("Planning complete - %d tasks created" % tasks.size(), ToastNotification.Type.SUCCESS)

func _get_kanban_board_for_session(session_id: String):
	"""Get existing kanban board for session (returns kanban_board, not Editor)"""
	if not SingletonObject.editor_pane:
		return null
	
	# Try to find existing kanban board for this session
	for editor in SingletonObject.editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				return kanban
	
	return null

func _get_or_create_kanban_board(session_id: String) -> Editor:
	"""Get existing kanban board for session or create new one"""
	if not SingletonObject.editor_pane:
		return null
	
	# Collect available models for per-task override menus
	var models_for_kanban: Array[Dictionary] = []
	for i in range(1, _model_option_button.item_count):
		var mid = str(_model_option_button.get_item_metadata(i))
		if not mid.is_empty():
			models_for_kanban.append({"id": mid, "name": _model_option_button.get_item_text(i)})

	# Try to find existing kanban board for this session
	for editor in SingletonObject.editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				kanban.available_models = models_for_kanban
				print("[SubmitJob] Found existing kanban board for session: %s" % session_id)
				return editor

	# Create new kanban board
	print("[SubmitJob] Creating new kanban board for session: %s" % session_id)
	var kanban_editor: Editor = SingletonObject.editor_pane.add(
		Editor.Type.KANBAN,
		null,
		"Planning: %s" % session_id.substr(0, 12)
	)

	if kanban_editor and kanban_editor.kanban_board:
		var kanban = kanban_editor.kanban_board
		kanban.available_models = models_for_kanban
		kanban.set_meta("session_id", session_id)
		kanban.set_meta("user_id", Core.client.client_id)
		
		# Set session_id on task store THEN load saved state
		# (must be in this order since _ready() already ran with empty session_id)
		if kanban.task_store:
			kanban.task_store.session_id = session_id
			# Now load saved state - this loads tasks from disk
			kanban.load_saved_state()
			print("[SubmitJob] Loaded saved kanban state for session: %s (tasks: %d)" % [
				session_id, kanban.task_store.get_all_tasks().size()
			])
	
	return kanban_editor

func _populate_kanban_from_plan(tasks: Array, task_store) -> void:  # task_store: AutocoderTaskStore
	"""Populate kanban board with tasks from planning"""
	if not task_store:
		return

	var AutocoderTaskClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTask.gd")

	var existing_tasks: Dictionary = {}
	for task in task_store.get_all_tasks():
		var plan_task_id = ""
		if task.metadata and task.metadata.has("plan_task_id"):
			plan_task_id = str(task.metadata.get("plan_task_id", ""))
		if plan_task_id.is_empty():
			plan_task_id = task.id
		existing_tasks[plan_task_id] = task

	for task_data in tasks:
		if not task_data is Dictionary:
			continue

		var title = task_data.get("title", "Untitled Task")
		var description = task_data.get("description", "")
		var priority = int(task_data.get("priority", 2))
		var category = task_data.get("category", "feature")
		var dependencies = task_data.get("dependencies", [])
		var complexity = task_data.get("estimated_complexity", "medium")
		var status_key = str(task_data.get("status", "plan")).to_lower()
		var status_map = {
			"plan": AutocoderTaskClass.TaskStatus.PLAN,
			"in_progress": AutocoderTaskClass.TaskStatus.IN_PROGRESS,
			"review": AutocoderTaskClass.TaskStatus.AI_REVIEW,
			"in_review": AutocoderTaskClass.TaskStatus.AI_REVIEW,
			"ai_review": AutocoderTaskClass.TaskStatus.AI_REVIEW,
			"human_review": AutocoderTaskClass.TaskStatus.HUMAN_REVIEW,
			"awaiting_user": AutocoderTaskClass.TaskStatus.HUMAN_REVIEW,
			"done": AutocoderTaskClass.TaskStatus.DONE,
			"complete": AutocoderTaskClass.TaskStatus.DONE
		}
		var mapped_status = status_map.get(status_key, AutocoderTaskClass.TaskStatus.PLAN)
		var plan_task_id = str(task_data.get("id", ""))
		var metadata = {
			"plan_task_id": plan_task_id,
			"dependencies": dependencies,
			"estimated_complexity": complexity,
			"category": category
		}

		if existing_tasks.has(plan_task_id):
			var existing_task = existing_tasks[plan_task_id]
			task_store.update_task(existing_task.id, {
				"title": title,
				"description": description,
				"priority": priority,
				"status": mapped_status,
				"metadata": metadata,
				"source_context": "Planning: %s" % category
			})
			continue

		# Create task in mapped status
		var task = task_store.create_task(
			title,
			description,
			mapped_status,
			"",  # model
			priority,
			AutocoderTaskClass.SourceType.AUTOCODER,
			"",  # source_uuid
			"Planning: %s" % category
		)
		
		# Store metadata (including plan_task_id to prevent duplicates on updates)
		task.metadata = metadata

		print("[SubmitJob] Created planning task: %s (priority: %d)" % [title, priority])

func _handle_planning_questions(questions: Array, session_id: String) -> void:
	"""Handle planning questions - remove answered ones, add new ones.
	This is the SINGLE source of truth for question handling to prevent duplication."""
	if not _action_stream:
		return
	
	# Get current question IDs from action stream
	var current_question_ids: Array[String] = []
	if _action_stream._question_cards:
		for question_id in _action_stream._question_cards.keys():
			current_question_ids.append(question_id)
	
	# Get active question IDs from backend (not answered, not already submitted locally)
	var active_question_ids: Array[String] = []
	for question_data in questions:
		if question_data is Dictionary:
			var question_id = str(question_data.get("id", ""))
			var answered = question_data.get("answered", false)
			# Also check if we've already submitted this question locally
			var locally_submitted = _submitted_questions.has(question_id)
			if not question_id.is_empty() and not answered and not locally_submitted:
				active_question_ids.append(question_id)
	
	# Remove questions that are no longer active (answered, removed, or submitted locally)
	for question_id in current_question_ids:
		if question_id not in active_question_ids:
			print("[SubmitJob] Removing answered/submitted question: %s" % question_id)
			if _action_stream._question_cards.has(question_id):
				var card = _action_stream._question_cards[question_id]
				if card and is_instance_valid(card):
					card.queue_free()
				_action_stream._question_cards.erase(question_id)
	
	# Add new questions (only if not already present AND not already submitted)
	for question_data in questions:
		if not question_data is Dictionary:
			continue
		var question_id = str(question_data.get("id", ""))
		var question_text = str(question_data.get("question", ""))
		var options = question_data.get("options", [])
		var answered = question_data.get("answered", false)
		
		# Skip if answered by backend, already submitted locally, or already displayed
		if answered or _submitted_questions.has(question_id):
			continue
		
		if not question_id.is_empty() and not question_text.is_empty():
			# Only add if not already present in action stream
			if not _action_stream._question_cards.has(question_id):
				print("[SubmitJob] Adding new question: %s" % question_id)
				add_question(question_id, question_text, options, session_id)
			else:
				# Update existing question if needed (and not already submitted)
				var existing_card = _action_stream._question_cards.get(question_id)
				if existing_card and is_instance_valid(existing_card) and not existing_card.has_meta("submitted"):
					existing_card.setup(question_id, question_text, options, session_id)
	
	# Show notification if there are unanswered required questions
	var unanswered_required = []
	for q in questions:
		if q is Dictionary:
			var qid = str(q.get("id", ""))
			var required = q.get("required", false)
			var answered = q.get("answered", false)
			if required and not answered and not _submitted_questions.has(qid):
				unanswered_required.append(q)

	if unanswered_required.size() > 0:
		SingletonObject.create_toast_notification(
			"Planning has %d required question(s) - please answer them" % unanswered_required.size(),
			ToastNotification.Type.INFO
		)


# =============================================================================
# OpenRouter Model Management
# =============================================================================

func _update_user_model_status() -> void:
	if not _model_management_status_label:
		return
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		_model_management_status_label.text = ""
		return
	var user_models = await SingletonObject.autocoder_manager.autocoder_adapter.get_user_models()
	_user_selected_models = []
	for m in user_models:
		if m is Dictionary:
			_user_selected_models.append(m)
	if _user_selected_models.size() > 0:
		_model_management_status_label.text = "%d custom model(s) saved" % _user_selected_models.size()
	else:
		_model_management_status_label.text = ""


func _on_browse_models_pressed() -> void:
	var api_key: String = SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENROUTER)
	if api_key.strip_edges().is_empty():
		SingletonObject.ErrorDisplay("No API Key", "Set your OpenRouter API key in Preferences > API Keys first.")
		return
	_show_model_browse_dialog(api_key)


func _on_clear_user_models_pressed() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return
	_clear_user_models_button.disabled = true
	var success = await SingletonObject.autocoder_manager.autocoder_adapter.clear_user_models()
	_clear_user_models_button.disabled = false
	if success:
		_user_selected_models.clear()
		SingletonObject.create_toast_notification("Custom models cleared")
		_refresh_models()
	else:
		SingletonObject.create_toast_notification("Failed to clear custom models", ToastNotification.Type.ERROR)


func _show_model_browse_dialog(api_key: String) -> void:
	var win := Window.new()
	win.title = "Browse OpenRouter Models"
	var scale: float = get_tree().root.content_scale_factor
	win.content_scale_factor = scale
	win.size = Vector2i(Vector2(620, 560) * scale)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.anchors_preset = Control.PRESET_FULL_RECT
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Search bar
	var search_hbox := HBoxContainer.new()
	var search_edit := LineEdit.new()
	search_edit.placeholder_text = "Search models..."
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_hbox.add_child(search_edit)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	search_hbox.add_child(refresh_btn)
	vbox.add_child(search_hbox)

	# Model list
	var item_list := ItemList.new()
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_list.allow_reselect = true
	vbox.add_child(item_list)

	# Details label
	var details_label := Label.new()
	details_label.text = "Select a model to see details."
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_label.custom_minimum_size.y = 48
	vbox.add_child(details_label)

	# Status label
	var status_label := Label.new()
	status_label.text = "Loading models..."
	status_label.modulate.a = 0.6
	vbox.add_child(status_label)

	# Buttons
	var btn_hbox := HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_END
	btn_hbox.add_theme_constant_override("separation", 8)
	var cancel_btn := Button.new()
	cancel_btn.text = "Close"
	cancel_btn.pressed.connect(func(): win.queue_free())
	btn_hbox.add_child(cancel_btn)
	var add_btn := Button.new()
	add_btn.text = "Add Selected"
	add_btn.disabled = true
	btn_hbox.add_child(add_btn)
	vbox.add_child(btn_hbox)

	add_child(win)
	win.popup_centered()

	# Store fetched models
	var all_models: Array = []
	var models_added_this_session: Array = []

	# Filter function
	var _filter_list := func(search_text: String):
		item_list.clear()
		var query := search_text.strip_edges().to_lower()
		for i in range(all_models.size()):
			var m: Dictionary = all_models[i]
			var name_: String = m.get("display_name", "")
			var id_: String = m.get("api_model_id", "")
			if query.is_empty() or query in name_.to_lower() or query in id_.to_lower():
				var cost_str := "$%.2f/$%.2f" % [m.get("input_token_cost", 0.0), m.get("output_token_cost", 0.0)]
				item_list.add_item("%s  %s" % [name_, cost_str])
				item_list.set_item_metadata(item_list.get_item_count() - 1, i)

	# Selection handler
	item_list.item_selected.connect(func(idx: int):
		var model_idx: int = item_list.get_item_metadata(idx)
		var m: Dictionary = all_models[model_idx]
		details_label.text = "%s\nID: %s\nCost: $%.2f in / $%.2f out per M tokens" % [
			m.get("display_name", ""),
			m.get("api_model_id", ""),
			m.get("input_token_cost", 0.0),
			m.get("output_token_cost", 0.0),
		]
		if m.get("context_length", 0) > 0:
			details_label.text += "\nContext: %dk" % (m["context_length"] / 1000)
		add_btn.disabled = false
	)

	# Add button handler — supports multi-add without closing
	add_btn.pressed.connect(func():
		var selected := item_list.get_selected_items()
		if selected.is_empty():
			return
		var model_idx: int = item_list.get_item_metadata(selected[0])
		var m: Dictionary = all_models[model_idx]
		var model_id: String = m.get("api_model_id", "")
		var model_name: String = m.get("display_name", model_id)

		# Check if already in user models
		for um in _user_selected_models:
			if um.get("id") == model_id:
				status_label.text = "Model already added: %s" % model_name
				return

		# Check if already added this session
		for am in models_added_this_session:
			if am.get("id") == model_id:
				status_label.text = "Model already added: %s" % model_name
				return

		models_added_this_session.append({"id": model_id, "name": model_name})
		status_label.text = "Added: %s (%d new this session)" % [model_name, models_added_this_session.size()]
	)

	# On window close, save all newly added models
	win.tree_exiting.connect(func():
		if models_added_this_session.is_empty():
			return
		# Merge with existing user models
		var merged: Array = _user_selected_models.duplicate()
		var existing_ids: Dictionary = {}
		for um in merged:
			existing_ids[um.get("id", "")] = true
		for am in models_added_this_session:
			if not existing_ids.has(am.get("id", "")):
				merged.append(am)
		_user_selected_models = merged
		_save_user_models()
	)

	# Search filter
	search_edit.text_changed.connect(func(text: String): _filter_list.call(text))

	# Fetch models
	refresh_btn.pressed.connect(func(): _fetch_openrouter_models(api_key, status_label, add_btn, all_models, _filter_list, search_edit))
	_fetch_openrouter_models(api_key, status_label, add_btn, all_models, _filter_list, search_edit)


func _save_user_models() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return
	var success = await SingletonObject.autocoder_manager.autocoder_adapter.save_user_models(_user_selected_models)
	if success:
		SingletonObject.create_toast_notification("%d custom model(s) saved" % _user_selected_models.size())
		_refresh_models()
	else:
		SingletonObject.create_toast_notification("Failed to save custom models", ToastNotification.Type.ERROR)


func _fetch_openrouter_models(api_key: String, status_label: Label, add_btn: Button, all_models: Array, filter_fn: Callable, search_edit: LineEdit) -> void:
	status_label.text = "Loading models..."
	add_btn.disabled = true
	var fetched = await SingletonObject.openrouter_model_manager.fetch_api_models(api_key)
	all_models.clear()
	all_models.append_array(fetched)
	if all_models.is_empty():
		status_label.text = "No models found or API error."
	else:
		status_label.text = "%d models available" % all_models.size()
		filter_fn.call(search_edit.text)
