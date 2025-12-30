class_name AutocodeManager
extends VBoxContainer


var artifact_registry_adapter: ArtifactRegistryAdapter
var autocoder_adapter: AutocoderAdapter
var submit_job_manager: AutocoderSubmitJobManager

var _monitoring_sessions: PackedStringArray

# keep an array of notification message handlers so they dont go out of scope and get garbage collected
var _notification_message_handlers: Array[Core.AwaitMessage]

# Debug logging to file - captures ALL autocoder traffic for debugging
var _log_file: FileAccess = null
const LOG_FILE_PATH = "user://autocoder_traffic.log"

func _log_traffic(category: String, data: Variant = null) -> void:
	if _log_file == null:
		_log_file = FileAccess.open(LOG_FILE_PATH, FileAccess.WRITE)
		if _log_file:
			_log_file.store_line("=" .repeat(80))
			_log_file.store_line("=== AUTOCODER TRAFFIC LOG ===")
			_log_file.store_line("=== Started: %s ===" % Time.get_datetime_string_from_system())
			_log_file.store_line("=== File: %s ===" % ProjectSettings.globalize_path(LOG_FILE_PATH))
			_log_file.store_line("=" .repeat(80))
			_log_file.store_line("")

	if _log_file:
		var timestamp = Time.get_datetime_string_from_system()
		_log_file.store_line("-".repeat(80))
		_log_file.store_line("[%s] <<< %s >>>" % [timestamp, category])
		if data != null:
			_log_file.store_line(JSON.stringify(data, "  "))
		_log_file.store_line("")
		_log_file.flush()  # Ensure it's written immediately

func _init() -> void:
	Core.ready.connect(
		func():
			Core.client.connection_established.connect(_on_core_connected)
			Core.client.connection_closed.connect(_on_core_disconnected)
			Core.client.message_received.connect(_on_core_message_received)
	)

	SingletonObject.autocoder_manager = self


func _ready() -> void:
	# Get reference to submit job manager
	submit_job_manager = get_node("TabContainer/Jobs") as AutocoderSubmitJobManager


func info(input):
	print("#\n#### Autocoder: %s\n#" % str(input))


func _on_core_connected():
	info("Waiting for registration message...")

	var registration_message = await (
		Core
		.await_message()
		.with_topic("system")
		.with_cmd("registration_confirmed")
		.receive()
	)

	if not registration_message:
		info("No registration message received")
		return

	info("Registration message received")

	var services = await Core.fetch_services()

	for service in services:

		info("Found service: %s" % service.client_id)

		if service.client_id == "artifact-service":
			artifact_registry_adapter = ArtifactRegistryAdapter.new(service)

		if service.client_id == "autocoder-orchestrator":
			autocoder_adapter = AutocoderAdapter.new(service)

	# Load previous sessions after connection is established
	if autocoder_adapter:
		_load_session_history()


func _on_core_disconnected():
	info("Core disconnected")

func _on_core_message_received(data):
	if data is Dictionary and data.get("cmd", "") == "event" and data.get("entity_type", "") == "core":
		var params = data.get("params", {})
		if params.get("name", "") == "service_disconnected":
			info("Service %s disconnected" % params.get("service_id", "Unknown"))


## Load session history on app startup
func _load_session_history() -> void:
	if not autocoder_adapter:
		info("Autocoder adapter not available for loading session history")
		return

	info("Loading previous sessions...")

	var sessions = await autocoder_adapter.list_sessions()

	if sessions.is_empty():
		info("No previous sessions found")
		return

	info("Found %d previous session(s)" % sessions.size())

	# Check for active sessions (in_review or processing)
	var active_sessions: Array[Dictionary] = []
	for session in sessions:
		var status = str(session.get("status", "")).to_lower()
		if status in ["in_review", "processing", "active"]:
			active_sessions.append(session)

	if not active_sessions.is_empty():
		info("Found %d active session(s) that can be resumed" % active_sessions.size())
		_show_resume_sessions_notification(active_sessions)

	# TODO: Display session history in UI
	# For now just log them
	for session in sessions:
		var session_id = session.get("session_id", "unknown")
		var status = session.get("status", "unknown")
		var created = session.get("created_at", "")
		info("  - Session %s: %s (created: %s)" % [session_id, status, created])


## Show notification for resumable sessions
func _show_resume_sessions_notification(active_sessions: Array[Dictionary]) -> void:
	var message = "You have %d active AutoCoder session(s) that can be resumed." % active_sessions.size()

	if active_sessions.size() == 1:
		var session = active_sessions[0]
		var session_id = session.get("session_id", "")
		message = "AutoCoder session %s is ready to resume." % session_id

	SingletonObject.create_toast_notification(message, ToastNotification.Type.INFO)


func _subscribe_to_session(session_id: String) -> void:
	var user_id = Core.client.client_id
	if user_id.is_empty():
		info("Cannot subscribe to sessions - user_id is empty")
		return

	# Subscribe to session-specific iteration topic (NO wildcards)
	var iteration_topic = "autocoder-orchestrator/iteration/%s/%s" % [user_id, session_id]
	info("=== SUBSCRIBING TO SESSION ===")
	info("Topic: %s" % iteration_topic)
	info("User ID: %s" % user_id)
	info("Session ID: %s" % session_id)

	var success = await Core.subscribe(iteration_topic)

	info("Subscription result: %s" % ("SUCCESS" if success else "FAILED"))

	if not success:
		SingletonObject.ErrorDisplay("Subscription Failed", "Failed to subscribe to iteration updates")
		return

	info("✓ Successfully subscribed to iteration topic")

	# Subscribe to session-specific LLM traffic topic (NO wildcards)
	var llm_topic = "autocoder-orchestrator/llm-traffic/%s/%s" % [user_id, session_id]
	info("Subscribing to LLM topic: %s" % llm_topic)

	success = await Core.subscribe(llm_topic)
	if not success:
		SingletonObject.ErrorDisplay("Subscription Failed", "Failed to subscribe to LLM traffic")
		return

	info("Successfully subscribed to LLM traffic topic")

	# Subscribe to session-specific actions topic (hierarchical action stream)
	var actions_topic = "autocoder-orchestrator/actions/%s/%s" % [user_id, session_id]
	info("Subscribing to actions topic: %s" % actions_topic)

	success = await Core.subscribe(actions_topic)
	if not success:
		info("Warning: Failed to subscribe to actions topic (may not be available)")
	else:
		info("Successfully subscribed to actions topic")

	# Setup global handlers for wildcard notifications
	info("=== SETTING UP MESSAGE HANDLERS ===")

	var iteration_awaiter = Core.await_message()
	_notification_message_handlers.append(iteration_awaiter)
	info("Created iteration_awaiter")

	var telemetry_awaiter = Core.await_message()
	_notification_message_handlers.append(telemetry_awaiter)
	info("Created telemetry_awaiter")

	# Add a catch-all handler to see if we're getting ANY messages
	var debug_awaiter = Core.await_message()
	_notification_message_handlers.append(debug_awaiter)
	debug_awaiter.receive_all().connect(
		func(msg: Dictionary):
			info("!!! DEBUG: ANY MESSAGE RECEIVED !!!")
			info("Command: %s" % msg.get("cmd", "NONE"))
			info("Topic: %s" % msg.get("topic", "NONE"))
	)
	info("Created debug catch-all handler")

	# Handle iteration publications (from wildcard)
	iteration_awaiter.with_cmd("publication").receive_all().connect(
		func(msg: Dictionary):
			var topic = msg.get("topic", "")

			if not topic.begins_with("autocoder-orchestrator/iteration/"):
				return

			var params = msg.get("params", {})
			var payload: Dictionary = params.get("data", {})

			# Log FULL iteration notification to file
			_log_traffic("ITERATION_NOTIFICATION", payload)

			info("✓ Iteration publication - status: %s" % payload.get("status", "unknown"))

			# Route to the appropriate viewer if monitoring this session
			_handle_iteration_notification(session_id, topic, payload)
	)

	# Handle LLM traffic publications (from wildcard)
	telemetry_awaiter.with_cmd("publication").receive_all().connect(
		func(msg: Dictionary):
			var topic = msg.get("topic", "")
			if not topic.begins_with("autocoder-orchestrator/llm-traffic/"):
				return

			var payload = msg.get("params", {}).get("data", {})

			# Log LLM traffic (but truncate large content)
			var log_payload = payload.duplicate() if payload is Dictionary else {}
			if log_payload.has("content") and str(log_payload.get("content", "")).length() > 500:
				log_payload["content"] = str(log_payload.get("content", "")).substr(0, 500) + "... [TRUNCATED]"
			_log_traffic("LLM_TRAFFIC", log_payload)

			# Route to the appropriate viewer if monitoring this session
			_handle_llm_notification(session_id, topic, payload)
	)

	# Handle actions publications (hierarchical action stream)
	var actions_awaiter = Core.await_message()
	_notification_message_handlers.append(actions_awaiter)
	actions_awaiter.with_cmd("publication").receive_all().connect(
		func(msg: Dictionary):
			var topic = msg.get("topic", "")
			if not topic.begins_with("autocoder-orchestrator/actions/"):
				return

			var payload = msg.get("params", {}).get("data", {})
			var action_type = payload.get("action_type", "UNKNOWN")

			# Log ALL actions to file
			_log_traffic("ACTION: %s" % action_type, payload)

			info("Received action: %s (status: %s)" % [action_type, payload.get("status", "unknown")])

			# Route to the appropriate viewer
			_handle_action_notification(session_id, topic, payload)
	)


## Handle iteration notification for a specific session
func _handle_iteration_notification(session_id: String, topic: String, payload: Dictionary) -> void:
	# Find the log viewer for this session
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return

	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue

		var editor = tab as Editor
		if editor.type != Editor.Type.LOGS:
			continue

		var logs_viewer = editor.logs_viewer
		if not logs_viewer:
			continue

		# Check if this viewer is for our session
		if logs_viewer.session_id == session_id:
			var status = payload.get("status", "unknown")
			info("Routing iteration notification to viewer for session %s (status: %s)" % [session_id, status])

			logs_viewer.add_iteration_entry(topic, payload)

			# Show error dialog if status is error
			if status == "error":
				var error_msg = str(payload.get("error", ""))
				if error_msg.is_empty():
					error_msg = str(payload.get("summary", ""))
				if error_msg.is_empty():
					error_msg = str(payload.get("message", ""))
				if error_msg.is_empty():
					error_msg = "Unknown error occurred"
				SingletonObject.ErrorDisplay("Generation Failed", error_msg)

			return

	info("No viewer found for session %s (not currently monitoring)" % session_id)


## Handle LLM notification for a specific session
func _handle_llm_notification(session_id: String, topic: String, payload: Variant) -> void:
	# Find the log viewer for this session
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return

	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue

		var editor = tab as Editor
		if editor.type != Editor.Type.LOGS:
			continue

		var logs_viewer = editor.logs_viewer
		if not logs_viewer:
			continue

		# Check if this viewer is for our session
		if logs_viewer.session_id == session_id:
			logs_viewer.add_telemetry_entry(topic, payload)
			return


## Handle action notification for a specific session (hierarchical action stream)
func _handle_action_notification(session_id: String, topic: String, payload: Dictionary) -> void:
	# Find the log viewer for this session
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return

	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue

		var editor = tab as Editor
		if editor.type != Editor.Type.LOGS:
			continue

		var logs_viewer = editor.logs_viewer
		if not logs_viewer:
			continue

		# Check if this viewer is for our session
		if logs_viewer.session_id == session_id:
			var action_type = payload.get("action_type", "UNKNOWN")
			info("Routing action notification to viewer: %s (type: %s)" % [session_id, action_type])

			logs_viewer.add_action_entry(topic, payload)
			return

	info("No viewer found for session %s action notification" % session_id)


func monitor_session(user_id: String, session_id: String, _notification_topics: Array[String] = []):
	"""
	Open a log viewer for a session and subscribe to its notification topics.
	Subscribes to session-specific topics (no wildcards) to receive iteration and LLM traffic updates.
	"""

	if session_id.is_empty():
		SingletonObject.ErrorDisplay("Can't monitor", "Missing session id")
		return

	if _monitoring_sessions.has(session_id):
		info("Already monitoring session %s" % session_id)
		return

	info("Opening log viewer for session %s" % session_id)

	# Subscribe to session-specific topics (NO wildcards)
	_subscribe_to_session(session_id)

	# Create log viewer tab
	var log_editor: Editor = SingletonObject.editor_pane.add(
		Editor.Type.LOGS,
		null,
		"Autocoder Session %s" % session_id
	)

	var log_viewer: AutocoderLogsViewer = log_editor.logs_viewer
	if not log_viewer:
		SingletonObject.ErrorDisplay("Can't open logs", "Log viewer unavailable")
		return

	# Configure the viewer with session-specific topics
	var session_topics: PackedStringArray = PackedStringArray([
		"autocoder-orchestrator/iteration/%s/%s" % [user_id, session_id],
		"autocoder-orchestrator/llm-traffic/%s/%s" % [user_id, session_id]
	])

	log_viewer.configure_session(user_id, session_id, session_topics)
	log_viewer.mark_saved_snapshot()

	# Mark as monitored
	_monitoring_sessions.append(session_id)

	info("Log viewer opened for session %s (subscribed to session-specific topics)" % session_id)
