class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
@onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

@onready var _input_resources_container: Container = %InputResourcesCard
@onready var _clear_resources_button: Button = $VSplitContainer/TopSection/ScrollContainer/MainMargin/MainVBox/MainInputCard/CardMargin/CardContent/ResourceRow/ClearInputResourcesButton

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

## The local source directory path associated with the selected artifact (if created from local files)
var _pending_source_dir: String = ""


func _ready() -> void:
	# Create and setup session history browser
	_session_history_browser = SessionHistoryBrowser.new()
	_session_history_browser.session_view_requested.connect(_on_session_view_requested)
	_session_history_browser.session_resume_requested.connect(_on_session_resume_requested)

	if _session_history_container:
		_session_history_container.add_child(_session_history_browser)

	_populate_models([])
	_populate_review_agents([])
	
	# Connect mode selector
	if _mode_option_button:
		_mode_option_button.item_selected.connect(_on_mode_selected)
		_mode_option_button.select(AutocoderMode.CODER)  # Default to Coder
		current_mode = AutocoderMode.CODER
	
	# Update review agents visibility based on mode (not auto-review checkbox)
	_update_review_agents_for_mode()

	# Load initial data when connected (use call_deferred to support await)
	if SingletonObject.autocoder_manager and SingletonObject.autocoder_manager.autocoder_adapter:
		_refresh_session_history.call_deferred()
		_refresh_models.call_deferred()
		_refresh_review_agents.call_deferred()

	if Core and Core.client:
		if not Core.client.connection_established.is_connected(_on_core_connected):
			Core.client.connection_established.connect(_on_core_connected)

	_auto_review_check_box.toggled.connect(_on_auto_review_toggled)
	_review_agents_refresh_button.pressed.connect(_on_review_agents_refresh_pressed)
	_review_agents_clear_button.pressed.connect(_on_review_agents_clear_pressed)

	if _new_session_check_box and not _new_session_check_box.toggled.is_connected(_on_new_session_toggled):
		_new_session_check_box.toggled.connect(_on_new_session_toggled)


func _on_core_connected() -> void:
	_refresh_session_history.call_deferred()
	_refresh_models.call_deferred()
	_refresh_review_agents.call_deferred()


func _refresh_session_history() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return

	_session_history_browser.show_loading()
	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()
	_session_history_browser.set_sessions(sessions)
	_populate_session_options(sessions)


func _refresh_models() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		_populate_models([])
		return

	_model_option_button.disabled = true
	_model_option_button.clear()
	_model_option_button.add_item("Loading models...")

	var models = await SingletonObject.autocoder_manager.autocoder_adapter.list_generation_models()
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
		var name = str(agent.get("name", "Unnamed Agent"))
		var model = str(agent.get("model", ""))
		var tools_enabled = bool(agent.get("tools_enabled", false))
		var tools_tag = " 🛠" if tools_enabled else ""
		var label = "🔍 %s%s" % [name, tools_tag]
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
	_session_option_button.clear()
	_session_option_button.add_item("Select a session")
	_session_option_button.set_item_metadata(0, "")

	var active_statuses = PackedStringArray(["processing", "active", "in_review", "awaiting_user"])
	var index = 1
	for session in sessions:
		if not (session is Dictionary):
			continue
		var session_id = str(session.get("session_id", ""))
		if session_id.is_empty():
			continue
		var status = str(session.get("status", "")).to_lower()
		if status not in active_statuses:
			continue
		var updated_at = str(session.get("updated_at", session.get("created_at", "")))
		var label = "%s %s (%s)" % [_status_emoji(status), session_id, _format_timestamp(updated_at)]
		_session_option_button.add_item(label)
		_session_option_button.set_item_metadata(index, session_id)
		index += 1

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

	# Use the current client_id as user_id (no need to fetch session history)
	var user_id = Core.client.client_id

	# Monitor the session (this will open a log viewer)
	SingletonObject.autocoder_manager.monitor_session(user_id, session_id)


func _on_session_resume_requested(session_id: String) -> void:
	# For now, just open the session viewer so user can see the status
	# In the future, we could add a UI to enter revision feedback
	var user_id = Core.client.client_id
	SingletonObject.autocoder_manager.monitor_session(user_id, session_id)

	SingletonObject.create_toast_notification(
		"Session opened. Use the log viewer to provide feedback for revisions.",
		ToastNotification.Type.INFO
	)


func _on_select_package_button_pressed() -> void:

	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't fetch", "Please connect to core first!")
		return

	var artifacts: = await SingletonObject.autocoder_manager.artifact_registry_adapter.search()
	_artifact_browser.set_artifacts(artifacts)

	_artifact_browser_popup.size = DisplayServer.screen_get_size() * 0.9
	_artifact_browser_popup.popup_centered()


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

func _on_create_package_button_pressed() -> void:
	var editor: = SingletonObject.editor_pane.add(Editor.Type.PACKAGE)

	# Capture source directory when user selects a folder
	editor.package_editor.directory_selected.connect(
		func(path: String):
			_pending_source_dir = path
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
		# Step 1: Clean workspace before starting new generation
		SingletonObject.create_toast_notification("Preparing workspace...", ToastNotification.Type.INFO)

		var cleanup_success = await SingletonObject.autocoder_manager.autocoder_adapter.cleanup(true)

		if not cleanup_success:
			SingletonObject.ErrorDisplay("Cleanup Failed", "Failed to clean workspace. Cannot start generation.")
			return

	# Step 2: Pre-create session ID and subscribe BEFORE sending generate request
	# This ensures we don't miss any notifications
	var user_id = Core.client.client_id

	# We need to wait for the session_id from the response, so we'll subscribe after
	# but we'll pre-open the log viewer to prepare for monitoring
	SingletonObject.create_toast_notification("Starting code generation...", ToastNotification.Type.INFO)

	# Step 3: Start generation (this returns immediately with acknowledgment)
	var model_id = _get_selected_model_id()
	var require_permission = _require_permission_check_box.button_pressed
	var review_agent_ids: Array = []
	if _auto_review_check_box.button_pressed:
		review_agent_ids = _get_selected_review_agent_ids()
	var output: = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
		_prompt_text_edit.text,
		session_id,
		selected_artifact.artifact_uri if selected_artifact else "",
		require_permission,
		model_id,
		review_agent_ids
	)

	if not output:
		return

	SingletonObject.create_toast_notification(output.message, ToastNotification.Type.SUCCESS)

	# Step 4: Save source directory association if we have one
	if not _pending_source_dir.is_empty():
		SingletonObject.save_session_source_dir(output.session_id, _pending_source_dir)
		_pending_source_dir = ""  # Clear for next submission

	# Step 5: Now monitor session - this will subscribe and open the log viewer
	# Subscriptions happen inside monitor_session to catch all notifications
	SingletonObject.autocoder_manager.monitor_session(
		output.user_id,
		output.session_id,
		output.notification_topics
	)

	# Step 6: Refresh session history to show the new session
	_refresh_session_history()


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

func add_question(question_id: String, question_text: String, options: Array = []) -> void:
	if _action_stream:
		_action_stream.add_question(question_id, question_text, options)

func clear_action_stream() -> void:
	if _action_stream:
		_action_stream.clear()
