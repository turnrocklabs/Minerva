class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
@onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

@warning_ignore("unused_variable")
@onready var _input_resources_container: Container = %InputResourcesCard
@onready var _clear_resources_button: Button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/ResourceRow/ClearInputResourcesButton
@onready var _attach_folder_button: Button = %AttachFolderButton
@onready var _set_source_folder_button: Button = %SetSourceFolderButton
@onready var _download_latest_button: Button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/ResourceRow/DownloadLatestButton
@onready var _extract_latest_button: Button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/ResourceRow/ExtractLatestButton
@onready var _download_patch_button: Button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/ResourceRow/DownloadPatchButton

@onready var _selected_artifact_name_label: Label = %SelectedArtifactNameLabel
@onready var _selected_artifact_uri_label: Label = %SelectedArtifactURILabel

@onready var _prompt_text_edit: TextEdit = %PromptTextEdit

@onready var _model_option_button: OptionButton = %ModelOptionButton

@onready var _auto_review_check_box: CheckBox = %AutoReviewCheckBox
@onready var _require_permission_check_box: CheckBox = %RequirePermissionCheckBox
@onready var _review_agents_panel: PanelContainer = %ReviewAgentsCard
@onready var _review_agents_refresh_button: Button = %ReviewAgentsRefreshButton
@onready var _review_agents_list: ItemList = %ReviewAgentsList
@onready var _review_agents_empty_label: Label = %ReviewAgentsEmptyLabel
@onready var _review_agents_clear_button: Button = %ReviewAgentsClearButton

@onready var _session_option_button: OptionButton = %SessionOptionButton
@onready var _new_session_check_box: CheckBox = %NewSessionCheckBox
@onready var _continue_session_check_box: CheckBox = %ContinueSessionCheckBox
@onready var _mode_option_button: OptionButton = %ModeOptionButton

enum AutocoderMode {
	PLAN = 0,
	CODER = 1,
	REVIEW = 2
}

var current_mode: AutocoderMode = AutocoderMode.CODER

@onready var _session_history_container: Container = %SessionHistoryContainer

@onready var _action_stream: AutocoderActionStream = %ActionStream

var _session_history_browser: SessionHistoryBrowser

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


func _ready() -> void:
	SingletonObject.load_config_file()
	# Create and setup session history browser
	_session_history_browser = SessionHistoryBrowser.new()
	_session_history_browser.session_view_requested.connect(_on_session_view_requested)
	_session_history_browser.session_resume_requested.connect(_on_session_resume_requested)

	if _session_history_container:
		_session_history_container.add_child(_session_history_browser)

	_populate_models([])
	_populate_review_agents([])
	
	# Connect action stream question answers
	if _action_stream:
		_action_stream.question_answered.connect(_on_question_answered)
	
	# Connect mode selector
	if _mode_option_button:
		_mode_option_button.item_selected.connect(_on_mode_selected)
		_mode_option_button.select(AutocoderMode.PLAN)  # Default to Plan mode
		current_mode = AutocoderMode.PLAN
	
	# Update review agents visibility based on mode (not auto-review checkbox)
	_update_review_agents_for_mode()

	# Note: Session loading and model loading are now handled by AutocoderManager
	# calling _refresh_session_history() and _refresh_models() after the autocoder_adapter is ready.
	# No need to connect to Core directly or attempt early loading.
	
	# Review agents can still be loaded on demand
	_refresh_review_agents.call_deferred()

	_auto_review_check_box.toggled.connect(_on_auto_review_toggled)
	_review_agents_refresh_button.pressed.connect(_on_review_agents_refresh_pressed)
	_review_agents_clear_button.pressed.connect(_on_review_agents_clear_pressed)

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

	if _new_session_check_box and not _new_session_check_box.toggled.is_connected(_on_new_session_toggled):
		_new_session_check_box.toggled.connect(_on_new_session_toggled)
	if _session_option_button and not _session_option_button.item_selected.is_connected(_on_session_option_selected):
		_session_option_button.item_selected.connect(_on_session_option_selected)




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


func _refresh_review_agents() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		_populate_review_agents([])
		return

	_review_agents_refresh_button.disabled = true
	_review_agents_list.clear()
	_review_agents_list.add_item("Loading review agents...")
	_review_agents_list.set_item_disabled(0, true)

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


func _populate_review_agents(agents: Array[Dictionary]) -> void:
	_review_agents_list.clear()
	_review_agents_empty_label.visible = false

	if agents.is_empty():
		_review_agents_empty_label.visible = true
		return

	_review_agents_list.select_mode = ItemList.SELECT_MULTI

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
		var tools_tag = " 🛠" if tools_enabled else ""
		var label = "🔍 %s%s" % [name_, tools_tag]
		if not model.is_empty():
			label = "%s (%s)" % [label, model]

		var index = _review_agents_list.item_count
		_review_agents_list.add_item(label)
		_review_agents_list.set_item_metadata(index, agent_id)


func _set_review_agents_enabled(enabled: bool) -> void:
	_review_agents_panel.visible = enabled


func _on_mode_selected(index: int) -> void:
	current_mode = index as AutocoderMode
	_update_review_agents_for_mode()
	_update_submit_button_text()


func _update_review_agents_for_mode() -> void:
	# Show review agents for Coder and Review modes, hide for Plan
	var show_agents = current_mode != AutocoderMode.PLAN
	_review_agents_panel.visible = show_agents
	
	# Also show/hide auto-review checkbox (only relevant in Coder mode)
	if _auto_review_check_box:
		_auto_review_check_box.visible = current_mode == AutocoderMode.CODER


func _update_submit_button_text() -> void:
	var submit_button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/SubmitJobButton
	if not submit_button:
		return
	
	var is_new_session = _new_session_check_box.button_pressed
	
	match current_mode:
		AutocoderMode.PLAN:
			submit_button.text = "Start Planning" if is_new_session else "Continue Planning"
		AutocoderMode.CODER:
			submit_button.text = "Generate Code" if is_new_session else "Continue Coding"
		AutocoderMode.REVIEW:
			submit_button.text = "Run Review"


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
	for index in _review_agents_list.get_selected_items():
		var meta = _review_agents_list.get_item_metadata(index)
		if meta != null:
			var agent_id = str(meta)
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
	_update_submit_button_text()


func _on_new_session_toggled(_toggled_on: bool) -> void:
	_session_option_button.disabled = not _continue_session_check_box.button_pressed or _session_option_button.item_count <= 1
	_update_submit_button_text()


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


func _on_auto_review_toggled(toggled_on: bool) -> void:
	# In Coder mode, auto-review controls whether agents are selected automatically
	# But review agents panel visibility is controlled by mode, not this checkbox
	if current_mode == AutocoderMode.CODER and toggled_on and _review_agents_list.item_count == 0:
		_refresh_review_agents()


func _on_review_agents_refresh_pressed() -> void:
	_refresh_review_agents()


func _on_review_agents_clear_pressed() -> void:
	for index in _review_agents_list.get_selected_items():
		_review_agents_list.deselect(index)


func _on_submit_job_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.ErrorDisplay("Can't start", "Please connect to core first!")
		return

	var session_id = ""
	if _continue_session_check_box.button_pressed:
		session_id = _get_selected_session_id()
		if session_id.is_empty():
			SingletonObject.ErrorDisplay("Continue Session", "Select a session to continue.")
			return
	else:
		# Step 1: Clean workspace before starting new generation (skip for planning mode)
		if current_mode != AutocoderMode.PLAN:
			SingletonObject.create_toast_notification("Preparing workspace...", ToastNotification.Type.INFO)

			var cleanup_success = await SingletonObject.autocoder_manager.autocoder_adapter.cleanup(true)

			if not cleanup_success:
				SingletonObject.ErrorDisplay("Cleanup Failed", "Failed to clean workspace. Cannot start generation.")
				return

	# Step 2: Check for concurrent requests on same session
	if not session_id.is_empty() and _processing_sessions.get(session_id, false):
		SingletonObject.create_toast_notification(
			"Session is already processing a request. Please wait.",
			ToastNotification.Type.WARNING
		)
		return
	
	# Mark session as processing
	if not session_id.is_empty():
		_processing_sessions[session_id] = true
	
	# Step 3: Pre-create session ID and subscribe BEFORE sending generate request
	# This ensures we don't miss any notifications
	var user_id = Core.client.client_id

	# We need to wait for the session_id from the response, so we'll subscribe after
	# but we'll pre-open the log viewer to prepare for monitoring
	var starting_message = "Starting planning..." if current_mode == AutocoderMode.PLAN else "Starting code generation..."
	SingletonObject.create_toast_notification(starting_message, ToastNotification.Type.INFO)
	
	# Disable prompt while processing
	_set_prompt_enabled(false)

	# Step 4: Start generation or planning based on mode
	var model_id = _get_selected_model_id()
	var require_permission = _require_permission_check_box.button_pressed
	# Always get selected review agents if any are selected (user intent)
	var review_agent_ids: Array = _get_selected_review_agent_ids()
	# Run reviews if auto_review is checked OR agents are explicitly selected OR in review mode
	var auto_review = _auto_review_check_box.button_pressed or not review_agent_ids.is_empty() or current_mode == AutocoderMode.REVIEW
	
	print("[SubmitJob] auto_review=%s, review_agent_ids=%s" % [auto_review, review_agent_ids])
	
	var output: Variant = null
	
	match current_mode:
		AutocoderMode.PLAN:
			# Planning mode - add progress indicator
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
				_prompt_text_edit.text,
				session_id,
				selected_artifact.artifact_uri if selected_artifact else "",
				model_id,
				"",  # modify_request - empty for new planning
				kanban_state,
				kanban_hash
			)
			if planning_output:
				var task_count = planning_output.tasks.size()
				print("[SubmitJob] Planning completed with %d tasks" % task_count)
				
				# Update progress indicator as complete
				if task_count > 0:
					update_tool_call(planning_action_id, "completed", "Plan generated with %d tasks" % task_count)
				else:
					# Tasks will come via notification topic, initial response may be empty
					update_tool_call(planning_action_id, "completed", "Planning in progress - tasks will appear shortly...")
				
				output = {
					"session_id": planning_output.session_id,
					"message": planning_output.message,
					"notification_topics": planning_output.notification_topics,
					"status": planning_output.status,
					"user_id": planning_output.user_id,
					"iteration": 0.0,
					"tasks": planning_output.tasks,
					"questions": planning_output.questions
				}
			else:
				# Update progress indicator as failed
				update_tool_call(planning_action_id, "failed", "Planning failed - check logs for details")
		AutocoderMode.CODER:
			# Code generation mode
			# CRITICAL: Set up handlers BEFORE calling generate so we can receive
			# planning notifications (task status updates) during the long-running call
			if not session_id.is_empty():
				print("[SubmitJob] Setting up session monitoring BEFORE generate call...")
				# This sets up ALL handlers (planning, actions, LLM traffic, etc.)
				SingletonObject.autocoder_manager.monitor_session(user_id, session_id)
				# Also ensure kanban board exists
				_get_or_create_kanban_board(session_id)
			
			output = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
				_prompt_text_edit.text,
				session_id,
				selected_artifact.artifact_uri if selected_artifact else "",
				require_permission,
				model_id,
				review_agent_ids,
				not session_id.is_empty(),  # use_plan_tasks when continuing a session
				[],
				auto_review
			)
		AutocoderMode.REVIEW:
			# Review mode - use generate but with review flag
			output = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
				_prompt_text_edit.text,
				session_id,
				selected_artifact.artifact_uri if selected_artifact else "",
				require_permission,
				model_id,
				review_agent_ids,
				false,
				[],
				auto_review
			)

	if not output:
		# Release processing flag on error
		if not session_id.is_empty():
			_processing_sessions[session_id] = false
			print("[SubmitJob] Released processing lock after error for session: %s" % session_id)
		# Re-enable prompt input even on error (so user can retry)
		_set_prompt_enabled(true)
		return

	SingletonObject.create_toast_notification(output.message, ToastNotification.Type.SUCCESS)

	# Determine effective session_id - when continuing a session, prefer the ORIGINAL session_id
	# to keep the kanban board consistent. The backend may return a different session_id.
	var effective_session_id = session_id if not session_id.is_empty() else output.session_id
	
	if not session_id.is_empty() and output.session_id != session_id:
		print("[SubmitJob] WARNING: Backend returned different session_id. Original: %s, Returned: %s" % [session_id, output.session_id])
		print("[SubmitJob] Using original session_id for tracking: %s" % session_id)
	
	# Step 4: Handle planning mode - populate kanban board
	if current_mode == AutocoderMode.PLAN and output.has("tasks"):
		_handle_planning_results(output)
	
	# Step 5: Save source directory association if we have one
	if not _pending_source_dir.is_empty():
		_save_source_dir_for_session(effective_session_id, _pending_source_dir)
		_pending_source_dir = ""  # Clear for next submission
	
	# Ensure session is monitored (may already be set up for CODER mode)
	# monitor_session checks _monitoring_sessions to avoid duplicates
	if not SingletonObject.autocoder_manager._monitoring_sessions.has(effective_session_id):
		SingletonObject.autocoder_manager.monitor_session(
			output.user_id,
			effective_session_id,
			output.notification_topics
		)

	# Step 7: Refresh session dropdown to show the new session
	await _refresh_session_history()
	
	# Step 8: Select this session in the dropdown (without reloading history - we just started it)
	_ensure_session_option(effective_session_id, output.status)
	_select_session_in_dropdown(effective_session_id)
	
	# Release processing flag
	if not effective_session_id.is_empty():
		_processing_sessions[effective_session_id] = false
		print("[SubmitJob] Released processing lock for session: %s" % effective_session_id)
	
	# Re-enable prompt input after job completes (for follow-up prompts)
	_set_prompt_enabled(true)
	_prompt_text_edit.text = ""  # Clear the prompt for next input


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
	
	# Forward to autocoder adapter (await it since it's async)
	var success = await autocoder_manager.autocoder_adapter.answer_question(resolved_session_id, question_id, answer)
	
	print("[SubmitJob] Answer submission result: %s" % ("SUCCESS" if success else "FAILED"))
	
	if success:
		# Show visual feedback that planning is continuing
		_action_stream.add_llm_progress("Continuing planning with your answers...")
		
		# Disable prompt while processing
		_set_prompt_enabled(false)
		
		SingletonObject.create_toast_notification(
			"Answer submitted - refining plan based on your input...",
			ToastNotification.Type.INFO
		)
		print("[SubmitJob] Now waiting for planning notification on topic: autocoder-orchestrator/planning/%s/%s" % [Core.client.client_id, resolved_session_id])
	else:
		SingletonObject.create_toast_notification(
			"Answer submission failed - please retry if needed",
			ToastNotification.Type.WARNING
		)

func clear_action_stream() -> void:
	if _action_stream:
		_action_stream.clear()

func on_planning_turn_complete(session_id: String, planning_status: String) -> void:
	"""Called when a planning turn completes (from AutocoderManager)"""
	print("[SubmitJob] Planning turn complete for session %s (status: %s)" % [session_id, planning_status])
	
	# Stop LLM progress animations
	if _action_stream:
		_action_stream.stop_llm_progress()
	_submitted_questions.clear()
	
	# Re-enable prompt for follow-up questions or modifications
	_set_prompt_enabled(true)
	
	match planning_status:
		"complete":
			# Add planning complete message DIRECTLY to action stream (don't reload history)
			if _action_stream:
				_action_stream.add_message("✓ Planning Complete\n\nPlan ready - switch to Coder mode to implement", "system")
			
			SingletonObject.create_toast_notification(
				"✓ Planning complete! You can now:\n• Modify the plan\n• Add more tasks\n• Switch to Coder mode to implement",
				ToastNotification.Type.SUCCESS
			)
			# Auto-switch to Coder mode for the same session (user can add prompt and run)
			if current_mode == AutocoderMode.PLAN:
				if _mode_option_button:
					_mode_option_button.select(AutocoderMode.CODER)
					_on_mode_selected(AutocoderMode.CODER)
				# Use _select_session_in_dropdown instead of _auto_select_session
				# to avoid reloading history and causing incorrect ordering
				_select_session_in_dropdown(session_id)
				SingletonObject.create_toast_notification(
					"Coder mode ready - add instructions and click Generate Code",
					ToastNotification.Type.INFO
				)
		"awaiting_answers":
			SingletonObject.create_toast_notification(
				"⏸ Planning paused - answer questions to continue",
				ToastNotification.Type.INFO
			)
	
	# Update button text
	_update_submit_button_text()

func _set_prompt_enabled(enabled: bool) -> void:
	"""Enable or disable the prompt input"""
	if _prompt_text_edit:
		_prompt_text_edit.editable = enabled
		if enabled:
			_prompt_text_edit.placeholder_text = "Enter additional instructions, modifications, or questions..."
		else:
			_prompt_text_edit.placeholder_text = "Processing..."

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
	
	# Try to find existing kanban board for this session
	for editor in SingletonObject.editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
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

func _populate_kanban_from_plan(tasks: Array, task_store: AutocoderTaskStore) -> void:
	"""Populate kanban board with tasks from planning"""
	if not task_store:
		return

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
			"plan": AutocoderTask.TaskStatus.PLAN,
			"in_progress": AutocoderTask.TaskStatus.IN_PROGRESS,
			"review": AutocoderTask.TaskStatus.HUMAN_REVIEW,
			"ai_review": AutocoderTask.TaskStatus.AI_REVIEW,
			"human_review": AutocoderTask.TaskStatus.HUMAN_REVIEW,
			"done": AutocoderTask.TaskStatus.DONE,
			"complete": AutocoderTask.TaskStatus.DONE
		}
		var mapped_status = status_map.get(status_key, AutocoderTask.TaskStatus.PLAN)
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
			AutocoderTask.SourceType.AUTOCODER,
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
