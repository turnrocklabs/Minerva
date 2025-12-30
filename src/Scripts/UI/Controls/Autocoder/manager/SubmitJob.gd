class_name AutocoderSubmitJobManager
extends VBoxContainer

@onready var _artifact_browser_popup: PersistentWindow = %ArtifactBrowserPopup
@onready var _artifact_browser: ArtifactBrowser = %ArtifactBrowser

@onready var _input_resources_container: Container = %InputResourcesContainer

@onready var _selected_artifact_name_label: Label = %SelectedArtifactNameLabel
@onready var _selected_artifact_uri_label: Label = %SelectedArtifactURILabel

@onready var _prompt_text_edit: TextEdit = %PromptTextEdit

@onready var _session_option_button: OptionButton = %SessionOptionButton

@onready var _session_history_container: Container = %SessionHistoryContainer

var _session_history_browser: SessionHistoryBrowser

var selected_artifact: Artifact = null:
	set(value):
		selected_artifact = value

		_input_resources_container.visible = selected_artifact != null

		if selected_artifact:
			_selected_artifact_name_label.text = selected_artifact.filename
			_selected_artifact_uri_label.text = selected_artifact.artifact_uri

## The local source directory path associated with the selected artifact (if created from local files)
var _pending_source_dir: String = ""


func _ready() -> void:
	# Create and setup session history browser
	_session_history_browser = SessionHistoryBrowser.new()
	_session_history_browser.session_view_requested.connect(_on_session_view_requested)
	_session_history_browser.session_resume_requested.connect(_on_session_resume_requested)

	if _session_history_container:
		_session_history_container.add_child(_session_history_browser)

	# Load initial session history when connected (use call_deferred to support await)
	if SingletonObject.autocoder_manager and SingletonObject.autocoder_manager.autocoder_adapter:
		_refresh_session_history.call_deferred()


func _refresh_session_history() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		return

	_session_history_browser.show_loading()
	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()
	_session_history_browser.set_sessions(sessions)


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
	_session_option_button.disabled = not toggled_on


func _on_submit_job_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.ErrorDisplay("Can't start", "Please connect to core first!")
		return

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
	var output: = await SingletonObject.autocoder_manager.autocoder_adapter.generate(
		_prompt_text_edit.text,
		"", # no session - new generation
		selected_artifact.artifact_uri if selected_artifact else ""
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
