class_name MCPChatTools
extends MCPToolModule
## MCP tool module for Chat domain tools.
## Handles create/send/read/close chat operations, system prompts,
## agent mode configuration, and ledger/compact tools.


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_chat",
		"minerva_create_focused_chat",
		"minerva_set_system_prompt",
		"minerva_set_agent_mode",
		"minerva_send_message",
		"minerva_get_chat_history",
		"minerva_get_chat_messages",
		"minerva_get_tool_calls",
		"minerva_list_chats",
		"minerva_close_chat",
		"minerva_list_ledger_entries",
		"minerva_get_ledger_entry",
		"minerva_compact_chat",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_chat",
		"Create a new chat tab in Minerva. Returns a chat_id (UUID) that MUST be used for all subsequent operations on this chat. Do not use the name as the chat_id. Next steps: use minerva_set_system_prompt to configure behavior, then minerva_send_message to start conversation.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the chat tab"
				},
				"provider": {
					"type": "string",
					"description": "Model provider. Use enum name (e.g. claude_sonnet, claude_opus, gpt_standard, gpt_deep, gemini_flash, chatgpt_default) or 'current' to use the calling chat's provider. Case-insensitive. Default: current UI selection."
				},
				"provider_enum_id": {
					"type": "integer",
					"description": "Alternative: provider enum ID (e.g. 11=CLAUDE_SONNET, 12=CLAUDE_OPUS, 20=CHATGPT). Use for OpenRouter dynamic models (>=1000). Takes precedence over provider name."
				}
			},
			"required": ["name"]
		}
	, "chat")

	server._register_tool("minerva_create_focused_chat",
		"Create a focused chat with a fixed tool set (static mode). Skills resolve to tools — no dynamic tool discovery. Ideal for models that struggle with 2-step tool calling. Returns chat_id for subsequent operations.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the chat tab"
				},
				"provider": {
					"type": "string",
					"description": "Model provider (e.g. claude_sonnet, gpt_standard, chatgpt). Default: current UI selection."
				},
				"provider_enum_id": {
					"type": "integer",
					"description": "Alternative: provider enum ID. Takes precedence over provider name."
				},
				"skills": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Skill names or IDs to resolve (docket skills). Their tool_deps become the tool set."
				},
				"extra_tools": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Additional tool names to include beyond what skills provide."
				},
				"system_prompt": {
					"type": "string",
					"description": "System prompt. Skill instructions are automatically prepended."
				}
			},
			"required": ["name"]
		}
	, "chat")

	server._register_tool("minerva_set_system_prompt",
		"Set the system prompt for a specific chat. Requires chat_id from minerva_list_chats or minerva_create_chat.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				},
				"prompt": {
					"type": "string",
					"description": "The system prompt text"
				}
			},
			"required": ["chat_id", "prompt"]
		}
	, "chat")

	server._register_tool("minerva_set_agent_mode",
		"Configure agent mode settings for a chat. When enabled, the chat can use MCP tools.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				},
				"enabled": {
					"type": "boolean",
					"description": "Whether to enable agent mode"
				},
				"agentic_prompt": {
					"type": "string",
					"description": "Optional custom agentic system prompt"
				},
				"max_rounds": {
					"type": "integer",
					"description": "Maximum tool call rounds (default: 10)"
				},
				"disabled_tools": {
					"type": "array",
					"items": {"type": "string"},
					"description": "List of tool names to disable for this chat"
				}
			},
			"required": ["chat_id", "enabled"]
		}
	, "chat")

	server._register_tool("minerva_send_message",
		"Send a message to a chat. Returns immediately (fire and forget). For worker chats, use minerva_check_worker to monitor status (compact, ~100 tokens). Only use minerva_get_chat_history when you need the full transcript. Requires chat_id — get it from minerva_list_chats or minerva_create_chat.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				},
				"message": {
					"type": "string",
					"description": "The message to send"
				}
			},
			"required": ["chat_id", "message"]
		}
	, "chat")

	server._register_tool("minerva_get_chat_history",
		"Get a metadata-only message list for a chat. Returns one entry per message with index, role, chars, tool_calls, and tool_names when present. Use this to decide which specific messages to hydrate with minerva_get_chat_messages. Requires chat_id from minerva_list_chats.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				}
			},
			"required": ["chat_id"]
		}
	, "chat")

	server._register_tool("minerva_get_chat_messages",
		"Get full content for specific messages in a chat by 0-based index. Use minerva_get_chat_history first, then hydrate only the indices you need. Requires chat_id and indices. Recommended: fetch 5 or fewer messages at a time.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				},
				"indices": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Array of 0-based message indices to hydrate"
				}
			},
			"required": ["chat_id", "indices"]
		}
	, "chat")

	server._register_tool("minerva_list_chats",
		"List all open chat tabs with their IDs, names, message counts, and agent info.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "chat")

	server._register_tool("minerva_close_chat",
		"Close a chat tab.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The UUID returned from minerva_create_chat (not the display name)"
				}
			},
			"required": ["chat_id"]
		}
	, "chat")

	server._register_tool("minerva_get_tool_calls",
		"Get detailed tool call arguments and results for a specific message in a chat. Use after minerva_get_chat_history shows tool_calls > 0 on a message. Returns the full arguments passed to each tool and a summary of the result.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The chat ID from minerva_list_chats"
				},
				"message_index": {
					"type": "integer",
					"description": "0-based index of the message in chat history"
				}
			},
			"required": ["chat_id", "message_index"]
		}
	, "chat")

	server._register_tool("minerva_list_ledger_entries",
		"List compaction ledger entries. Optionally filter by chat_id. Returns archived conversation segments.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "Filter by chat history ID. Omit for all entries."
				}
			},
			"required": []
		}
	, "compaction")

	server._register_tool("minerva_get_ledger_entry",
		"Get a specific ledger entry by ID, including original messages.",
		{
			"type": "object",
			"properties": {
				"entry_id": {
					"type": "string",
					"description": "ID of the ledger entry to retrieve"
				}
			},
			"required": ["entry_id"]
		}
	, "compaction")

	server._register_tool("minerva_compact_chat",
		"Compact a chat's history by summarizing older messages. Keeps recent messages and archives originals in the Ledger. Uses LLM summarization when available.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "ID of the chat to compact"
				}
			},
			"required": ["chat_id"]
		}
	, "compaction")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_chat":
			return _create_chat(arguments)
		"minerva_create_focused_chat":
			return _create_focused_chat(arguments)
		"minerva_set_system_prompt":
			return _set_system_prompt(arguments)
		"minerva_set_agent_mode":
			return _set_agent_mode(arguments)
		"minerva_send_message":
			return _send_message(arguments)
		"minerva_get_chat_history":
			return _get_chat_history(arguments)
		"minerva_get_chat_messages":
			return _get_chat_messages(arguments)
		"minerva_get_tool_calls":
			return _get_tool_calls(arguments)
		"minerva_list_chats":
			return _list_chats(arguments)
		"minerva_close_chat":
			return _close_chat(arguments)
		"minerva_list_ledger_entries":
			return _list_ledger_entries(arguments)
		"minerva_get_ledger_entry":
			return _get_ledger_entry(arguments)
		"minerva_compact_chat":
			return await _compact_chat_mcp(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


#region Chat Tool Implementations

func _create_chat(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Agent Chat")
	var provider_name: String = args.get("provider", "")

	# Before creating, check if resource with same name exists
	# If it does, return it with already_existed: true
	if not name_.is_empty():
		for existing in SingletonObject.ChatList:
			if existing.HistoryName == name_:
				return {"success": true, "already_existed": true, "chat_id": existing.HistoryId, "name": existing.HistoryName}

	# Get the chat pane
	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return MCPToolUtils.error("Chat pane not available")

	# Resolve provider: friendly name, enum ID, "current", or fallback
	var provider_obj = null
	var provider_enum_id = args.get("provider_enum_id", -1)

	if provider_name == "current":
		# Use the calling chat's provider
		if chat_pane.current_tab >= 0 and chat_pane.current_tab < SingletonObject.ChatList.size():
			var caller_history = SingletonObject.ChatList[chat_pane.current_tab]
			if caller_history and caller_history.provider:
				provider_obj = caller_history.provider.duplicate() if caller_history.provider.has_method("duplicate") else caller_history.provider
				if not provider_obj:
					# Can't duplicate, create new instance of same type
					var script = caller_history.provider.get_script()
					if script:
						provider_obj = script.new()
				print("[MCPChatTools] Using current chat's provider")

	if not provider_obj and int(provider_enum_id) >= 0:
		# Accept raw enum ID (covers OpenRouter >=1000, ChatGPT=20, etc.)
		var eid: int = int(provider_enum_id)
		if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(eid):
			provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[eid].new()
			print("[MCPChatTools] Using provider enum ID: %d" % eid)

	if not provider_obj and not provider_name.is_empty():
		# Build friendly name map dynamically from the enum
		var name_map: Dictionary = {}
		for eid in SingletonObject.API_MODEL_PROVIDERS.values():
			var ename: String = SingletonObject.API_MODEL_PROVIDERS.find_key(eid)
			if ename:
				name_map[ename.to_lower()] = eid
		# Try exact match first, then common aliases
		var lookup_name := provider_name.to_lower().replace("-", "_").replace(" ", "_")
		# Common aliases that agents might use
		var aliases := {
			"anthropic": "claude_sonnet",
			"claude": "claude_sonnet",
			"google": "gemini_flash",
			"gemini": "gemini_flash",
			"chatgpt": "chatgpt",
		}
		if not name_map.has(lookup_name) and aliases.has(lookup_name):
			lookup_name = aliases[lookup_name]
		if name_map.has(lookup_name):
			var eid: int = name_map[lookup_name]
			if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(eid):
				provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[eid].new()
				print("[MCPChatTools] Using provider: %s (enum: %d)" % [provider_name, eid])

	# Fall back to current selected provider in UI
	if not provider_obj:
		if not provider_name.is_empty():
			# Provider was specified but not found — log warning with valid names
			var valid_names: PackedStringArray = []
			for eid in SingletonObject.API_MODEL_PROVIDERS.values():
				var ename: String = SingletonObject.API_MODEL_PROVIDERS.find_key(eid)
				if ename:
					valid_names.append(ename.to_lower())
			push_warning("[MCPChatTools] Provider '%s' not found. Valid names: %s. Falling back to UI selection." % [provider_name, ", ".join(valid_names)])
		provider_obj = chat_pane._provider_option_button.get_selected_provider()
		if not provider_obj:
			provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[SingletonObject.API_MODEL_PROVIDERS.GPT_NANO].new()

	# Create new chat history
	var ChatHistoryScript = load("res://Scripts/Models/ChatHistory.gd")
	var history = ChatHistoryScript.new(provider_obj)
	history.HistoryName = name_
	# Note: HistoryItemList is already initialized in the constructor

	# Add to chat list and render
	SingletonObject.ChatList.append(history)
	chat_pane.render_history(history)

	# Don't switch tabs - keep focus on the requesting chat to avoid breaking agent loops
	# The user can manually switch if they want to see the new chat

	var provider_display = provider_obj.model_name if "model_name" in provider_obj else "unknown"
	print("[MCPChatTools] Created chat '%s' with id: %s (model: %s)" % [history.HistoryName, history.HistoryId, provider_display])

	return {
		"success": true,
		"chat_id": history.HistoryId,
		"name": history.HistoryName,
		"provider": provider_display,
		"message": "Chat created. Use the chat_id value (not the name) for subsequent operations."
	}


func _create_focused_chat(args: Dictionary) -> Dictionary:
	# 1. Create the chat via the normal path (handles provider resolution)
	var create_result := _create_chat(args)
	if create_result.has("error") or not create_result.get("success", false):
		return create_result

	var chat_id: String = create_result.get("chat_id", "")
	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat created but not found: %s" % chat_id)

	# 2. Resolve skills
	var skill_names_raw: Array = args.get("skills", [])
	var extra_tools_raw: Array = args.get("extra_tools", [])
	var system_prompt: String = args.get("system_prompt", "")

	var resolved_tools: Array[String] = []
	var instructions := ""
	if not skill_names_raw.is_empty():
		var skill_names: Array[String] = []
		for sn in skill_names_raw:
			skill_names.append(str(sn))
		# Find MCPSkillTools module
		for module in server._modules:
			if module is MCPSkillTools:
				var resolved: Dictionary = module.resolve_skills(skill_names)
				instructions = resolved.get("instructions", "")
				resolved_tools.assign(resolved.get("tools", []))
				break

	# 3. Union with extra_tools
	for et in extra_tools_raw:
		var tool_name: String = str(et)
		if tool_name not in resolved_tools:
			resolved_tools.append(tool_name)

	if resolved_tools.is_empty():
		return MCPToolUtils.error("No tools resolved — provide skills or extra_tools")

	# 4. Compute disabled set
	var mcp = SingletonObject.get_mcp_manager()
	if not mcp:
		return MCPToolUtils.error("MCP manager not available")

	var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
	var disabled: Array[String] = []
	for tool_def in mcp.get_available_tools():
		var tool_name: String = str(tool_def.name)
		if tool_name not in resolved_tools or tool_name in discovery_tools:
			disabled.append(tool_name)

	# 5. Configure static mode on history
	history.StaticToolMode = true
	history.ConfiguredTools = resolved_tools
	var configured_skills: Array[String] = []
	for sn in skill_names_raw:
		configured_skills.append(str(sn))
	history.ConfiguredSkills = configured_skills
	history.DisabledTools = disabled
	history.AgentModeEnabled = true

	# 6. Set system prompt with skill instructions prepended
	if not instructions.is_empty() or not system_prompt.is_empty():
		var full_prompt := ""
		if not instructions.is_empty():
			full_prompt = instructions
		if not system_prompt.is_empty():
			full_prompt = full_prompt + "\n\n---\n\n" + system_prompt if not full_prompt.is_empty() else system_prompt
		history.AgenticSystemPrompt = full_prompt

	var skill_count := skill_names_raw.size()
	print("[MCPChatTools] Created focused chat '%s' (id: %s) — %d skills, %d tools, %d disabled" % [
		history.HistoryName, chat_id, skill_count, resolved_tools.size(), disabled.size()])

	return {
		"success": true,
		"chat_id": chat_id,
		"name": history.HistoryName,
		"tool_count": resolved_tools.size(),
		"skills_resolved": skill_count,
		"tools": resolved_tools,
		"message": "Focused chat created with %d tools. Static tool mode — no dynamic discovery." % resolved_tools.size(),
	}


func _set_system_prompt(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var prompt: String = args.get("prompt", "")

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	# Create system prompt history item
	var ChatHistoryItemScript = load("res://Scripts/Models/ChatHistoryItem.gd")
	var system_item = ChatHistoryItemScript.new()
	system_item.Message = prompt
	system_item.Role = ChatHistoryItemScript.ChatRole.SYSTEM

	# Replace or insert system prompt
	if history.HasUsedSystemPrompt and history.HistoryItemList.size() > 0:
		history.HistoryItemList[0] = system_item
	else:
		history.HistoryItemList.insert(0, system_item)
		history.HasUsedSystemPrompt = true
	history.SystemPromptEnabled = true

	return {"success": true, "message": "System prompt set"}


func _set_agent_mode(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var enabled: bool = args.get("enabled", false)

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	history.AgentModeEnabled = enabled
	# Any chat with agent mode enabled via MCP is an agent chat —
	# ensures agent_chat_finished fires on completion for completion routing
	if enabled:
		history.IsAgentChat = true

	if args.has("agentic_prompt"):
		history.AgenticSystemPrompt = args.get("agentic_prompt", "")

	if args.has("max_rounds"):
		history.MaxToolCallRounds = MCPToolUtils.coerce_int(args.get("max_rounds", 15))

	if args.has("disabled_tools"):
		var disabled = args.get("disabled_tools", [])
		history.DisabledTools.clear()
		for tool_name in disabled:
			history.DisabledTools.append(str(tool_name))

	return {"success": true, "agent_mode": enabled}


func _send_message(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var message: String = args.get("message", "")

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	if message.is_empty():
		return MCPToolUtils.error("message is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	# Tool fence: reject if the target chat has pending tool calls.
	# Inserting a user message between an assistant's tool_calls and their
	# tool_results violates the OpenAI API contract and causes
	# "No tool output found for function call" errors.
	var pending := _count_pending_tool_calls(history)
	if pending > 0:
		return MCPToolUtils.error(
			"Worker has %d pending tool call(s). Wait for them to complete before sending a message. Use minerva_check_worker to monitor progress." % pending)

	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return MCPToolUtils.error("Chat pane not available")

	# Find the target chat tab
	var tab_idx = MCPToolUtils.find_chat_tab_index(chat_id)
	if tab_idx == -1:
		return MCPToolUtils.error("Chat tab not found")

	# Save original tab
	var original_tab = chat_pane.current_tab

	# Switch to target chat and execute (fire and forget - no waiting)
	chat_pane.current_tab = tab_idx

	print("[MCPChatTools] Sending message to chat '%s': %s" % [history.HistoryName, message.left(50)])
	chat_pane.execute_regular_chat(message)

	# Restore original tab after the current frame completes.
	# IMPORTANT: Don't switch back immediately — execute_regular_chat reads
	# current_tab during setup. Switching too early causes provider mismatch
	# (e.g., sub-agent uses caller's ChatGPT format instead of its own Anthropic format).
	chat_pane.call_deferred("set_current_tab", original_tab)

	return {
		"success": true,
		"message": "Message sent. Use minerva_check_worker to monitor worker progress (compact). Use minerva_get_chat_history only to read final results."
	}


## Returns the number of unresolved tool calls in the chat's most recent
## assistant tool_call message. Returns 0 if no tool calls are pending.
func _count_pending_tool_calls(history) -> int:
	var items: Array = history.HistoryItemList
	# Walk backward to find the last assistant message with tool calls
	for i in range(items.size() - 1, -1, -1):
		var item: ChatHistoryItem = items[i]
		if item.Role == ChatHistoryItem.ChatRole.USER:
			return 0  # Hit a user message first — no pending tool calls
		if (item.Role == ChatHistoryItem.ChatRole.ASSISTANT or item.Role == ChatHistoryItem.ChatRole.MODEL) and item.IsToolCall:
			# Found it — count expected vs received
			var expected_ids: Dictionary = {}
			for tc in item.ToolCalls:
				var cid: String = tc.get("id", "")
				if not cid.is_empty():
					expected_ids[cid] = true
			# Remove IDs that have matching TOOL responses after this message
			for j in range(i + 1, items.size()):
				if items[j].Role == ChatHistoryItem.ChatRole.TOOL:
					expected_ids.erase(items[j].ToolCallId)
			return expected_ids.size()
	return 0


func _chat_role_name(item: ChatHistoryItem) -> String:
	match item.Role:
		ChatHistoryItem.ChatRole.USER:
			return "user"
		ChatHistoryItem.ChatRole.ASSISTANT, ChatHistoryItem.ChatRole.MODEL:
			return "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			return "system"
		ChatHistoryItem.ChatRole.TOOL:
			return "tool"
	return "unknown"


func _tool_names_from_item(item: ChatHistoryItem) -> Array[String]:
	var names: Array[String] = []
	for tc in item.ToolCalls:
		names.append(tc.get("name", ""))
	return names


func _serialize_chat_message_metadata(item: ChatHistoryItem, index: int) -> Dictionary:
	var msg: Dictionary = {
		"index": index,
		"role": _chat_role_name(item),
		"chars": item.Message.length(),
		"tool_calls": item.ToolCalls.size() if item.IsToolCall else 0,
	}
	if item.IsToolCall and not item.ToolCalls.is_empty():
		msg["tool_names"] = _tool_names_from_item(item)
	if item.Role == ChatHistoryItem.ChatRole.TOOL:
		msg["tool_name"] = item.ToolName
	return msg


func _serialize_chat_message_full(item: ChatHistoryItem, index: int) -> Dictionary:
	var msg: Dictionary = {
		"index": index,
		"role": _chat_role_name(item),
		"content": item.Message,
	}
	if item.IsToolCall and not item.ToolCalls.is_empty():
		msg["tool_calls"] = item.ToolCalls.duplicate(true)
		msg["tool_names"] = _tool_names_from_item(item)
	if item.Role == ChatHistoryItem.ChatRole.TOOL:
		msg["tool_call_id"] = item.ToolCallId
		msg["tool_name"] = item.ToolName
	return msg


func _get_chat_history(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	var messages: Array = []
	for i in range(history.HistoryItemList.size()):
		messages.append(_serialize_chat_message_metadata(history.HistoryItemList[i], i))

	return {
		"success": true,
		"chat_id": chat_id,
		"name": history.HistoryName,
		"messages": messages,
		"count": messages.size(),
	}


func _get_chat_messages(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var indices_raw = args.get("indices", [])

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")
	if not (indices_raw is Array) or indices_raw.is_empty():
		return MCPToolUtils.error("indices is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	var history_size: int = history.HistoryItemList.size()
	if history_size == 0:
		return MCPToolUtils.error("Chat has no messages")

	var indices: Array[int] = []
	for raw_index in indices_raw:
		var msg_index := MCPToolUtils.coerce_int(raw_index, -1)
		if msg_index < 0 or msg_index >= history_size:
			return MCPToolUtils.error("message index %d out of range (0-%d)" % [msg_index, history_size - 1])
		indices.append(msg_index)

	var messages: Array = []
	for msg_index in indices:
		messages.append(_serialize_chat_message_full(history.HistoryItemList[msg_index], msg_index))

	return {
		"success": true,
		"chat_id": chat_id,
		"name": history.HistoryName,
		"messages": messages,
		"count": messages.size(),
	}


func _get_tool_calls(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var msg_index: int = MCPToolUtils.coerce_int(args.get("message_index", -1))

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	if msg_index < 0 or msg_index >= history.HistoryItemList.size():
		return MCPToolUtils.error("message_index %d out of range (0-%d)" % [msg_index, history.HistoryItemList.size() - 1])

	var item = history.HistoryItemList[msg_index]

	if not item.IsToolCall or item.ToolCalls.is_empty():
		return MCPToolUtils.error("Message at index %d has no tool calls" % msg_index)

	# Build detailed tool call info
	var calls: Array = []
	for tc in item.ToolCalls:
		var call_info: Dictionary = {
			"tool_name": tc.get("name", ""),
			"arguments": tc.get("arguments", {}),
			"call_id": tc.get("id", ""),
		}
		calls.append(call_info)

	# Also include ToolExecutions if available (has results)
	var executions: Array = []
	for exec in item.ToolExecutions:
		executions.append({
			"tool_name": exec.get("tool_name", ""),
			"arguments": exec.get("arguments", {}),
			"call_id": exec.get("call_id", ""),
			"status": exec.get("status", ""),
			"result": exec.get("result", "").left(500),  # Truncate result
		})

	return {
		"success": true,
		"chat_id": chat_id,
		"message_index": msg_index,
		"tool_calls": calls,
		"tool_executions": executions,
		"count": calls.size(),
	}


func _list_chats(_args: Dictionary) -> Dictionary:
	var result: Array[Dictionary] = []
	for history in SingletonObject.ChatList:
		var entry: Dictionary = {
			"chat_id": history.HistoryId,
			"name": history.HistoryName,
			"message_count": history.HistoryItemList.size(),
			"is_agent": history.IsAgentChat,
		}
		if history.IsAgentChat:
			entry["agent_definition_id"] = history.AgentDefinitionId
			entry["max_tool_rounds"] = history.MaxToolCallRounds
		result.append(entry)
	return {"success": true, "chats": result, "count": result.size()}


func _close_chat(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")

	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var tab_idx = MCPToolUtils.find_chat_tab_index(chat_id)
	if tab_idx == -1:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return MCPToolUtils.error("Chat pane not available")

	# Close the tab
	chat_pane.get_tab_bar().tab_close_pressed.emit(tab_idx)

	return {"success": true, "message": "Chat closed"}

#endregion


#region Ledger / Compaction Tool Implementations

func _list_ledger_entries(args: Dictionary) -> Dictionary:
	var lm = SingletonObject.ledger_manager
	if not lm:
		return MCPToolUtils.error("Ledger manager not available")

	var chat_id: String = args.get("chat_id", "")
	var entries: Array[LedgerEntry]
	if not chat_id.is_empty():
		entries = lm.get_entries_for_chat(chat_id)
	else:
		entries = lm.entries

	var result: Array[Dictionary] = []
	for e in entries:
		result.append({
			"id": e.id,
			"chat_id": e.chat_id,
			"chat_name": e.chat_name,
			"timestamp": e.timestamp,
			"message_range": e.message_range,
			"message_count": e.original_messages.size(),
		})
	return {"success": true, "entries": result, "count": result.size()}


func _get_ledger_entry(args: Dictionary) -> Dictionary:
	var lm = SingletonObject.ledger_manager
	if not lm:
		return MCPToolUtils.error("Ledger manager not available")

	var entry_id: String = args.get("entry_id", "")
	if entry_id.is_empty():
		return MCPToolUtils.error("entry_id is required")

	var entry = lm.get_entry(entry_id)
	if not entry:
		return MCPToolUtils.error("Ledger entry not found: %s" % entry_id)

	return {
		"success": true,
		"entry": entry.serialize()
	}


func _compact_chat_mcp(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var chats = SingletonObject.Chats
	if not chats:
		return MCPToolUtils.error("Chat pane not available")

	# Find the chat by ID
	var history = MCPToolUtils.find_chat_by_id(chat_id)

	if not history:
		return MCPToolUtils.error("Chat not found: %s" % chat_id)

	var result = await chats.compact_chat(history)
	if not result:
		return {"success": false, "message": "Not enough messages to compact"}

	# Get the ledger entry ID if one was created
	var ledger_id := ""
	if SingletonObject.ledger_manager and not SingletonObject.ledger_manager.entries.is_empty():
		var last_entry = SingletonObject.ledger_manager.entries.back()
		if last_entry.chat_id == chat_id:
			ledger_id = last_entry.id

	return {
		"success": true,
		"message": "Chat compacted successfully",
		"ledger_entry_id": ledger_id,
		"new_history_size": history.HistoryItemList.size()
	}

#endregion
