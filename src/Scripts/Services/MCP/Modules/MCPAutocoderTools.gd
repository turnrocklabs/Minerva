class_name MCPAutocoderTools
extends MCPToolModule
## MCP tool module for AutoCoder domain tools.
## Handles code planning, generation, review, approval, session management,
## review agents, and review presets.


func get_tool_names() -> Array[String]:
	return [
		"minerva_autocoder_plan",
		"minerva_autocoder_generate",
		"minerva_autocoder_status",
		"minerva_autocoder_review",
		"minerva_autocoder_approve",
		"minerva_autocoder_answer_question",
		"minerva_autocoder_create_review_agent",
		"minerva_autocoder_list_review_agents",
		"minerva_autocoder_update_review_agent",
		"minerva_autocoder_delete_review_agent",
		"minerva_autocoder_list_sessions",
		"minerva_autocoder_download",
		"minerva_autocoder_create_review_preset",
		"minerva_autocoder_list_review_presets",
		"minerva_autocoder_update_review_preset",
		"minerva_autocoder_delete_review_preset",
	]


func register_tools() -> void:
	server._register_tool("minerva_autocoder_plan",
		"Create or continue a planning session with the AutoCoder. Returns a plan with tasks and optionally questions that need answers before generation can proceed. Use minerva_autocoder_answer_question to respond to any questions.",
		{
			"type": "object",
			"properties": {
				"prompt": {
					"type": "string",
					"description": "The planning prompt describing what you want to build or modify"
				},
				"session_id": {
					"type": "string",
					"description": "Optional session ID to continue an existing planning session"
				},
				"input_archive_uri": {
					"type": "string",
					"description": "Optional URI of an input archive to use as the starting point"
				},
				"model": {
					"type": "string",
					"description": "Optional model override for planning"
				},
				"modify_request": {
					"type": "string",
					"description": "Optional modification request to refine an existing plan"
				}
			},
			"required": ["prompt"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_generate",
		"Start code generation with the AutoCoder. Can create a new session or continue from an existing plan. Returns a session ID for tracking progress. Use minerva_autocoder_status to poll for completion.",
		{
			"type": "object",
			"properties": {
				"prompt": {
					"type": "string",
					"description": "The generation prompt describing what to build"
				},
				"session_id": {
					"type": "string",
					"description": "Optional session ID to continue from (e.g., from a planning session)"
				},
				"input_archive_uri": {
					"type": "string",
					"description": "Optional URI of an input archive to build upon"
				},
				"model": {
					"type": "string",
					"description": "Optional model override for generation"
				},
				"use_plan_tasks": {
					"type": "boolean",
					"description": "Whether to use tasks from the planning phase (default: false)"
				},
				"review_agent_ids": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional list of review agent IDs to run after generation. If any are provided, review runs automatically."
				}
			},
			"required": ["prompt"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_status",
		"Get the current status of an AutoCoder session including generation progress, artifacts, and any available outputs.",
		{
			"type": "object",
			"properties": {
				"session_id": {
					"type": "string",
					"description": "The session ID to check status for"
				}
			},
			"required": ["session_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_review",
		"Request a review of the generated code in an AutoCoder session. Can use custom prompts, specific models, and optionally auto-fix issues found.",
		{
			"type": "object",
			"properties": {
				"session_id": {
					"type": "string",
					"description": "The session ID to review"
				},
				"custom_prompt": {
					"type": "string",
					"description": "Optional custom review prompt"
				},
				"models": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional list of model names to use for review"
				},
				"auto_fix": {
					"type": "boolean",
					"description": "Whether to automatically fix issues found during review (default: false)"
				}
			},
			"required": ["session_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_approve",
		"Approve the generated output of an AutoCoder session, marking it as accepted.",
		{
			"type": "object",
			"properties": {
				"session_id": {
					"type": "string",
					"description": "The session ID to approve"
				}
			},
			"required": ["session_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_answer_question",
		"Answer a question raised during AutoCoder planning. Questions may arise when the planner needs clarification. Pass an empty answer to let the AutoCoder decide.",
		{
			"type": "object",
			"properties": {
				"session_id": {
					"type": "string",
					"description": "The planning session ID"
				},
				"question_id": {
					"type": "string",
					"description": "The ID of the question to answer"
				},
				"answer": {
					"type": "string",
					"description": "Your answer to the question. Empty string means 'let AutoCoder decide'."
				}
			},
			"required": ["session_id", "question_id", "answer"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_create_review_agent",
		"Create a new review agent that can be used to automatically review generated code.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the review agent"
				},
				"prompt": {
					"type": "string",
					"description": "The review prompt/instructions for this agent"
				},
				"setup_commands": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional shell commands to run before review (e.g., install dependencies)"
				},
				"model": {
					"type": "string",
					"description": "Optional model override for this review agent"
				},
				"tools_enabled": {
					"type": "boolean",
					"description": "Whether this agent can use tools during review (default: false)"
				}
			},
			"required": ["name", "prompt"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_list_review_agents",
		"List all configured review agents.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_update_review_agent",
		"Update an existing review agent. Only the provided fields are changed; omitted fields keep their current values.",
		{
			"type": "object",
			"properties": {
				"agent_id": {"type": "string", "description": "ID of the review agent to update"},
				"name": {"type": "string", "description": "New display name (optional)"},
				"prompt": {"type": "string", "description": "New review prompt/instructions (optional)"},
				"setup_commands": {"type": "array", "items": {"type": "string"}, "description": "New setup commands (optional)"},
				"model": {"type": "string", "description": "New model override (optional)"},
				"tools_enabled": {"type": "boolean", "description": "Whether agent can use tools (optional)"}
			},
			"required": ["agent_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_delete_review_agent",
		"Delete a review agent from the registry.",
		{
			"type": "object",
			"properties": {
				"agent_id": {"type": "string", "description": "ID of the review agent to delete"}
			},
			"required": ["agent_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_list_sessions",
		"List AutoCoder sessions, optionally filtered by status.",
		{
			"type": "object",
			"properties": {
				"status_filter": {
					"type": "string",
					"description": "Optional status to filter by (e.g., 'completed', 'in_progress', 'planning')"
				}
			},
			"required": []
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_download",
		"Download an artifact from an AutoCoder session. Returns the file content as base64-encoded data. If no artifact_uri is provided, downloads the latest archive from the specified session.",
		{
			"type": "object",
			"properties": {
				"session_id": {
					"type": "string",
					"description": "The session ID to download from (used to find latest artifact if no URI given)"
				},
				"artifact_uri": {
					"type": "string",
					"description": "Optional specific artifact URI to download. If omitted, downloads the latest archive from the session."
				}
			},
			"required": []
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_create_review_preset",
		"Create a named preset grouping review agent IDs for quick reuse during job submission.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the preset (e.g. 'Godot Review Suite')"
				},
				"agent_ids": {
					"type": "array",
					"items": {"type": "string"},
					"description": "List of review agent IDs to include in this preset"
				}
			},
			"required": ["name", "agent_ids"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_list_review_presets",
		"List all review agent presets.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_update_review_preset",
		"Update an existing review agent preset. Only the provided fields are changed.",
		{
			"type": "object",
			"properties": {
				"preset_id": {
					"type": "string",
					"description": "ID of the preset to update"
				},
				"name": {
					"type": "string",
					"description": "New display name (optional)"
				},
				"agent_ids": {
					"type": "array",
					"items": {"type": "string"},
					"description": "New list of agent IDs (optional)"
				}
			},
			"required": ["preset_id"]
		}
	, "autocoder")

	server._register_tool("minerva_autocoder_delete_review_preset",
		"Delete a review agent preset.",
		{
			"type": "object",
			"properties": {
				"preset_id": {
					"type": "string",
					"description": "ID of the preset to delete"
				}
			},
			"required": ["preset_id"]
		}
	, "autocoder")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_autocoder_plan": return await _autocoder_plan(arguments)
		"minerva_autocoder_generate": return await _autocoder_generate(arguments)
		"minerva_autocoder_status": return await _autocoder_status(arguments)
		"minerva_autocoder_review": return await _autocoder_review(arguments)
		"minerva_autocoder_approve": return await _autocoder_approve(arguments)
		"minerva_autocoder_answer_question": return await _autocoder_answer_question(arguments)
		"minerva_autocoder_create_review_agent": return await _autocoder_create_review_agent(arguments)
		"minerva_autocoder_list_review_agents": return await _autocoder_list_review_agents(arguments)
		"minerva_autocoder_update_review_agent": return await _autocoder_update_review_agent(arguments)
		"minerva_autocoder_delete_review_agent": return await _autocoder_delete_review_agent(arguments)
		"minerva_autocoder_list_sessions": return await _autocoder_list_sessions(arguments)
		"minerva_autocoder_download": return await _autocoder_download(arguments)
		"minerva_autocoder_create_review_preset": return await _autocoder_create_review_preset(arguments)
		"minerva_autocoder_list_review_presets": return await _autocoder_list_review_presets(arguments)
		"minerva_autocoder_update_review_preset": return await _autocoder_update_review_preset(arguments)
		"minerva_autocoder_delete_review_preset": return await _autocoder_delete_review_preset(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _get_autocoder_adapter():
	var mgr = SingletonObject.autocoder_manager
	if not mgr:
		return null
	return mgr.autocoder_adapter


func _get_artifact_adapter():
	var mgr = SingletonObject.autocoder_manager
	if not mgr:
		return null
	return mgr.artifact_registry_adapter


func _autocoder_plan(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var prompt: String = args.get("prompt", "")
	if prompt.is_empty():
		return MCPToolUtils.error("prompt is required")

	var session_id: String = args.get("session_id", "")
	var input_archive_uri: String = args.get("input_archive_uri", "")
	var model: String = args.get("model", "")
	var modify_request: String = args.get("modify_request", "")

	var result = await adapter.plan(prompt, session_id, input_archive_uri, model, modify_request)
	if not result:
		return MCPToolUtils.error("Planning request failed")

	# Sync UI to track this session (same as if user clicked "Start Planning")
	if result.session_id and not result.session_id.is_empty():
		var mgr = SingletonObject.autocoder_manager
		if mgr and mgr.submit_job_manager:
			mgr.submit_job_manager.setup_mcp_session(
				result.session_id, prompt,
				AutocoderSubmitJobManager.AutocoderMode.PLAN,
				input_archive_uri
			)

	var response: Dictionary = {
		"success": true,
		"session_id": result.session_id,
		"status": result.status,
		"message": result.message,
		"tasks": [],
		"questions": []
	}

	if result.tasks:
		for task in result.tasks:
			response["tasks"].append(task if task is Dictionary else str(task))

	if result.questions:
		for q in result.questions:
			response["questions"].append(q if q is Dictionary else str(q))

	if result.notification_topics:
		response["notification_topics"] = []
		for t in result.notification_topics:
			response["notification_topics"].append(str(t))

	return response


func _autocoder_generate(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var prompt: String = args.get("prompt", "")
	if prompt.is_empty():
		return MCPToolUtils.error("prompt is required")

	var session_id: String = args.get("session_id", "")
	var input_archive_uri: String = args.get("input_archive_uri", "")
	var model: String = args.get("model", "")
	var use_plan_tasks: bool = args.get("use_plan_tasks", false)
	var review_agent_ids: Array = args.get("review_agent_ids", [])
	var auto_review: bool = not review_agent_ids.is_empty()

	var result = await adapter.generate(
		prompt, session_id, input_archive_uri, false,
		model, review_agent_ids, use_plan_tasks, [], auto_review
	)
	if not result:
		return MCPToolUtils.error("Generation request failed")

	# Sync UI to track this session (same as if user clicked "Generate Code")
	if result.session_id and not result.session_id.is_empty():
		var mgr = SingletonObject.autocoder_manager
		if mgr and mgr.submit_job_manager:
			mgr.submit_job_manager.setup_mcp_session(
				result.session_id, prompt,
				AutocoderSubmitJobManager.AutocoderMode.CODER,
				input_archive_uri
			)

	return {
		"success": true,
		"session_id": result.session_id,
		"status": result.status,
		"message": result.message,
		"user_id": result.user_id,
		"iteration": result.iteration
	}


func _autocoder_status(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var session_id: String = args.get("session_id", "")
	if session_id.is_empty():
		return MCPToolUtils.error("session_id is required")

	var info = await adapter.get_session_info(session_id)
	if not info or info.is_empty():
		return MCPToolUtils.error("Session not found or status unavailable")

	# Merge cached artifact URIs from the manager
	var mgr = SingletonObject.autocoder_manager
	if mgr:
		if mgr._latest_archive_by_session.has(session_id):
			info["latest_archive_uri"] = mgr._latest_archive_by_session[session_id]
		if mgr._latest_patch_by_session.has(session_id):
			info["latest_patch_uri"] = mgr._latest_patch_by_session[session_id]

		# Include buffered notification events for MCP polling
		var events = mgr.get_session_events(session_id)
		if not events.is_empty():
			info["recent_events"] = events.slice(maxi(0, events.size() - 20))
			# Walk backwards to find the latest iteration status from real-time notifications
			for i in range(events.size() - 1, -1, -1):
				if events[i]["type"] == "iteration":
					info["latest_notification_status"] = events[i]["payload"].get("status", "")
					break

	info["success"] = true
	return info


func _autocoder_review(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var session_id: String = args.get("session_id", "")
	if session_id.is_empty():
		return MCPToolUtils.error("session_id is required")

	var user_id: String = Core.client.client_id
	var custom_prompt: String = args.get("custom_prompt", "")
	var models: Array = args.get("models", [])
	var auto_fix: bool = args.get("auto_fix", false)

	var ok = await adapter.request_review(user_id, session_id, custom_prompt, models, auto_fix)
	if not ok:
		return MCPToolUtils.error("Review request failed")

	return {"success": true, "session_id": session_id, "message": "Review requested"}


func _autocoder_approve(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var session_id: String = args.get("session_id", "")
	if session_id.is_empty():
		return MCPToolUtils.error("session_id is required")

	var user_id: String = Core.client.client_id
	var ok = await adapter.approve(user_id, session_id)
	if not ok:
		return MCPToolUtils.error("Approve request failed")

	return {"success": true, "session_id": session_id, "message": "Session approved"}


func _autocoder_answer_question(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var session_id: String = args.get("session_id", "")
	if session_id.is_empty():
		return MCPToolUtils.error("session_id is required")

	var question_id: String = args.get("question_id", "")
	if question_id.is_empty():
		return MCPToolUtils.error("question_id is required")

	var answer: String = args.get("answer", "")

	var ok = await adapter.answer_question(session_id, question_id, answer)
	if not ok:
		return MCPToolUtils.error("Failed to submit answer")

	return {"success": true, "session_id": session_id, "question_id": question_id, "message": "Answer submitted"}


func _autocoder_create_review_agent(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var agent_name: String = args.get("name", "")
	if agent_name.is_empty():
		return MCPToolUtils.error("name is required")

	var prompt: String = args.get("prompt", "")
	if prompt.is_empty():
		return MCPToolUtils.error("prompt is required")

	var setup_commands: Array = args.get("setup_commands", [])
	var model: String = args.get("model", "")
	var tools_enabled: bool = args.get("tools_enabled", false)

	var agent_id = await adapter.create_review_agent(agent_name, prompt, setup_commands, model, tools_enabled)
	if not agent_id or (agent_id is String and agent_id.is_empty()):
		return MCPToolUtils.error("Failed to create review agent")

	return {"success": true, "agent_id": agent_id, "message": "Review agent created"}


func _autocoder_list_review_agents(_args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var agents = await adapter.list_review_agents()
	return {"success": true, "agents": agents, "count": agents.size()}


func _autocoder_update_review_agent(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var agent_id: String = args.get("agent_id", "")
	if agent_id.is_empty():
		return MCPToolUtils.error("agent_id is required")
	var name: String = args.get("name", "")
	var prompt: String = args.get("prompt", "")
	var setup_commands = args.get("setup_commands", null)
	var model: String = args.get("model", "")
	var tools_enabled = args.get("tools_enabled", null)
	var ok = await adapter.update_review_agent(agent_id, name, prompt, setup_commands, model, tools_enabled)
	if not ok:
		return MCPToolUtils.error("Failed to update review agent")
	return {"success": true, "agent_id": agent_id, "message": "Review agent updated"}


func _autocoder_delete_review_agent(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var agent_id: String = args.get("agent_id", "")
	if agent_id.is_empty():
		return MCPToolUtils.error("agent_id is required")
	var ok = await adapter.delete_review_agent(agent_id)
	if not ok:
		return MCPToolUtils.error("Failed to delete review agent")
	return {"success": true, "agent_id": agent_id, "message": "Review agent deleted"}


func _autocoder_list_sessions(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")

	var status_filter: String = args.get("status_filter", "")
	var sessions = await adapter.list_sessions(status_filter)
	return {"success": true, "sessions": sessions, "count": sessions.size()}


func _autocoder_download(args: Dictionary) -> Dictionary:
	var artifact_adapter = _get_artifact_adapter()
	if not artifact_adapter:
		return MCPToolUtils.error("Artifact registry not connected")

	var artifact_uri: String = args.get("artifact_uri", "")
	var session_id: String = args.get("session_id", "")

	# If no URI given, try to resolve from session's latest archive
	if artifact_uri.is_empty():
		if session_id.is_empty():
			return MCPToolUtils.error("Either session_id or artifact_uri is required")

		var mgr = SingletonObject.autocoder_manager
		if mgr and mgr._latest_archive_by_session.has(session_id):
			artifact_uri = mgr._latest_archive_by_session[session_id]
		else:
			# Try getting it from session info
			var adapter = _get_autocoder_adapter()
			if adapter:
				var info = await adapter.get_session_info(session_id)
				if info and info.has("archive_uri"):
					artifact_uri = info["archive_uri"]
				elif info and info.has("output_archive_uri"):
					artifact_uri = info["output_archive_uri"]

		if artifact_uri.is_empty():
			return MCPToolUtils.error("No artifact URI found for session %s" % session_id)

	var result = await artifact_adapter._download_binary(artifact_uri)
	if not result or result.is_empty():
		return MCPToolUtils.error("Binary download failed for artifact: %s" % artifact_uri)

	var filename: String = result.get("filename", "")
	var buffer: PackedByteArray = result.get("buffer", PackedByteArray())

	if buffer.is_empty() or filename.is_empty():
		return MCPToolUtils.error("Empty artifact data for: %s" % artifact_uri)

	# Save to disk
	var artifacts_dir := "user://autocoder_artifacts"
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("autocoder_artifacts"):
		dir.make_dir_recursive("autocoder_artifacts")

	var save_path := "%s/%s" % [artifacts_dir, filename]
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if not file:
		var err := FileAccess.get_open_error()
		return MCPToolUtils.error("Failed to save artifact to disk: %s" % error_string(err))
	file.store_buffer(buffer)
	file.close()

	var global_path := ProjectSettings.globalize_path(save_path)

	return {
		"success": true,
		"filename": filename,
		"size": buffer.size(),
		"artifact_uri": artifact_uri,
		"path": global_path
	}


func _autocoder_create_review_preset(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var preset_name: String = args.get("name", "")
	if preset_name.is_empty():
		return MCPToolUtils.error("name is required")
	var agent_ids: Array = args.get("agent_ids", [])
	if agent_ids.is_empty():
		return MCPToolUtils.error("agent_ids is required and must be non-empty")
	var preset_id = await adapter.create_review_preset(preset_name, agent_ids)
	if not preset_id or (preset_id is String and preset_id.is_empty()):
		return MCPToolUtils.error("Failed to create review preset")
	return {"success": true, "preset_id": preset_id, "message": "Review preset created"}


func _autocoder_list_review_presets(_args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var presets = await adapter.list_review_presets()
	return {"success": true, "presets": presets, "count": presets.size()}


func _autocoder_update_review_preset(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var preset_id: String = args.get("preset_id", "")
	if preset_id.is_empty():
		return MCPToolUtils.error("preset_id is required")
	var preset_name: String = args.get("name", "")
	var agent_ids: Array = args.get("agent_ids", [])
	var ok = await adapter.update_review_preset(preset_id, preset_name, agent_ids)
	if not ok:
		return MCPToolUtils.error("Failed to update review preset")
	return {"success": true, "preset_id": preset_id, "message": "Review preset updated"}


func _autocoder_delete_review_preset(args: Dictionary) -> Dictionary:
	var adapter = _get_autocoder_adapter()
	if not adapter:
		return MCPToolUtils.error("AutoCoder not connected")
	var preset_id: String = args.get("preset_id", "")
	if preset_id.is_empty():
		return MCPToolUtils.error("preset_id is required")
	var ok = await adapter.delete_review_preset(preset_id)
	if not ok:
		return MCPToolUtils.error("Failed to delete review preset")
	return {"success": true, "preset_id": preset_id, "message": "Review preset deleted"}
