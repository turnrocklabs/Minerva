class_name AgentSpawner
extends RefCounted
## Static utility that creates a ChatHistory from an AgentDefinition,
## configures all fields, renders it in ChatPane, and sends the initial message.

const OpenRouterProviderScript = preload("res://Scripts/Services/Providers/OpenRouter/OpenRouterProvider.gd")


## Spawns an agent from `agent_def`: {history} or {error} (why it was not
## spawned). The agent's skill_names are resolved first, all or none
## (MCPSkillTools.resolve_skills), so an agent whose skills cannot be read
## is never created: nothing is added, rendered or sent. `still_wanted`, when
## given, is asked once they are read, before anything is created: "" to go
## on, else why the spawn is no longer wanted (its caller was stopped, its
## trigger changed), which is then the error.
static func spawn_agent(agent_def: AgentDefinition, initial_message: String = "", _trigger_id: String = "",
		still_wanted: Callable = Callable()) -> Dictionary:
	if not agent_def:
		push_error("[AgentSpawner] null AgentDefinition")
		return {"error": "no agent definition"}

	# 0. Resolve skills before anything is created
	var resolved := {}
	if not agent_def.skill_names.is_empty():
		var skill_module = _find_skill_tools_module()
		if not skill_module:
			return {"error": "its skills cannot be resolved: the skill tools are not available"}
		resolved = await skill_module.resolve_skills(agent_def.skill_names)
		if resolved.status != "ok":
			return {"error": str(resolved.message)}
		var unwanted: String = still_wanted.call() if still_wanted.is_valid() else ""
		if not unwanted.is_empty():
			return {"error": unwanted}

	# 1. Create provider
	var provider: BaseProvider = _create_provider(agent_def)
	if not provider:
		push_error("[AgentSpawner] Could not create provider for enum_id %d" % agent_def.provider_enum_id)
		return {"error": "no provider could be created for model %d" % agent_def.provider_enum_id}

	# 2. Create ChatHistory
	var history = ChatHistory.new(provider)
	history.HistoryName = "Agent: %s" % agent_def.name
	history.AgentModeEnabled = true
	history.AgenticSystemPrompt = agent_def.system_prompt
	history.AgenticSystemPromptEnabled = true
	history.Temperature = agent_def.temperature
	history.TopP = agent_def.top_p
	history.FrequencyPenalty = agent_def.frequency_penalty
	history.PresencePenalty = agent_def.presence_penalty
	history.MaxToolCallRounds = agent_def.max_tool_call_rounds
	history.IsAgentChat = true
	history.AgentDefinitionId = agent_def.id

	# 2b. Set active profiles from agent definition
	if not agent_def.skills.is_empty():
		history.ActiveSkills = agent_def.skills.duplicate()

	# 3. Compute DisabledTools from enabled_tools allowlist
	if not agent_def.enabled_tools.is_empty():
		var mcp = SingletonObject.get_mcp_manager()
		if mcp:
			var all_tools = mcp.get_available_tools()
			var disabled: Array[String] = []
			for tool_def in all_tools:
				var tool_name: String = str(tool_def.name) if tool_def is MCPToolDefinition else str(tool_def)
				if tool_name not in agent_def.enabled_tools:
					disabled.append(tool_name)
			history.DisabledTools = disabled

	# 3b. Apply static tool mode from skill_names (overrides enabled_tools if both set)
	if not agent_def.skill_names.is_empty():
		var resolved_tools: Array[String] = []
		resolved_tools.assign(resolved.get("tools", []))
		var skill_instructions: String = resolved.get("instructions", "")
		var mcp = SingletonObject.get_mcp_manager()
		if mcp:
			var all_tools = mcp.get_available_tools()
			var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
			var disabled: Array[String] = []
			for tool_def in all_tools:
				var tool_name: String = str(tool_def.name) if tool_def is MCPToolDefinition else str(tool_def)
				if tool_name not in resolved_tools or tool_name in discovery_tools:
					disabled.append(tool_name)
			history.DisabledTools = disabled
			history.StaticToolMode = true
		# Prepend skill instructions to system prompt
		if not skill_instructions.is_empty():
			history.AgenticSystemPrompt = skill_instructions + "\n\n---\n\n" + history.AgenticSystemPrompt
		print("[AgentSpawner] Static tool mode: %d skill_names resolved for agent '%s'" % [agent_def.skill_names.size(), agent_def.name])

	# 4. Create agent memory tabs if configured (pass history so tabs auto-link)
	_ensure_agent_memory_tabs(agent_def, history)

	# 5. Add to ChatList
	SingletonObject.ChatList.append(history)

	# 6. Render in ChatPane
	var chats = SingletonObject.Chats
	if chats:
		chats.render_history(history)
		# Switch to the new tab
		var tab_count = chats.get_tab_count()
		if tab_count > 0:
			chats.current_tab = tab_count - 1
		# Hide buffer control
		if chats.buffer_control_chats and chats.buffer_control_chats.visible:
			chats.buffer_control_chats.hide()

	# 7. Send initial message if provided
	if not initial_message.is_empty() and chats:
		chats.call_deferred("execute_regular_chat", initial_message)

	print("[AgentSpawner] Spawned agent '%s' (history_id=%s)" % [agent_def.name, history.HistoryId])
	return {"history": history}


static func _create_provider(agent_def: AgentDefinition) -> BaseProvider:
	if agent_def.provider_enum_id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
		return _create_core_provider(agent_def.core_service_id, agent_def.core_action_name)
	var id := agent_def.provider_enum_id
	var provider: BaseProvider = ModelResolver.create({"kind": "dynamic" if id >= SingletonObject.DYNAMIC_MODEL_ID_BASE else "builtin", "model_id": id}).get("provider")
	if provider != null and not provider.supports_chat:
		provider.free()
		return null
	return provider


static func _create_core_provider(service_id: String, action_name: String) -> BaseProvider:
	var result := ModelResolver.create({"kind": "core_action", "service_client_id": service_id, "action_name": action_name})
	if not result.success:
		push_warning("[AgentSpawner] %s" % result.error_message)
	return result.get("provider")


## Find MCPSkillTools module through the singleton chain.
## Returns the module instance, or null if not available.
static func _find_skill_tools_module():
	var mcp = SingletonObject.get_mcp_manager()
	if mcp and mcp.minerva_server:
		for module in mcp.minerva_server._modules:
			if module is MCPSkillTools:
				return module
	push_warning("[AgentSpawner] MCPSkillTools module not found — skill resolution unavailable")
	return null


static func _ensure_agent_memory_tabs(agent_def: AgentDefinition, history: ChatHistory = null) -> void:
	# Project-scoped memory tab
	if not agent_def.memory_tab_name.is_empty() and SingletonObject.notes_container:
		var vbox = SingletonObject.notes_container.find_or_create_agent_tab(
			agent_def.memory_tab_name, agent_def.id
		)
		if history and history.HistoryId not in vbox.default_linked_chat_ids:
			vbox.default_linked_chat_ids.append(history.HistoryId)

	# App-scoped drawer memory tab
	if not agent_def.drawer_tab_name.is_empty() and SingletonObject.drawer_notes_container:
		var vbox = SingletonObject.drawer_notes_container.find_or_create_agent_tab(
			agent_def.drawer_tab_name, agent_def.id
		)
		if history and history.HistoryId not in vbox.default_linked_chat_ids:
			vbox.default_linked_chat_ids.append(history.HistoryId)
