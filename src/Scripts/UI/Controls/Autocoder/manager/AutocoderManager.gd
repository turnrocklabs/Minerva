class_name AutocodeManager
extends VBoxContainer


var artifact_registry_adapter: ArtifactRegistryAdapter
var autocoder_adapter: AutocoderAdapter
var submit_job_manager: Node  # Will be cast to AutocoderSubmitJobManager in _ready()

var _monitoring_sessions: PackedStringArray
var _latest_archive_by_session: Dictionary = {}  # session_id -> archive_uri
var _latest_patch_by_session: Dictionary = {}  # session_id -> patch_uri

# keep an array of notification message handlers so they dont go out of scope and get garbage collected
var _notification_message_handlers: Array[Core.AwaitMessage]

# Permission request queue (OpenCode approvals)
var _permission_queue: Array[Dictionary] = []
var _active_permission_request: Dictionary = {}

@onready var _permission_popup: PersistentWindow = %PermissionPopup
@onready var _permission_queue_label: Label = %PermissionQueueLabel
@onready var _permission_title_label: Label = %PermissionTitleLabel
@onready var _permission_type_label: Label = %PermissionTypeLabel
@onready var _permission_pattern_text: TextEdit = %PermissionPatternText
@onready var _permission_metadata_text: TextEdit = %PermissionMetadataText
@onready var _permission_approve_button: Button = %PermissionApproveButton
@onready var _permission_reject_button: Button = %PermissionRejectButton
@onready var _permission_copy_button: Button = %PermissionCopyButton

# Debug logging to file - DISABLED: All data should be saved on server, not locally
# This allows users to continue sessions across devices
# var _log_file: FileAccess = null
# const LOG_FILE_PATH = "user://autocoder_traffic.log"

func _log_traffic(category: String, data: Variant = null) -> void:
	# Local file logging disabled - all data is saved on server
	# LLM traffic, session history, and all conversation data is persisted server-side
	# This allows users to continue sessions across devices
	pass

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
	
	# Get reference to session view and connect signals
	var session_view = get_node("TabContainer/My Sessions") as AutocoderSessionViewManager
	if session_view:
		session_view.session_double_clicked.connect(_on_session_double_clicked)

	if _permission_pattern_text:
		_permission_pattern_text.editable = false
		_permission_pattern_text.scroll_vertical = 0

	if _permission_metadata_text:
		_permission_metadata_text.editable = false
		_permission_metadata_text.scroll_vertical = 0

	_permission_approve_button.pressed.connect(_on_permission_approve_pressed)
	_permission_reject_button.pressed.connect(_on_permission_reject_pressed)
	_permission_copy_button.pressed.connect(_on_permission_copy_pressed)
	if _permission_popup:
		_permission_popup.close_requested.connect(_on_permission_close_requested)

	# Kanban boards now created only when planning sessions start
	# (see _handle_planning_notification and SubmitJob._get_or_create_kanban_board)


func info(input):
	# if SingletonObject.verbose_logging:
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
		await _load_session_history()
		# Now refresh child views (sessions, models, etc.)
		_refresh_child_views()
	else:
		info("⚠️ Autocoder service not found in discovered services")


func _on_core_disconnected():
	info("Core disconnected")

func _on_core_message_received(data):
	if data is Dictionary and data.get("cmd", "") == "request" and data.get("topic", "") == "autocoder/permission":
		_enqueue_permission_request(data)
		return

	if data is Dictionary and data.get("cmd", "") == "event" and data.get("entity_type", "") == "core":
		var params = data.get("params", {})
		if params.get("name", "") == "service_disconnected":
			info("Service %s disconnected" % params.get("service_id", "Unknown"))


func _enqueue_permission_request(msg: Dictionary) -> void:
	var params = msg.get("params", {})
	if not (params is Dictionary):
		return

	var request_id = str(params.get("request_id", ""))
	var payload = params.get("data", {})

	if request_id.is_empty():
		return

	if _permission_queue.any(func(item): return str(item.get("request_id", "")) == request_id):
		return

	if _active_permission_request.get("request_id", "") == request_id:
		return

	_permission_queue.append({
		"request_id": request_id,
		"data": payload if payload is Dictionary else {}
	})

	_present_next_permission_request()


func _present_next_permission_request() -> void:
	if not _active_permission_request.is_empty():
		_update_permission_queue_label()
		return

	if _permission_queue.is_empty():
		_permission_popup.hide()
		return

	_active_permission_request = _permission_queue.pop_front()
	_show_permission_request(_active_permission_request)


func _show_permission_request(request: Dictionary) -> void:
	var data = request.get("data", {})
	var title = str(data.get("title", "Permission request"))
	var request_type = str(data.get("type", "unknown"))
	var pattern = str(data.get("pattern", ""))
	var metadata = data.get("metadata", {})

	_permission_title_label.text = "Title: %s" % title
	_permission_type_label.text = "Type: %s" % request_type
	_permission_pattern_text.text = pattern
	_permission_metadata_text.text = JSON.stringify(metadata, "  ")

	_update_permission_queue_label()

	if not _permission_popup.visible:
		_permission_popup.popup_centered()


func _update_permission_queue_label() -> void:
	var total = _permission_queue.size()
	var index = 0
	if not _active_permission_request.is_empty():
		index = 1
		total += 1
	_permission_queue_label.text = "Queue: %d of %d" % [index, total]


func _on_permission_approve_pressed() -> void:
	_handle_permission_response("approve")


func _on_permission_reject_pressed() -> void:
	_handle_permission_response("reject")


func _handle_permission_response(response: String) -> void:
	if _active_permission_request.is_empty():
		return

	var request_id = str(_active_permission_request.get("request_id", ""))
	if request_id.is_empty():
		_active_permission_request = {}
		_present_next_permission_request()
		return

	if autocoder_adapter:
		var success = autocoder_adapter.respond_permission(request_id, response)
		if not success:
			SingletonObject.ErrorDisplay(
				"Permission Response Failed",
				"Failed to send %s response for permission request." % response
			)
			# Don't clear the request, let user try again
			return

	_active_permission_request = {}
	_present_next_permission_request()


func _on_permission_copy_pressed() -> void:
	if _active_permission_request.is_empty():
		return

	var payload = _active_permission_request.get("data", {})
	var text = JSON.stringify(payload, "  ")
	DisplayServer.clipboard_set(text)
	SingletonObject.create_toast_notification("Permission details copied.", ToastNotification.Type.SUCCESS)


func _on_permission_close_requested() -> void:
	if _active_permission_request.is_empty():
		_permission_popup.hide()
		return

	_permission_popup.popup_centered()


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

	# Log sessions for debugging
	for session in sessions:
		var session_id = session.get("session_id", "unknown")
		var status = session.get("status", "unknown")
		var created = session.get("created_at", "")
		info("  - Session %s: %s (created: %s)" % [session_id, status, created])


func _refresh_child_views() -> void:
	"""Refresh session lists and models in child views after autocoder is ready"""
	info("Refreshing child views with session data and models...")
	
	# Refresh SubmitJob dropdown, session history browser, and models
	if submit_job_manager:
		if submit_job_manager.has_method("_refresh_session_history"):
			print("[AutocoderManager] Calling SubmitJob._refresh_session_history()")
			submit_job_manager._refresh_session_history()
		else:
			push_warning("[AutocoderManager] SubmitJob does not have _refresh_session_history method")
		
		# Now refresh models (autocoder_adapter is guaranteed to be ready)
		if submit_job_manager.has_method("_refresh_models"):
			print("[AutocoderManager] Calling SubmitJob._refresh_models()")
			submit_job_manager._refresh_models()
		else:
			push_warning("[AutocoderManager] SubmitJob does not have _refresh_models method")
	else:
		push_warning("[AutocoderManager] submit_job_manager is null")
	
	# Refresh SessionView tree
	var session_view = get_node_or_null("TabContainer/My Sessions") as AutocoderSessionViewManager
	if session_view:
		if session_view.has_method("_load_sessions"):
			print("[AutocoderManager] Calling SessionView._load_sessions()")
			session_view._load_sessions()
		else:
			push_warning("[AutocoderManager] SessionView does not have _load_sessions method")
	else:
		push_warning("[AutocoderManager] Could not find SessionView node")


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
		print("DEBUG: Cannot subscribe to sessions - user_id is empty")
		return

	# Subscribe to session-specific iteration topic (NO wildcards)
	var iteration_topic = "autocoder-orchestrator/iteration/%s/%s" % [user_id, session_id]
	print("=== DEBUG: SUBSCRIBING TO SESSION ===")
	print("Topic: %s" % iteration_topic)
	print("User ID: %s" % user_id)
	print("Session ID: %s" % session_id)
	print("Timestamp: %s" % Time.get_datetime_string_from_system())

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

	# Subscribe to planning topics (for planning mode)
	var planning_topic = "autocoder-orchestrator/planning/%s/%s" % [user_id, session_id]
	info("Subscribing to planning topic: %s" % planning_topic)

	success = await Core.subscribe(planning_topic)
	if not success:
		info("Warning: Failed to subscribe to planning topic (may not be available)")
	else:
		info("Successfully subscribed to planning topic")

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
			# Always print - bypasses verbose_logging for debugging
			print("!!! DEBUG: ANY MESSAGE RECEIVED !!!")
			print("Command: %s" % msg.get("cmd", "NONE"))
			print("Topic: %s" % msg.get("topic", "NONE"))
			var params = msg.get("params", {})
			if params is Dictionary and params.has("topic"):
				print("Params.topic: %s" % params.get("topic", "NONE"))
	)
	print("DEBUG: Created catch-all message handler")

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

	# Handle planning publications (planning mode updates)
	var planning_awaiter = Core.await_message()
	_notification_message_handlers.append(planning_awaiter)
	planning_awaiter.with_cmd("publication").receive_all().connect(
		func(msg: Dictionary):
			var topic = msg.get("topic", "")
			if not topic.begins_with("autocoder-orchestrator/planning/"):
				return

			var payload = msg.get("params", {}).get("data", {})
			var pub_session_id = payload.get("session_id", "")
			var planning_status = payload.get("status", "unknown")
			
			_log_traffic("PLANNING_NOTIFICATION", payload)
			info("Received planning update for session %s (status: %s)" % [pub_session_id, planning_status])

			# Route to kanban board
			_handle_planning_notification(pub_session_id, topic, payload)
			
			# Notify submit job manager of planning turn completion
			if submit_job_manager and planning_status in ["complete", "awaiting_answers"]:
				submit_job_manager.on_planning_turn_complete(pub_session_id, planning_status)
	)


## Handle iteration notification for a specific session
func _handle_iteration_notification(session_id: String, topic: String, payload: Dictionary) -> void:
	# Record artifacts regardless of which viewers are open
	_record_artifact_ready(session_id, payload)

	# Find the kanban board or log viewer for this session
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return

	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue

		var editor = tab as Editor
		
		# Route to kanban board
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				var status = payload.get("status", "unknown")
				info("Routing iteration notification to kanban for session %s (status: %s)" % [session_id, status])
				
				# TODO: Update kanban board with iteration data
				# For now, just log it
				
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
				
				# Don't return - also route to logs viewer if present
		
		# Route summary to SubmitJob stream
		if submit_job_manager and submit_job_manager.has_method("add_iteration_message"):
			submit_job_manager.add_iteration_message(session_id, payload)
		var status_text = str(payload.get("status", "")).to_lower()
		if status_text in ["complete", "completed", "awaiting_user", "in_review", "error", "failed"]:
			if submit_job_manager.has_method("stop_llm_stream"):
				submit_job_manager.stop_llm_stream()

		# Route to logs viewer
		if editor.type == Editor.Type.LOGS:
			var logs_viewer = editor.logs_viewer
			if not logs_viewer:
				continue

			# Check if this viewer is for our session
			if logs_viewer.session_id == session_id:
				var status = payload.get("status", "unknown")
				info("Routing iteration notification to logs viewer for session %s (status: %s)" % [session_id, status])

				logs_viewer.add_iteration_entry(topic, payload)
				_record_artifact_ready(session_id, payload)
				return

	info("No viewer found for session %s (not currently monitoring)" % session_id)


func _record_artifact_ready(session_id: String, payload: Dictionary) -> void:
	if session_id.is_empty() or not payload:
		return
	var archive_uri = str(payload.get("archive_uri", ""))
	if archive_uri.is_empty():
		archive_uri = str(payload.get("output_archive_uri", ""))
	var patch_uri = str(payload.get("patch_uri", ""))
	if patch_uri.is_empty():
		patch_uri = str(payload.get("patch_url", ""))
	
	if not archive_uri.is_empty():
		_latest_archive_by_session[session_id] = archive_uri
		if submit_job_manager and submit_job_manager.has_method("set_latest_archive_uri"):
			submit_job_manager.set_latest_archive_uri(session_id, archive_uri)
	
	if not patch_uri.is_empty():
		_latest_patch_by_session[session_id] = patch_uri
		if submit_job_manager and submit_job_manager.has_method("set_latest_patch_uri"):
			submit_job_manager.set_latest_patch_uri(session_id, patch_uri)
	
	if archive_uri.is_empty() and patch_uri.is_empty():
		return
	SingletonObject.create_toast_notification(
		"Artifact ready for download (session %s)" % session_id.substr(0, 8),
		ToastNotification.Type.SUCCESS
	)


## Handle LLM notification for a specific session
func _handle_llm_notification(pub_session_id: String, topic: String, payload: Variant) -> void:
	# Route to SubmitJob action stream for planning sessions
	var manager_ref = submit_job_manager
	if not manager_ref:
		return
	
	# Handle both 'content' and 'content_delta' fields
	var content = str(payload.get("content", ""))
	var content_delta = str(payload.get("content_delta", ""))
	var event_type = str(payload.get("type", ""))
	var model_name = str(payload.get("model", ""))
	var event_data = payload.get("data", {})
	
	# Handle "request" type events - show OpenCode/OpenRouter requests
	if event_type == "request":
		var preview = _format_request_preview(model_name, event_data)
		var full_content = JSON.stringify(payload, "  ")
		if manager_ref.has_method("add_llm_request"):
			manager_ref.add_llm_request(pub_session_id, preview, full_content)
		elif manager_ref.has_method("add_llm_traffic_with_full_content"):
			manager_ref.add_llm_traffic_with_full_content(pub_session_id, preview, full_content)
		elif manager_ref.has_method("add_llm_traffic"):
			manager_ref.add_llm_traffic(pub_session_id, preview)
		else:
			manager_ref.add_llm_progress(preview)
		return
	
	# Handle streaming content_delta - accumulate chunks
	if not content_delta.is_empty():
		# For streaming chunks, send delta directly to accumulate
		if manager_ref.has_method("add_llm_delta"):
			manager_ref.add_llm_delta(pub_session_id, content_delta)
		elif manager_ref.has_method("add_llm_traffic"):
			manager_ref.add_llm_traffic(pub_session_id, content_delta)
		else:
			manager_ref.add_llm_progress(content_delta)
		return  # Don't process as JSON if it's just a delta
	
	# Handle "response_chunk" type - streaming response chunks
	if event_type == "response_chunk":
		var chunk_content = str(event_data.get("content", ""))
		if not chunk_content.is_empty():
			if manager_ref.has_method("add_llm_delta"):
				manager_ref.add_llm_delta(pub_session_id, chunk_content)
			elif manager_ref.has_method("add_llm_traffic"):
				manager_ref.add_llm_traffic(pub_session_id, chunk_content)
			else:
				manager_ref.add_llm_progress(chunk_content)
		return
	
	# Handle "response_complete" type - full response
	if event_type == "response_complete":
		# Extract content from the data field or top-level
		var response_content = str(event_data.get("content", content))
		if response_content.is_empty():
			response_content = content
		if not response_content.is_empty():
			var preview = _format_response_preview(model_name, response_content)
			var full_content = JSON.stringify(payload, "  ") if response_content.length() > 500 else response_content
			if manager_ref.has_method("add_llm_traffic_with_full_content"):
				manager_ref.add_llm_traffic_with_full_content(pub_session_id, preview, full_content)
			elif manager_ref.has_method("add_llm_traffic"):
				manager_ref.add_llm_traffic(pub_session_id, preview)
			else:
				manager_ref.add_llm_progress(preview)
		return
	
	# Parse JSON content if it's a string (for complete responses)
	if not content.is_empty():
		# Try to parse as JSON to extract actual content
		var json_parser = JSON.new()
		var parse_result = json_parser.parse(content)
		if parse_result == OK:
			var json_data = json_parser.data
			if json_data is Dictionary:
				# Extract meaningful content from JSON
				var extracted_content = ""
				if json_data.has("tasks"):
					var tasks = json_data.get("tasks", [])
					extracted_content = "📋 Planning Tasks Generated:\n\n"
					for i in range(min(tasks.size(), 5)):  # Show first 5 tasks
						var task = tasks[i]
						if task is Dictionary:
							extracted_content += "• %s\n" % str(task.get("title", "Untitled"))
					if tasks.size() > 5:
						extracted_content += "... and %d more tasks\n" % (tasks.size() - 5)
				elif json_data.has("message") or json_data.has("text"):
					extracted_content = str(json_data.get("message", json_data.get("text", "")))
				else:
					# Fallback: show JSON structure
					extracted_content = "📄 JSON Response (%s)" % event_type
				
				# Store full content for viewing
				if manager_ref.has_method("add_llm_traffic_with_full_content"):
					manager_ref.add_llm_traffic_with_full_content(pub_session_id, extracted_content, content)
				elif manager_ref.has_method("add_llm_traffic"):
					manager_ref.add_llm_traffic(pub_session_id, extracted_content)
				else:
					manager_ref.add_llm_progress(extracted_content)
			else:
				# Not JSON, use as-is
				if manager_ref.has_method("add_llm_traffic"):
					manager_ref.add_llm_traffic(pub_session_id, content)
				else:
					manager_ref.add_llm_progress(content)
		else:
			# Not JSON, use as-is
			if manager_ref.has_method("add_llm_traffic"):
				manager_ref.add_llm_traffic(pub_session_id, content)
			else:
				manager_ref.add_llm_progress(content)


## Format a preview for LLM request events
func _format_request_preview(model: String, data: Variant) -> String:
	var preview = "🚀 Request"
	if not model.is_empty():
		preview += " → %s" % model
	
	if data is Dictionary:
		var message_count = int(data.get("message_count", 0))
		var tools = data.get("tools", [])
		var tool_count = tools.size() if tools is Array else 0
		var request_type = str(data.get("request_type", ""))
		
		if not request_type.is_empty():
			preview += " [%s]" % request_type
		
		if message_count > 0:
			preview += " (%d msgs" % message_count
			if tool_count > 0:
				preview += ", %d tools" % tool_count
			preview += ")"
		
		# First check for prompt_preview (sent by backend)
		var prompt_preview = str(data.get("prompt_preview", ""))
		if not prompt_preview.is_empty():
			if prompt_preview.length() > 150:
				prompt_preview = prompt_preview.substr(0, 150) + "..."
			preview += "\n📝 " + prompt_preview
		else:
			# Fallback: try to get prompt from messages array
			var messages = data.get("messages", [])
			if messages is Array and messages.size() > 0:
				# Find the LAST user message (could be at any position)
				var user_content = ""
				for i in range(messages.size() - 1, -1, -1):  # Iterate backwards
					var msg = messages[i]
					if msg is Dictionary and msg.get("role", "") == "user":
						var content = msg.get("content", "")
						# Handle both string content and array content (OpenAI format)
						if content is String:
							user_content = content
						elif content is Array:
							# Extract text from content array [{"type": "text", "text": "..."}]
							for part in content:
								if part is Dictionary and part.get("type", "") == "text":
									user_content = str(part.get("text", ""))
									break
						break  # Stop after finding last user message
				
				if not user_content.is_empty():
					if user_content.length() > 150:
						user_content = user_content.substr(0, 150) + "..."
					preview += "\n📝 " + user_content
	
	return preview


## Format a preview for LLM response events
func _format_response_preview(model: String, content: String) -> String:
	var preview = "✅ Response"
	if not model.is_empty():
		preview += " ← %s" % model
	
	# Try to parse as JSON and extract meaningful info
	var json_parser = JSON.new()
	var parse_result = json_parser.parse(content)
	if parse_result == OK:
		var json_data = json_parser.data
		if json_data is Dictionary:
			if json_data.has("tasks"):
				var tasks = json_data.get("tasks", [])
				preview += "\n📋 %d tasks generated:" % tasks.size()
				# Show first few tasks with titles
				var max_tasks_shown = min(5, tasks.size())
				for i in range(max_tasks_shown):
					var task = tasks[i]
					if task is Dictionary:
						var title = str(task.get("title", "Untitled"))
						var priority = str(task.get("priority", ""))
						var complexity = str(task.get("estimated_complexity", ""))
						var task_line = "\n  %d. %s" % [i + 1, title]
						if not priority.is_empty():
							task_line += " (P%s)" % priority
						if not complexity.is_empty():
							task_line += " [%s]" % complexity
						preview += task_line
				if tasks.size() > max_tasks_shown:
					preview += "\n  ... and %d more" % (tasks.size() - max_tasks_shown)
			if json_data.has("questions"):
				var questions = json_data.get("questions", [])
				if questions.size() > 0:
					preview += "\n❓ %d questions" % questions.size()
		return preview
	
	# Plain text preview
	if content.length() > 150:
		preview += "\n" + content.substr(0, 150) + "..."
	elif not content.is_empty():
		preview += "\n" + content
	
	return preview


## Handle action notification for a specific session (hierarchical action stream)
func _handle_action_notification(session_id: String, topic: String, payload: Dictionary) -> void:
	# Find the kanban board or log viewer for this session
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return

	var action_type = payload.get("action_type", "UNKNOWN")
	var action_id = payload.get("action_id", "")
	# Backend sends "summary", but we also check "description" for compatibility
	var description = payload.get("summary", payload.get("description", ""))
	var status = payload.get("status", "")
	var output = payload.get("output", "")
	var details = payload.get("details", {})
	
	print("[AutocoderManager] Action notification: type=%s, id=%s, status=%s, desc=%s" % [action_type, action_id, status, description])

	# Route to SubmitJob action stream for planning sessions
	if submit_job_manager:
		# Normalize status to lowercase for comparison (backend sends lowercase)
		var status_lower = status.to_lower()
		
		# Map backend action status to frontend status
		var frontend_status = "running"
		if status_lower == "completed":
			frontend_status = "completed"
		elif status_lower == "error" or status_lower == "failed":
			frontend_status = "error"
		elif status_lower == "in_progress":
			frontend_status = "running"

		# Add or update tool call in action stream
		# First try to update existing tool call
		var updated = false
		if not action_id.is_empty() and not status.is_empty():
			# Check if we already have this action
			if submit_job_manager._action_stream and submit_job_manager._action_stream._tool_cards.has(action_id):
				submit_job_manager.update_tool_call(action_id, frontend_status, output)
				updated = true
		
		# If not updated and we have valid data, add as new tool call
		if not updated and not action_id.is_empty() and not description.is_empty():
			submit_job_manager.add_tool_call(action_type, description, action_id)
			# If it's already completed, update status immediately
			if status_lower == "completed" or status_lower == "error":
				submit_job_manager.update_tool_call(action_id, frontend_status, output)

		info("Routed action to SubmitJob stream: %s (%s)" % [action_type, frontend_status])

	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue

		var editor = tab as Editor

		# Route to kanban board
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				info("Routing action notification to kanban: %s (type: %s)" % [session_id, action_type])

				# TODO: Update kanban board with action data
				# - Could create tasks from tool calls
				# - Could update task status based on action status

		# Route to logs viewer
		if editor.type == Editor.Type.LOGS:
			var logs_viewer = editor.logs_viewer
			if not logs_viewer:
				continue

			# Check if this viewer is for our session
			if logs_viewer.session_id == session_id:
				info("Routing action notification to logs viewer: %s (type: %s)" % [session_id, action_type])

				logs_viewer.add_action_entry(topic, payload)
				return

	info("Action notification processed for session %s" % session_id)


## Handle planning notification for a specific session
func _handle_planning_notification(session_id: String, topic: String, payload: Dictionary) -> void:
	"""Handle planning updates and populate kanban board"""
	print("[AutocoderManager] ========== PLANNING NOTIFICATION RECEIVED ==========")
	print("[AutocoderManager] Session: %s" % session_id)
	print("[AutocoderManager] Topic: %s" % topic)
	print("[AutocoderManager] Payload keys: %s" % str(payload.keys()))
	
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		print("[AutocoderManager] ERROR: No editor pane or tabs available")
		return

	var tasks = payload.get("tasks", [])
	var questions = payload.get("questions", [])
	var status = payload.get("status", "unknown")
	
	print("[AutocoderManager] Status: %s, Tasks: %d, Questions: %d" % [status, tasks.size(), questions.size()])

	# Find or create kanban board for this session
	var kanban_editor: Editor = null
	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue
		var editor = tab as Editor
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				kanban_editor = editor
				break

	if not kanban_editor:
		# Create new kanban board
		print("[AutocoderManager] Creating new kanban board for session: %s" % session_id)
		kanban_editor = SingletonObject.editor_pane.add(
			Editor.Type.KANBAN,
			null,
			"Planning: %s" % session_id.substr(0, 12)
		)
		if kanban_editor and kanban_editor.kanban_board:
			var kanban = kanban_editor.kanban_board
			kanban.set_meta("session_id", session_id)
			kanban.set_meta("user_id", Core.client.client_id)
			# Set session_id THEN load saved state (must be in this order)
			if kanban.task_store:
				kanban.task_store.session_id = session_id
				kanban.load_saved_state()
				print("[AutocoderManager] Loaded saved kanban state for session: %s (tasks: %d)" % [
					session_id, kanban.task_store.get_all_tasks().size()
				])
	else:
		print("[AutocoderManager] Found existing kanban board for session: %s" % session_id)

	if kanban_editor and kanban_editor.kanban_board:
		var kanban = kanban_editor.kanban_board
		var task_store = kanban.task_store

		if task_store:
			# Set session_id if not set
			if task_store.session_id.is_empty():
				task_store.session_id = session_id

			# Update tasks from planning
			if tasks.size() > 0:
				_update_kanban_from_planning_tasks(tasks, task_store)

		# Handle questions - route through SubmitJob's deduplication logic
		if submit_job_manager and submit_job_manager.has_method("_handle_planning_questions"):
			submit_job_manager._handle_planning_questions(questions, session_id)

		info("Updated kanban board for planning session %s (status: %s, %d tasks)" % [session_id, status, tasks.size()])

func _update_kanban_from_planning_tasks(tasks: Array, task_store: AutocoderTaskStore) -> void:
	"""Update kanban board with tasks from planning"""
	if not task_store:
		print("[AutocoderManager] ERROR: No task_store provided")
		return

	print("[AutocoderManager] _update_kanban_from_planning_tasks: Processing %d tasks" % tasks.size())

	var existing_tasks: Dictionary = {}
	for task in task_store.get_all_tasks():
		var plan_task_id = ""
		if task.metadata and task.metadata.has("plan_task_id"):
			plan_task_id = str(task.metadata.get("plan_task_id", ""))
		if plan_task_id.is_empty():
			plan_task_id = task.id
		existing_tasks[plan_task_id] = task
	
	print("[AutocoderManager] Found %d existing tasks in store" % existing_tasks.size())

	# Add new tasks
	for task_data in tasks:
		if not task_data is Dictionary:
			continue

		var task_id = task_data.get("id", "")
		if task_id.is_empty():
			# Generate ID if not provided
			task_id = "plan_%s" % str(Time.get_ticks_msec())

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
		var metadata = {
			"dependencies": dependencies,
			"estimated_complexity": complexity,
			"category": category,
			"plan_task_id": task_id
		}
		
		print("[AutocoderManager] Task %s: status_key='%s' -> mapped_status=%d" % [task_id, status_key, mapped_status])

		if existing_tasks.has(task_id):
			var existing_task = existing_tasks[task_id]
			print("[AutocoderManager] Updating existing task %s (kanban_id=%s) to status %d" % [task_id, existing_task.id, mapped_status])
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

		# Store metadata
		task.metadata = metadata
		existing_tasks[task_id] = task
		info("Added planning task to kanban: %s" % title)


func monitor_session(user_id: String, session_id: String, _notification_topics: Array[String] = []):
	"""
	Open a kanban board for a session and subscribe to its notification topics.
	Subscribes to session-specific topics (no wildcards) to receive iteration and LLM traffic updates.
	"""

	if session_id.is_empty():
		SingletonObject.ErrorDisplay("Can't monitor", "Missing session id")
		return

	if _monitoring_sessions.has(session_id):
		info("Already monitoring session %s" % session_id)
		return

	info("Opening kanban board for session %s" % session_id)

	# Subscribe to session-specific topics (NO wildcards)
	_subscribe_to_session(session_id)

	# Reuse existing kanban board if already opened for this session
	var kanban_editor: Editor = null
	if SingletonObject.editor_pane and SingletonObject.editor_pane.Tabs:
		for tab in SingletonObject.editor_pane.Tabs.get_children():
			if not tab is Editor:
				continue
			var editor = tab as Editor
			if editor.type == Editor.Type.KANBAN:
				var kanban_board = editor.kanban_board
				if kanban_board and kanban_board.get_meta("session_id", "") == session_id:
					kanban_editor = editor
					break

	# Create kanban board tab if one doesn't exist
	if not kanban_editor:
		info("Creating new kanban board for session %s" % session_id)
		kanban_editor = SingletonObject.editor_pane.add(
			Editor.Type.KANBAN,
			null,
			"Session %s" % session_id.substr(0, 12)
		)
	else:
		info("Found existing kanban board for session %s" % session_id)

	var kanban: AutocoderKanbanBoard = kanban_editor.kanban_board if kanban_editor else null
	if not kanban:
		SingletonObject.ErrorDisplay("Can't open kanban", "Kanban board unavailable")
		return

	# Store session info on the kanban board for later use
	kanban.set_meta("user_id", user_id)
	kanban.set_meta("session_id", session_id)
	# Set session_id THEN load saved state (must be in this order since _ready() ran first)
	if kanban.task_store:
		kanban.task_store.session_id = session_id
		kanban.load_saved_state()
		info("Loaded saved kanban state for session %s (tasks: %d)" % [
			session_id, kanban.task_store.get_all_tasks().size()
		])

	# Logs viewer is optional; keep logs in SubmitJob stream instead of auto-opening

	# Mark as monitored
	_monitoring_sessions.append(session_id)

	info("Kanban board opened for session %s (subscribed to session-specific topics)" % session_id)


func open_logs_viewer(user_id: String, session_id: String) -> AutocoderLogsViewer:
	"""
	Open a log viewer for a session (for debugging/advanced view).
	"""
	# Create log viewer tab
	var log_editor: Editor = SingletonObject.editor_pane.add(
		Editor.Type.LOGS,
		null,
		"Logs %s" % session_id.substr(0, 12)
	)

	var log_viewer: AutocoderLogsViewer = log_editor.logs_viewer
	if not log_viewer:
		SingletonObject.ErrorDisplay("Can't open logs", "Log viewer unavailable")
		return null

	# Configure the viewer with session-specific topics
	var session_topics: PackedStringArray = PackedStringArray([
		"autocoder-orchestrator/iteration/%s/%s" % [user_id, session_id],
		"autocoder-orchestrator/llm-traffic/%s/%s" % [user_id, session_id]
	])

	log_viewer.configure_session(user_id, session_id, session_topics)
	log_viewer.mark_saved_snapshot()

	return log_viewer


func _find_logs_viewer(session_id: String) -> AutocoderLogsViewer:
	if not SingletonObject.editor_pane or not SingletonObject.editor_pane.Tabs:
		return null
	for tab in SingletonObject.editor_pane.Tabs.get_children():
		if not tab is Editor:
			continue
		var editor = tab as Editor
		if editor.type == Editor.Type.LOGS and editor.logs_viewer and editor.logs_viewer.session_id == session_id:
			return editor.logs_viewer
	return null


func _on_session_double_clicked(session_id: String) -> void:
	"""Handle double-click from the My Sessions tab"""
	print("[AutocoderManager] Session double-clicked: %s" % session_id)
	
	# Check if session is ongoing (active or in_review status)
	var status = await _get_session_status(session_id)
	if status in ["active", "in_review"]:
		# Monitor ongoing session
		if submit_job_manager:
			SingletonObject.create_toast_notification(
				"Session is ongoing - monitoring it now",
				ToastNotification.Type.INFO
			)
	
	# Open Kanban board for this session (if saved state exists)
	_open_session_kanban_board(session_id)
	
	# Switch to Jobs tab (index 0)
	var tab_container = get_node("TabContainer") as TabContainer
	if tab_container:
		tab_container.current_tab = 0
	
	# Auto-select the session in SubmitJob
	if submit_job_manager:
		submit_job_manager._auto_select_session(session_id)
	
	SingletonObject.create_toast_notification(
		"Session selected - ready to continue",
		ToastNotification.Type.SUCCESS
	)


func _get_session_status(session_id: String) -> String:
	"""Get the current status of a session"""
	if not autocoder_adapter:
		return "unknown"
	
	var sessions = await autocoder_adapter.list_sessions()
	for session in sessions:
		if session is Dictionary and str(session.get("session_id", "")) == session_id:
			return str(session.get("status", "unknown")).to_lower()
	
	return "unknown"


func _check_and_sync_session(session_id: String, kanban) -> void:
	"""Check backend status and sync missed updates when reopening a session"""
	if not autocoder_adapter:
		return
	
	var user_id = Core.client.client_id
	var session_info = await autocoder_adapter.get_session_info(session_id)
	
	if session_info.is_empty():
		info("No session info available from backend for: %s" % session_id)
		return
	
	var status = session_info.get("status", "unknown")
	var backend_hash = session_info.get("plan_hash", "")
	
	# Check if session is still processing
	if status == "processing":
		# Session is still processing - re-subscribe to updates
		var notification_topics = [
			"autocoder-orchestrator/planning/%s/%s" % [user_id, session_id],
			"autocoder-orchestrator/actions/%s/%s" % [user_id, session_id],
			"autocoder-orchestrator/llm-traffic/%s/%s" % [user_id, session_id]
		]
		monitor_session(user_id, session_id, notification_topics)
		SingletonObject.create_toast_notification(
			"Session is still processing - subscribed to updates",
			ToastNotification.Type.INFO
		)
		return
	
	# Check if backend has updates we missed (hash mismatch)
	if not backend_hash.is_empty() and kanban.task_store:
		var local_hash = kanban.task_store.last_backend_hash
		
		if backend_hash != local_hash:
			# Backend has updates we missed
			SingletonObject.create_toast_notification(
				"Backend has updates for this session - syncing Kanban board",
				ToastNotification.Type.INFO
			)
			await _sync_kanban_from_backend(session_id, kanban)
		else:
			info("Kanban board is in sync with backend (hash: %s)" % backend_hash.substr(0, 8))


func _sync_kanban_from_backend(session_id: String, kanban) -> void:
	"""Sync Kanban board with backend plan when hash mismatch detected"""
	if not autocoder_adapter or not kanban or not kanban.task_store:
		return
	
	var session_info = await autocoder_adapter.get_session_info(session_id)
	if session_info.is_empty():
		return
	
	var plan = session_info.get("plan", {})
	var backend_tasks = plan.get("tasks", [])
	var backend_hash = plan.get("hash", "")
	
	if backend_tasks.is_empty():
		info("No tasks in backend plan to sync")
		return
	
	# Clear existing tasks and add backend tasks
	var task_store = kanban.task_store
	for task in task_store.get_all_tasks():
		task_store.delete_task(task.id)
	
	# Add backend tasks
	for task_data in backend_tasks:
		var task = AutocoderTask.new()
		task.id = task_data.get("id", "")
		task.title = task_data.get("title", "")
		task.description = task_data.get("description", "")
		task.status = AutocoderTask.TaskStatus.PLAN  # All synced tasks start in PLAN
		task.source_type = AutocoderTask.SourceType.AGENT_TOOL
		task.metadata["plan_task_id"] = task.id
		task_store.add_task(task)
	
	# Update backend hash
	task_store.last_backend_hash = backend_hash
	
	info("Synced %d tasks from backend to Kanban board" % backend_tasks.size())


func _open_session_kanban_board(session_id: String) -> void:
	"""Open or focus Kanban board for a session, loading saved state if it exists"""
	if not SingletonObject.editor_pane:
		return
	
	# Check if saved kanban state exists
	var save_path = "user://autocoder_kanban/%s.json" % session_id
	if not FileAccess.file_exists(save_path):
		print("[AutocoderManager] No saved kanban state found for session: %s" % session_id)
		return
	
	# Check if board is already open
	for editor in SingletonObject.editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN:
			var kanban = editor.kanban_board
			if kanban and kanban.get_meta("session_id", "") == session_id:
				# Board already open, just switch to its tab
				var tab_index = editor.get_index()
				if SingletonObject.editor_pane.Tabs:
					SingletonObject.editor_pane.Tabs.current_tab = tab_index
				print("[AutocoderManager] Focused existing kanban board for session: %s" % session_id)
				return
	
	# Create new kanban board
	var kanban_editor: Editor = SingletonObject.editor_pane.add(
		Editor.Type.KANBAN,
		null,
		"Session: %s" % session_id.substr(0, 12)
	)
	
	if kanban_editor and kanban_editor.kanban_board:
		var kanban = kanban_editor.kanban_board
		kanban.set_meta("session_id", session_id)
		kanban.set_meta("user_id", Core.client.client_id)
		
		# Set session_id THEN load saved state (must be in this order since _ready() already ran)
		if kanban.task_store:
			kanban.task_store.session_id = session_id
			kanban.load_saved_state()
			print("[AutocoderManager] Loaded kanban state for session: %s (%d tasks)" % [
				session_id, kanban.task_store.get_all_tasks().size()
			])
			
			# Check backend status and sync if needed
			await _check_and_sync_session(session_id, kanban)
