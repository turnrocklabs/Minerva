class_name AutocoderAdapter
extends BaseServiceAdapter

signal review_agents_changed
signal review_presets_changed

var _agent_registry: AgentRegistry

## Typed agent registry — wraps the raw dict CRUD methods below.
var agent_registry: AgentRegistry:
	get:
		if _agent_registry == null:
			_agent_registry = AgentRegistry.new(self)
		return _agent_registry


class GenerationOutput extends RefCounted:
	var session_id: String
	var message: String
	var notification_topics: Array[String]
	var status: String
	var user_id: String
	var iteration: float

	func _init(
		sid: String,
		msg: String,
		notif_topics: Array[String],
		output_status: String,
		output_user_id: String,
		ouput_iteration: float
	) -> void:
		session_id = sid
		message = msg
		notification_topics = notif_topics
		status = output_status
		user_id = output_user_id
		iteration = ouput_iteration



# {
#     "cmd": "response",
#     "params": {
#         "client_id": "678dd438-6d80-4109-948c-cb1422ce1969",
#         "request_id": "019a5559-282a-72c2-b18b-8513de37e6dc",
#         "result": {
#             "iteration": 0.0,
#             "message": "Code generation started. Subscribe to notification topics for completion updates.",
#             "notification_topics": [
#                 "autocoder-orchestrator/iteration/678dd438-6d80-4109-948c-cb1422ce1969/*",
#                 "autocoder-orchestrator/iteration/678dd438-6d80-4109-948c-cb1422ce1969/ses_5aaa6d665ffeDGwbbZwNCXVAi3"
#             ],
#             "session_id": "ses_5aaa6d665ffeDGwbbZwNCXVAi3",
#             "status": "processing",
#             "user_id": "678dd438-6d80-4109-948c-cb1422ce1969"
#         }
#     },
#     "topic": "autocoder/generate"
# }

func generate(prompt: String, session_id: String = "", input_archive_uri: String = "", require_permission: bool = false, model: String = "", review_agent_ids: Array = [], use_plan_tasks: bool = false, plan_task_ids: Array = [], auto_review: bool = false, review_model: String = "", task_model_overrides: Dictionary = {}) -> GenerationOutput:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't start autocoder. Core not connected")
		return null

	var action: = get_action("autocoder/generate")

	var data: = {
		"prompt": prompt,
		"require_permission": require_permission,
	}

	if not session_id.is_empty():
		data["session_id"] = session_id

	if not input_archive_uri.is_empty():
		data["input_archive_uri"] = input_archive_uri

	if not model.is_empty():
		data["model"] = model

	if not review_agent_ids.is_empty():
		data["review_agent_ids"] = review_agent_ids
	if auto_review:
		data["auto_review"] = true
	
	if use_plan_tasks:
		data["use_plan_tasks"] = true
		if not plan_task_ids.is_empty():
			data["plan_task_ids"] = plan_task_ids

	if not review_model.is_empty():
		data["review_model"] = review_model

	if not task_model_overrides.is_empty():
		data["task_model_overrides"] = task_model_overrides

	# Use longer timeout for code generation (can take several minutes)
	var msg = await Core.send_message(service, action, data).with_timeout(600.0).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Autocoder Error", "No response from server - request may have timed out or connection lost")
		return null
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to start a session")
		SingletonObject.ErrorDisplay("Autocoder Error", error_msg)
		return null

	var sid = safe_extract(msg, ["params", "result", "session_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var iteration = safe_extract(msg, ["params", "result", "iteration"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0.0)
	var message = safe_extract(msg, ["params", "result", "message"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	
	var notification_topics: Array[String]
	notification_topics.assign(safe_extract(msg, ["params", "result", "notification_topics"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], []))

	var status = safe_extract(msg, ["params", "result", "status"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var user_id = safe_extract(msg, ["params", "result", "user_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")

	return GenerationOutput.new(
		sid,
		message,
		notification_topics,
		status,
		user_id,
		iteration,
	)


## Respond to a permission request (approve or reject)
func respond_permission(permission_id: String, response: String) -> bool:
	if not Core.client._connected:
		push_warning("Cannot respond to permission - Core not connected")
		return false

	var normalized = response.strip_edges().to_lower()
	if normalized != "approve" and normalized != "reject":
		push_warning("Invalid permission response: %s" % response)
		return false

	var msg := {
		"cmd": "response",
		"topic": "autocoder/permission",
		"params": {
			"client_id": Core.client.client_id,
			"request_id": permission_id,
			"result": {
				"response": normalized
			}
		}
	}

	Core.client.send_message_to_core(msg)
	return true


## Cleanup workspace before starting a new session
## @param deep_clean: If true, removes ALL files including hidden ones
func cleanup(deep_clean: bool = true) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't cleanup workspace. Core not connected")
		return false

	var action := get_action("autocoder/cleanup")

	var data := {
		"deep_clean": deep_clean
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Autocoder Cleanup Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to cleanup workspace")
		SingletonObject.ErrorDisplay("Autocoder Cleanup Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	var message = safe_extract(msg, ["params", "result", "message"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")

	if success:
		SingletonObject.create_toast_notification(message if not message.is_empty() else "Workspace cleaned successfully", ToastNotification.Type.SUCCESS)

	return success


## List all sessions for the current user
## @param status: Optional filter by status ("complete", "in_review", "error", etc.)
func list_sessions(status_filter: String = "") -> Array[Dictionary]:
	var sessions: Array[Dictionary] = []

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't list sessions. Core not connected")
		return sessions

	var action := get_action("autocoder/list-sessions")
	print("[AutocoderAdapter] list_sessions: action = %s" % (action.name if action else "null"))

	var data := {}
	if not status_filter.is_empty():
		data["status"] = status_filter

	var msg = await Core.send_message(service, action, data).receive()
	print("[AutocoderAdapter] list_sessions: received message, cmd = %s" % (msg.get("cmd") if msg else "null"))

	if not msg:
		# SingletonObject.ErrorDisplay("Autocoder Sessions Error", "No response from server")
		return []

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list sessions")
		SingletonObject.ErrorDisplay("Autocoder Sessions Error", error_msg)
		return []

	var result_sessions = safe_extract(msg, ["params", "result", "sessions"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])
	print("[AutocoderAdapter] list_sessions: extracted %d sessions from result" % result_sessions.size())

	# Convert to Array[Dictionary]
	for session_data in result_sessions:
		if session_data is Dictionary:
			print("[AutocoderAdapter] list_sessions: adding session %s" % session_data.get("session_id", "unknown"))
			sessions.append(session_data)

	print("[AutocoderAdapter] list_sessions: returning %d sessions" % sessions.size())
	return sessions


## Get full session history with all iterations
## @param session_id: The session ID to fetch
func get_session_history(session_id: String) -> Dictionary:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't get session history. Core not connected")
		return {}

	var action := get_action("autocoder/get-session-history")

	var data := {
		"session_id": session_id
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Autocoder Session Error", "No response from server")
		return {}

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get session history")
		SingletonObject.ErrorDisplay("Autocoder Session Error", error_msg)
		return {}

	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})

	return result


## Approve a session (marks it as complete)
## User is satisfied with the generated code
## @param user_id: The user ID
## @param session_id: The session to approve
func approve(user_id: String, session_id: String) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't approve session. Core not connected")
		return false

	var action := get_action("autocoder/approve")

	var data := {
		"user_id": user_id,
		"session_id": session_id
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Approve Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to approve session")
		SingletonObject.ErrorDisplay("Approve Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	var message = safe_extract(msg, ["params", "result", "message"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")

	if success:
		SingletonObject.create_toast_notification(message if not message.is_empty() else "Session approved successfully", ToastNotification.Type.SUCCESS)

	return success


## Request a revision for a session (user wants changes)
## @param user_id: The user ID
## @param session_id: The session to request revision for
## @param feedback: Description of what needs to change
func request_revision(user_id: String, session_id: String, feedback: String) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't request revision. Core not connected")
		return false

	var action := get_action("autocoder/request-revision")

	var data := {
		"user_id": user_id,
		"session_id": session_id,
		"feedback": feedback,
		"requester_id": user_id
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Revision Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to request revision")
		SingletonObject.ErrorDisplay("Revision Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	var message = safe_extract(msg, ["params", "result", "message"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")

	if success:
		SingletonObject.create_toast_notification(message if not message.is_empty() else "Revision requested successfully", ToastNotification.Type.SUCCESS)

	return success


## Get available review models for AI code review
## Returns array of {id, description, enabled} dictionaries
func get_review_models() -> Array[Dictionary]:
	var models: Array[Dictionary] = []

	if not Core.client._connected:
		return models

	var action := get_action("autocoder/get-review-models")
	if not action:
		return models

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		return models

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get review models")
		push_warning("Get review models error: %s" % error_msg)
		return models

	var result_models = safe_extract(msg, ["params", "result", "models"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for model_data in result_models:
		if model_data is Dictionary:
			models.append(model_data)

	return models


## Get available generation models for Autocoder sessions
## Returns array of {id, name} dictionaries
func list_generation_models() -> Array[Dictionary]:
	var models: Array[Dictionary] = []

	if not Core.client._connected:
		push_warning("Cannot list models - Core not connected")
		return models

	# Try to get action, with retry if service not discovered yet
	var action := _get_generation_models_action()
	if not action:
		# Wait a bit for service discovery, then retry
		await Engine.get_main_loop().process_frame
		await Engine.get_main_loop().process_frame
		action = _get_generation_models_action()
	
	if not action:
		push_warning("List generation models action not found. Service may not be discovered yet.")
		# Log available actions for debugging
		if service and service.actions:
			var available_topics = []
			for a in service.actions:
				if a:
					available_topics.append(a.topic)
			push_warning("Available autocoder actions: %s" % str(available_topics))
		return models

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		push_warning("No response when listing generation models")
		return models

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get generation models")
		push_warning("List generation models error: %s" % error_msg)
		return models

	# Extract models with more debugging
	var params = msg.get("params", {})
	if not params is Dictionary:
		push_warning("List generation models: params is not a Dictionary")
		return models
	
	var result = params.get("result", {})
	if not result is Dictionary:
		push_warning("List generation models: result is not a Dictionary")
		return models
	
	var result_models = result.get("models", [])
	if not result_models is Array:
		push_warning("List generation models: models is not an Array, got: %s" % typeof(result_models))
		return models

	if result_models.is_empty():
		push_warning("List generation models returned empty array")
		return models

	for model_data in result_models:
		if model_data is Dictionary:
			models.append(model_data)

	print("[AutocoderAdapter] ✓ Loaded %d generation models" % models.size())
	return models


func _get_generation_models_action() -> Action:
	# Use the single, canonical topic exposed by the backend
	var topic := "autocoder/list-generation-models"
	var action = get_action(topic)
	if action:
		print("[AutocoderAdapter] ✓ Found action for topic: %s (name: %s)" % [topic, action.name])
		return action

	# Debug: Log all available actions to see what we have
	if service:
		if not service.actions:
			print("[AutocoderAdapter] ✗ Service has no actions array - service may not be discovered yet")
		else:
			print("[AutocoderAdapter] Service has %d actions:" % service.actions.size())
			for svc_action in service.actions:
				if not svc_action:
					continue
				# Actions are always Action objects (not dictionaries)
				var action_name = str(svc_action.name) if svc_action.name else "(no name)"
				var action_topic = str(svc_action.topic) if svc_action.topic else "(no topic)"
				print("    [%s] topic: %s" % [action_name, action_topic])
				
				# Try to find by topic match (case-insensitive fallback)
				var topic_lower = action_topic.to_lower()
				if not topic_lower.begins_with("autocoder/"):
					continue
				if "model" in topic_lower and "review" not in topic_lower:
					print("[AutocoderAdapter] ✓ Found matching action via search: %s" % action_topic)
					return svc_action
	else:
		print("[AutocoderAdapter] ✗ Service is null - adapter not initialized")

	print("[AutocoderAdapter] ✗ No generation models action found")
	return null


## Request another AI review for a session (max 5 reviews)
## @param user_id: The user ID
## @param session_id: The session to review
## @param custom_prompt: Optional custom prompt to guide the AI review (applies to all models)
## @param models: Optional array of model IDs to use for review
## @param auto_fix: Whether to automatically apply fixes
## @param custom_prompts: Optional dictionary of per-model custom prompts {model_id: prompt}
func request_review(user_id: String, session_id: String, custom_prompt: String = "", models: Array = [], auto_fix: bool = false, custom_prompts: Dictionary = {}) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't request review. Core not connected")
		return false

	var action := get_action("autocoder/request-review")

	var data := {
		"user_id": user_id,
		"session_id": session_id
	}

	if not custom_prompt.is_empty():
		data["custom_prompt"] = custom_prompt

	if not models.is_empty():
		data["models"] = models

	if auto_fix:
		data["auto_fix"] = true

	if not custom_prompts.is_empty():
		data["custom_prompts"] = custom_prompts

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Request Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to request review")
		SingletonObject.ErrorDisplay("Review Request Error", error_msg)
		return false

	# Backend returns "approved" field, not "success"
	var approved = safe_extract(msg, ["params", "result", "approved"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	var summary = safe_extract(msg, ["params", "result", "summary"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	var reviews_remaining = safe_extract(msg, ["params", "result", "reviews_remaining"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_FLOAT], 0)

	# Treat any non-error response as a successful request so callers can clear UI state even if the verdict isn't "approved"
	if approved:
		var msg_text = summary if not summary.is_empty() else "Review requested successfully"
		if reviews_remaining > 0:
			msg_text += " (%d reviews remaining)" % int(reviews_remaining)
		SingletonObject.create_toast_notification(msg_text, ToastNotification.Type.SUCCESS)
	elif not summary.is_empty():
		SingletonObject.create_toast_notification(summary, ToastNotification.Type.INFO)

	return true


## Create a review agent (low-level Core transport).
## Prefer agent_registry.register() for typed access.
## @param name: Agent name (required)
## @param prompt: Agent prompt (required)
## @param setup_commands: Optional setup commands list
## @param model: Optional model id (server default if empty)
## @param tools_enabled: Whether tools are enabled for this agent
func create_review_agent(name: String, prompt: String, setup_commands: Array = [], model: String = "", tools_enabled: bool = false) -> String:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't create review agent. Core not connected")
		return ""

	var action := get_action("autocoder/review-agent/create")
	if not action:
		push_warning("Create review agent action not found")
		return ""

	var data := {
		"name": name,
		"prompt": prompt,
		"tools_enabled": tools_enabled
	}

	if not setup_commands.is_empty():
		data["setup_commands"] = setup_commands

	if not model.is_empty():
		data["model"] = model

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent Create Error", "No response from server")
		return ""

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to create review agent")
		SingletonObject.ErrorDisplay("Review Agent Create Error", error_msg)
		return ""

	var agent_id = safe_extract(msg, ["params", "result", "agent_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	if not agent_id.is_empty():
		review_agents_changed.emit()
	return agent_id


## List all review agents for the current user (low-level Core transport).
## Prefer agent_registry.list_agents() for typed access.
func list_review_agents() -> Array[Dictionary]:
	var agents: Array[Dictionary] = []

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't list review agents. Core not connected")
		return agents

	var action := get_action("autocoder/review-agent/list")
	if not action:
		push_warning("List review agents action not found")
		return agents

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent List Error", "No response from server")
		return agents

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list review agents")
		SingletonObject.ErrorDisplay("Review Agent List Error", error_msg)
		return agents

	var result_agents = safe_extract(msg, ["params", "result", "agents"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for agent_data in result_agents:
		if agent_data is Dictionary:
			agents.append(agent_data)

	return agents


## Get review agents (same result shape as list, low-level Core transport).
## Prefer agent_registry.list_agents() for typed access.
func get_review_agents() -> Array[Dictionary]:
	var agents: Array[Dictionary] = []

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't get review agents. Core not connected")
		return agents

	var action := get_action("autocoder/review-agent/get")
	if not action:
		push_warning("Get review agents action not found")
		return agents

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent Get Error", "No response from server")
		return agents

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get review agents")
		SingletonObject.ErrorDisplay("Review Agent Get Error", error_msg)
		return agents

	var result_agents = safe_extract(msg, ["params", "result", "agents"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for agent_data in result_agents:
		if agent_data is Dictionary:
			agents.append(agent_data)

	return agents


## Update a review agent (send only fields that should change, low-level Core transport).
## Prefer agent_registry.update() for typed access.
func update_review_agent(agent_id: String, name: String = "", prompt: String = "", setup_commands: Variant = null, model: String = "", tools_enabled: Variant = null) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't update review agent. Core not connected")
		return false

	var action := get_action("autocoder/review-agent/update")
	if not action:
		push_warning("Update review agent action not found")
		return false

	var data := {
		"agent_id": agent_id
	}

	if not name.is_empty():
		data["name"] = name

	if not prompt.is_empty():
		data["prompt"] = prompt

	if setup_commands != null:
		data["setup_commands"] = setup_commands

	if not model.is_empty():
		data["model"] = model

	if tools_enabled != null:
		data["tools_enabled"] = tools_enabled

	print("[ReviewAgent Update] Sending data: %s" % str(data))
	var msg = await Core.send_message(service, action, data).receive()
	print("[ReviewAgent Update] Response: %s" % str(msg))

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent Update Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "")
		if error_msg.is_empty():
			error_msg = str(msg.get("params", {}))
		SingletonObject.ErrorDisplay("Review Agent Update Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	if not success:
		SingletonObject.ErrorDisplay("Review Agent Update Error", "Server returned success=false. Response: %s" % str(msg.get("params", {})))
	else:
		review_agents_changed.emit()
	return success


## Delete a review agent by ID (low-level Core transport).
## Prefer agent_registry.delete() for typed access.
func delete_review_agent(agent_id: String) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't delete review agent. Core not connected")
		return false

	var action := get_action("autocoder/review-agent/delete")
	if not action:
		push_warning("Delete review agent action not found")
		return false

	var msg = await Core.send_message(service, action, {"agent_id": agent_id}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent Delete Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete review agent")
		SingletonObject.ErrorDisplay("Review Agent Delete Error", error_msg)
		return false

	var del_success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	if del_success:
		review_agents_changed.emit()
	return del_success


## Update a review agent's order (execution priority)
func update_review_agent_order(agent_id: String, order: int) -> bool:
	if not Core.client._connected:
		push_warning("Can't update review agent order. Core not connected")
		return false

	var action := get_action("autocoder/review-agent/update")
	if not action:
		push_warning("Update review agent action not found")
		return false

	var data := {
		"agent_id": agent_id,
		"order": order
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		push_warning("Review Agent Order Update Error: No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to update order")
		push_warning("Review Agent Order Update Error: %s" % error_msg)
		return false

	return safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)


## Create a review agent preset (named group of agent IDs)
func create_review_preset(name: String, agent_ids: Array) -> String:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't create review preset. Core not connected")
		return ""

	var action := get_action("autocoder/review-preset/create")
	if not action:
		push_warning("Create review preset action not found")
		return ""

	var data := {
		"name": name,
		"agent_ids": agent_ids
	}

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Preset Create Error", "No response from server")
		return ""

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to create review preset")
		SingletonObject.ErrorDisplay("Review Preset Create Error", error_msg)
		return ""

	var preset_id = safe_extract(msg, ["params", "result", "preset_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")
	if not preset_id.is_empty():
		review_presets_changed.emit()
	return preset_id


## List all review agent presets
func list_review_presets() -> Array[Dictionary]:
	var presets: Array[Dictionary] = []

	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't list review presets. Core not connected")
		return presets

	var action := get_action("autocoder/review-preset/list")
	if not action:
		push_warning("List review presets action not found")
		return presets

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Preset List Error", "No response from server")
		return presets

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list review presets")
		SingletonObject.ErrorDisplay("Review Preset List Error", error_msg)
		return presets

	var result_presets = safe_extract(msg, ["params", "result", "presets"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for preset_data in result_presets:
		if preset_data is Dictionary:
			presets.append(preset_data)

	return presets


## Update a review agent preset
func update_review_preset(preset_id: String, name: String = "", agent_ids: Array = []) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't update review preset. Core not connected")
		return false

	var action := get_action("autocoder/review-preset/update")
	if not action:
		push_warning("Update review preset action not found")
		return false

	var data := {
		"preset_id": preset_id
	}

	if not name.is_empty():
		data["name"] = name

	if not agent_ids.is_empty():
		data["agent_ids"] = agent_ids

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Preset Update Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to update review preset")
		SingletonObject.ErrorDisplay("Review Preset Update Error", error_msg)
		return false

	var success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	if success:
		review_presets_changed.emit()
	return success


## Delete a review agent preset
func delete_review_preset(preset_id: String) -> bool:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't delete review preset. Core not connected")
		return false

	var action := get_action("autocoder/review-preset/delete")
	if not action:
		push_warning("Delete review preset action not found")
		return false

	var msg = await Core.send_message(service, action, {"preset_id": preset_id}).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Preset Delete Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete review preset")
		SingletonObject.ErrorDisplay("Review Preset Delete Error", error_msg)
		return false

	var del_success = safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
	if del_success:
		review_presets_changed.emit()
	return del_success


## Generate a development plan from prompt (planning mode)
## @param prompt: The planning prompt
## @param session_id: Optional session ID to continue planning
## @param input_archive_uri: Optional artifact URI of existing project to analyze
## @param model: Optional model to use for planning
## @param modify_request: Optional request to modify existing plan
class PlanningOutput extends RefCounted:
	var session_id: String
	var tasks: Array[Dictionary]
	var questions: Array[Dictionary]
	var status: String
	var message: String
	var notification_topics: Array[String]
	var user_id: String
	var plan_hash: String

	func _init(
		sid: String,
		output_tasks: Array[Dictionary],
		output_questions: Array[Dictionary],
		output_status: String,
		output_message: String,
		notif_topics: Array[String],
		output_user_id: String,
		output_plan_hash: String = ""
	) -> void:
		session_id = sid
		tasks = output_tasks
		questions = output_questions
		status = output_status
		message = output_message
		notification_topics = notif_topics
		user_id = output_user_id
		plan_hash = output_plan_hash

func plan(prompt: String, session_id: String = "", input_archive_uri: String = "", model: String = "", modify_request: String = "", kanban_state: Dictionary = {}, kanban_hash: String = "") -> PlanningOutput:
	if not Core.client._connected:
		SingletonObject.create_toast_notification("Can't start planning. Core not connected")
		return null

	var action: = get_action("autocoder/plan")
	if not action:
		SingletonObject.ErrorDisplay("Planning Error", "Planning action not available")
		return null

	var data: = {
		"prompt": prompt,
	}

	if not session_id.is_empty():
		data["session_id"] = session_id

	if not input_archive_uri.is_empty():
		data["input_archive_uri"] = input_archive_uri

	if not model.is_empty():
		data["model"] = model

	if not modify_request.is_empty():
		data["modify_request"] = modify_request
	
	if not kanban_state.is_empty():
		data["kanban_state"] = kanban_state
	
	if not kanban_hash.is_empty():
		data["kanban_hash"] = kanban_hash
	
	# Use longer timeout for planning (can take several minutes with complex prompts)
	var msg = await Core.send_message(service, action, data).with_timeout(300.0).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Planning Error", "No response from server - request may have timed out or connection lost")
		return null
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to start planning")
		SingletonObject.ErrorDisplay("Planning Error", error_msg)
		return null

	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})
	var sid = safe_extract(result, ["session_id"], [TYPE_STRING], "")
	var tasks = safe_extract(result, ["tasks"], [TYPE_ARRAY], [])
	var questions = safe_extract(result, ["questions"], [TYPE_ARRAY], [])
	var status = safe_extract(result, ["status"], [TYPE_STRING], "planning")
	var message = safe_extract(result, ["message"], [TYPE_STRING], "")
	var plan_hash = safe_extract(result, ["plan_hash"], [TYPE_STRING], "")
	
	var notification_topics: Array[String]
	notification_topics.assign(safe_extract(result, ["notification_topics"], [TYPE_ARRAY], []))

	var user_id = safe_extract(result, ["user_id"], [TYPE_STRING], Core.client.client_id)

	# If status is "planning", this is just the ACK - actual results will come via notifications
	if status == "planning":
		print("[AutocoderAdapter] Received planning ACK - tasks will arrive via notification topic")
		# Return with empty tasks - they'll be populated from notification
		return PlanningOutput.new(
			sid,
			[],  # Empty tasks array - will be filled by notification
			[],  # Empty questions array - will be filled by notification
			status,
			message,
			notification_topics,
			user_id,
			plan_hash
		)

	# Convert tasks and questions to Array[Dictionary]
	var tasks_array: Array[Dictionary] = []
	for task_data in tasks:
		if task_data is Dictionary:
			tasks_array.append(task_data)

	var questions_array: Array[Dictionary] = []
	for question_data in questions:
		if question_data is Dictionary:
			questions_array.append(question_data)

	return PlanningOutput.new(
		sid,
		tasks_array,
		questions_array,
		status,
		message,
		notification_topics,
		user_id,
		plan_hash
	)

## Answer a question from the autocoder (planning mode clarification)
## @param session_id: The session ID the question belongs to
## @param question_id: The question ID to answer
## @param answer: The user's answer (empty string means "skip - let autocoder decide")
func answer_question(session_id: String, question_id: String, answer: String) -> bool:
	print("[AutocoderAdapter] ========== ANSWER_QUESTION CALLED ==========")
	print("[AutocoderAdapter] Session: %s" % session_id)
	print("[AutocoderAdapter] Question ID: %s" % question_id)
	print("[AutocoderAdapter] Answer: %s" % answer)
	print("[AutocoderAdapter] Core connected: %s" % Core.client._connected)
	
	if not Core.client._connected:
		push_warning("Can't answer question - Core not connected")
		return false

	var action := get_action("autocoder/answer-question")
	print("[AutocoderAdapter] Action found: %s" % (action != null))
	if action:
		print("[AutocoderAdapter] Action topic: %s" % action.topic)
	
	if not action:
		push_warning("[AutocoderAdapter] answer-question action not available")
		return false

	var data := {
		"session_id": session_id,
		"question_id": question_id,
		"answer": answer,
		"skipped": answer.is_empty()
	}

	# Use longer timeout - answering questions can trigger planning continuation
	var msg = await Core.send_message(service, action, data).with_timeout(120.0).receive()

	if not msg:
		push_warning("No response when answering question - may have timed out")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to answer question")
		push_warning("Answer question error: %s" % error_msg)
		var lowered = error_msg.to_lower()
		if lowered.find("not found") != -1 or lowered.find("already") != -1:
			return true
		return false

	return true


## Inject additional context into a planning session
## @param session_id: The session ID to inject context into
## @param content: The context text to inject
## @param context_type: "text" (user-typed) or "notes" (from notes panel)
func inject_context(session_id: String, content: String, context_type: String = "text") -> bool:
	if not Core.client._connected:
		push_warning("Can't inject context - Core not connected")
		return false

	var action := get_action("autocoder/inject-context")
	if not action:
		push_warning("[AutocoderAdapter] inject-context action not available")
		return false

	var data := {
		"session_id": session_id,
		"content": content,
		"context_type": context_type
	}

	# Use longer timeout — may trigger a re-plan
	var msg = await Core.send_message(service, action, data).with_timeout(120.0).receive()

	if not msg:
		push_warning("No response when injecting context - may have timed out")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to inject context")
		push_warning("Inject context error: %s" % error_msg)
		return false

	return true


func get_session_info(session_id: String) -> Dictionary:
	"""Get session metadata including prompt, plan, questions, and name"""
	if not Core.client._connected:
		return {}
	
	var action = get_action("autocoder/get-session-info")
	if not action:
		push_warning("[AutocoderAdapter] get-session-info action not available")
		return {}
	
	var data = {"session_id": session_id}
	var msg = await Core.send_message(service, action, data).receive()
	
	if not msg:
		return {}
	
	if msg.get("cmd") == "error":
		return {}
	
	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})
	return result


func delete_session(session_id: String) -> Dictionary:
	"""Delete a session and all its artifacts
	
	Returns:
		Dictionary with keys:
			- success: bool
			- message: String
			- deleted_artifacts: Array[String] (list of deleted artifact URIs)
	"""
	if not Core.client._connected:
		return {"success": false, "message": "Not connected"}
	
	var action = get_action("autocoder/delete-session")
	if not action:
		push_warning("[AutocoderAdapter] delete-session action not available")
		return {"success": false, "message": "Delete action not available"}
	
	var data = {"session_id": session_id}
	var msg = await Core.send_message(service, action, data).receive()
	
	if not msg:
		return {"success": false, "message": "No response from server"}
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete session")
		return {"success": false, "message": error_msg}
	
	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})
	
	# Also delete local Kanban file if it exists
	_delete_local_kanban_file(session_id)
	
	return result


func delete_all_sessions() -> Dictionary:
	"""Delete ALL sessions for the current user using backend endpoint
	
	Returns:
		Dictionary with keys:
			- success: bool
			- deleted_count: int
			- message: String
	"""
	if not Core.client._connected:
		return {"success": false, "deleted_count": 0, "message": "Not connected"}
	
	var action = get_action("autocoder/delete-all-sessions")
	if not action:
		push_warning("[AutocoderAdapter] delete-all-sessions action not available")
		return {"success": false, "deleted_count": 0, "message": "Delete all action not available"}
	
	print("[AutocoderAdapter] Deleting all sessions via backend...")
	var msg = await Core.send_message(service, action, {}).receive()
	
	if not msg:
		return {"success": false, "deleted_count": 0, "message": "No response from server"}
	
	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete all sessions")
		return {"success": false, "deleted_count": 0, "message": error_msg}
	
	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})
	var success = result.get("success", false)
	var deleted_count = result.get("deleted_count", 0)
	var message = result.get("message", "")
	
	# Also clear ALL local Kanban files
	_delete_all_local_kanban_files()
	
	return {
		"success": success,
		"deleted_count": deleted_count,
		"message": message
	}


## Save user-selected models to backend (persisted in Agent Memory)
## @param models: Array of {id: "provider/model", name: "Display Name"}
func save_user_models(models: Array) -> bool:
	if not Core.client._connected:
		push_warning("Can't save user models. Core not connected")
		return false

	var action := get_action("autocoder/user-models/save")
	if not action:
		push_warning("Save user models action not found")
		return false

	var msg = await Core.send_message(service, action, {"models": models}).receive()

	if not msg:
		push_warning("No response when saving user models")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to save user models")
		push_warning("Save user models error: %s" % error_msg)
		return false

	return true


## Get user-saved models from backend
## Returns array of {id, name} dictionaries
func get_user_models() -> Array[Dictionary]:
	var models: Array[Dictionary] = []

	if not Core.client._connected:
		push_warning("Can't get user models. Core not connected")
		return models

	var action := get_action("autocoder/user-models/get")
	if not action:
		push_warning("Get user models action not found")
		return models

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		push_warning("No response when getting user models")
		return models

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get user models")
		push_warning("Get user models error: %s" % error_msg)
		return models

	var result_models = safe_extract(msg, ["params", "result", "models"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	for model_data in result_models:
		if model_data is Dictionary:
			models.append(model_data)

	return models


## Clear all user-saved models from backend
func clear_user_models() -> bool:
	if not Core.client._connected:
		push_warning("Can't clear user models. Core not connected")
		return false

	var action := get_action("autocoder/user-models/clear")
	if not action:
		push_warning("Clear user models action not found")
		return false

	var msg = await Core.send_message(service, action, {}).receive()

	if not msg:
		push_warning("No response when clearing user models")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to clear user models")
		push_warning("Clear user models error: %s" % error_msg)
		return false

	return true


func _delete_local_kanban_file(session_id: String) -> void:
	"""Delete local Kanban save file for a session"""
	var save_path = "user://autocoder_kanban/%s.json" % session_id
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
		print("[AutocoderAdapter] Deleted local Kanban file: %s" % save_path)


func _delete_all_local_kanban_files() -> void:
	"""Delete ALL local Kanban save files"""
	var kanban_dir = "user://autocoder_kanban"
	if DirAccess.dir_exists_absolute(kanban_dir):
		var dir = DirAccess.open(kanban_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and file_name.ends_with(".json"):
					var full_path = kanban_dir + "/" + file_name
					DirAccess.remove_absolute(full_path)
					print("[AutocoderAdapter] Deleted local Kanban file: %s" % file_name)
				file_name = dir.get_next()
			dir.list_dir_end()
		print("[AutocoderAdapter] Cleared all local Kanban files")
