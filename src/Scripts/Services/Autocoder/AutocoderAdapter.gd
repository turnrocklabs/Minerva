class_name AutocoderAdapter
extends BaseServiceAdapter


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

func generate(prompt: String, session_id: String = "", input_archive_uri: String = "", require_permission: = false) -> GenerationOutput:
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
	
	var msg = await Core.send_message(service, action, data).receive()

	if not msg or msg.get("cmd") == "error":
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

	var data := {}
	if not status_filter.is_empty():
		data["status"] = status_filter

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		# SingletonObject.ErrorDisplay("Autocoder Sessions Error", "No response from server")
		return []

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list sessions")
		SingletonObject.ErrorDisplay("Autocoder Sessions Error", error_msg)
		return []

	var result_sessions = safe_extract(msg, ["params", "result", "sessions"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])

	# Convert to Array[Dictionary]
	for session_data in result_sessions:
		if session_data is Dictionary:
			sessions.append(session_data)

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


## Create a review agent
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

	return safe_extract(msg, ["params", "result", "agent_id"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_STRING], "")


## List all review agents for the current user
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


## Get review agents (same result shape as list)
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


## Update a review agent (send only fields that should change)
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

	var msg = await Core.send_message(service, action, data).receive()

	if not msg:
		SingletonObject.ErrorDisplay("Review Agent Update Error", "No response from server")
		return false

	if msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to update review agent")
		SingletonObject.ErrorDisplay("Review Agent Update Error", error_msg)
		return false

	return safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)


## Delete a review agent by ID
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

	return safe_extract(msg, ["params", "result", "success"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_BOOL], false)
