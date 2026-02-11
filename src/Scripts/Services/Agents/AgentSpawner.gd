class_name AgentSpawner
extends RefCounted
## Static utility that creates a ChatHistory from an AgentDefinition,
## configures all fields, renders it in ChatPane, and sends the initial message.

const OpenRouterProviderScript = preload("res://Scripts/Services/Providers/OpenRouter/OpenRouterProvider.gd")


static func spawn_agent(agent_def: AgentDefinition, initial_message: String = "", trigger_id: String = "") -> ChatHistory:
	if not agent_def:
		push_error("[AgentSpawner] null AgentDefinition")
		return null

	# 1. Create provider
	var provider: BaseProvider = _create_provider(agent_def)
	if not provider:
		push_error("[AgentSpawner] Could not create provider for enum_id %d" % agent_def.provider_enum_id)
		return null

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

	# 3. Compute DisabledTools from enabled_tools allowlist
	if not agent_def.enabled_tools.is_empty():
		var mcp = SingletonObject.get_mcp_manager()
		if mcp:
			var all_tools = mcp.get_available_tools()
			var disabled: Array[String] = []
			for tool_def in all_tools:
				var tool_name: String = tool_def.name if tool_def is MCPToolDefinition else str(tool_def)
				if tool_name not in agent_def.enabled_tools:
					disabled.append(tool_name)
			history.DisabledTools = disabled

	# 4. Add to ChatList
	SingletonObject.ChatList.append(history)

	# 5. Render in ChatPane
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

	# 6. Send initial message if provided
	if not initial_message.is_empty() and chats:
		chats.call_deferred("execute_regular_chat", initial_message)

	print("[AgentSpawner] Spawned agent '%s' (history_id=%s)" % [agent_def.name, history.HistoryId])
	return history


static func _create_provider(agent_def: AgentDefinition) -> BaseProvider:
	var provider_enum_id: int = agent_def.provider_enum_id

	# Handle dynamic OpenRouter models
	if provider_enum_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		var config: Dictionary = SingletonObject.openrouter_model_manager.get_model(provider_enum_id)
		if not config.is_empty():
			return OpenRouterProviderScript.create_from_config(config)
		return null

	# Handle Core/TurnRock: needs Service + Action from runtime discovery
	if provider_enum_id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
		return _create_core_provider(agent_def.core_service_id, agent_def.core_action_name)

	# Standard provider
	if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(provider_enum_id):
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum_id].new()

	return null


static func _create_core_provider(service_id: String, action_name: String) -> BaseProvider:
	if service_id.is_empty() or action_name.is_empty():
		push_error("[AgentSpawner] Core agent missing service_id or action_name")
		return null

	var core_node = SingletonObject.get_tree().root.get_node_or_null("Core")
	if not core_node:
		push_error("[AgentSpawner] Core autoload not found")
		return null

	for service in core_node.services:
		if service.client_id == service_id:
			for action in service.actions:
				if action.name == action_name:
					return CoreProvider.new(service, action)

	push_error("[AgentSpawner] Core service '%s' action '%s' not found" % [service_id, action_name])
	return null
