class_name MinervaMCPServer
extends RefCounted
## Internal MCP server that allows LLMs to control Minerva's own features.
## Provides tools for managing chats, notes, and editors.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")

## Reference to the MCPManager for tool registration
var mcp_manager

## Whether the minerva server is connected (enabled)
var server_enabled: bool = false

## Server name for tool registration
const SERVER_NAME: String = "minerva"

## Session-wide tracking of iterative generation attempts (prevents bypass via new editors)
var _session_iterative_attempts: int = 0
var _session_attempts_reset_time: int = 0


func _init(manager = null) -> void:
	mcp_manager = manager


## Register all minerva_* tools in the MCPManager's tool_registry
func register_tools() -> void:
	if not mcp_manager:
		push_error("[MinervaMCPServer] No MCPManager reference")
		return

	_register_chat_tools()
	_register_notes_tools()
	_register_editor_tools()

	print("[MinervaMCPServer] Registered %d tools" % get_tool_count())


## Get the count of registered minerva tools
func get_tool_count() -> int:
	var count := 0
	for tool_name in mcp_manager.tool_registry:
		if mcp_manager.tool_registry[tool_name].server_name == SERVER_NAME:
			count += 1
	return count


## Unregister all minerva tools
func unregister_tools() -> void:
	if not mcp_manager:
		return

	var to_remove: Array[String] = []
	for tool_name in mcp_manager.tool_registry:
		if mcp_manager.tool_registry[tool_name].server_name == SERVER_NAME:
			to_remove.append(tool_name)

	for tool_name in to_remove:
		mcp_manager.tool_registry.erase(tool_name)

	print("[MinervaMCPServer] Unregistered %d tools" % to_remove.size())


## Connect (enable) the minerva server - registers tools
func connect_server() -> void:
	if server_enabled:
		return

	register_tools()
	server_enabled = true
	print("[MinervaMCPServer] Connected")


## Disconnect (disable) the minerva server - unregisters tools
func disconnect_server() -> void:
	if not server_enabled:
		return

	unregister_tools()
	server_enabled = false
	print("[MinervaMCPServer] Disconnected")


## Execute a minerva_* tool
func execute_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not server_enabled:
		return {"error": "Minerva server not connected", "success": false}

	print("[MinervaMCPServer] Executing: %s" % tool_name)

	match tool_name:
		# Chat tools
		"minerva_create_chat":
			return _create_chat(arguments)
		"minerva_set_system_prompt":
			return _set_system_prompt(arguments)
		"minerva_set_agent_mode":
			return _set_agent_mode(arguments)
		"minerva_send_message":
			return _send_message(arguments)
		"minerva_get_chat_history":
			return _get_chat_history(arguments)
		"minerva_close_chat":
			return _close_chat(arguments)

		# Notes tools
		"minerva_create_note":
			return _create_note(arguments)
		"minerva_create_note_tab":
			return _create_note_tab(arguments)
		"minerva_list_notes":
			return _list_notes(arguments)
		"minerva_enable_notes":
			return _enable_notes(arguments)
		"minerva_disable_notes":
			return _disable_notes(arguments)
		"minerva_delete_note":
			return _delete_note(arguments)

		# Editor tools
		"minerva_create_text_editor":
			return _create_text_editor(arguments)
		"minerva_create_graphics_editor":
			return _create_graphics_editor(arguments)
		"minerva_get_editor_content":
			return _get_editor_content(arguments)
		"minerva_update_editor":
			return _update_editor(arguments)
		"minerva_save_editor":
			return _save_editor(arguments)
		"minerva_close_editor":
			return _close_editor(arguments)

		# Graphics editor AI tools
		"minerva_graphics_get_capabilities":
			return _get_graphics_capabilities(arguments)
		"minerva_graphics_generate":
			return _generate_graphics(arguments)
		"minerva_graphics_generate_iterative":
			return await _generate_graphics_iterative(arguments)

	return {"error": "Unknown minerva tool: %s" % tool_name, "success": false}


#region Tool Registration

func _register_tool(name: String, description: String, input_schema: Dictionary) -> void:
	var tool = MCPToolDefinitionScript.new()
	tool.name = name
	tool.description = description
	tool.input_schema = input_schema
	tool.server_name = SERVER_NAME
	mcp_manager.tool_registry[name] = tool


func _register_chat_tools() -> void:
	_register_tool("minerva_create_chat",
		"Create a new chat tab in Minerva. Returns a chat_id (UUID) that MUST be used for all subsequent operations on this chat. Do not use the name as the chat_id.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the chat tab"
				},
				"provider": {
					"type": "string",
					"description": "Model provider to use. Options: claude_sonnet, claude_haiku, claude_opus, gpt_nano, gpt_standard, gpt_deep, gemini_flash, gemini_pro. Default: current selected provider.",
					"enum": ["claude_sonnet", "claude_haiku", "claude_opus", "gpt_nano", "gpt_standard", "gpt_deep", "gemini_flash", "gemini_pro"]
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_set_system_prompt",
		"Set the system prompt for a specific chat.",
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
	)

	_register_tool("minerva_set_agent_mode",
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
	)

	_register_tool("minerva_send_message",
		"Send a message to a chat. Returns immediately (fire and forget). Use minerva_get_chat_history to check for the response later.",
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
	)

	_register_tool("minerva_get_chat_history",
		"Get the message history for a chat.",
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
	)

	_register_tool("minerva_close_chat",
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
	)


func _register_notes_tools() -> void:
	_register_tool("minerva_create_note",
		"Create a new note. Notes can be used as context/memory for LLM conversations.",
		{
			"type": "object",
			"properties": {
				"title": {
					"type": "string",
					"description": "Title of the note"
				},
				"content": {
					"type": "string",
					"description": "Content of the note"
				},
				"tab": {
					"type": "string",
					"description": "Optional tab name to add the note to. If not specified, uses current tab."
				}
			},
			"required": ["title", "content"]
		}
	)

	_register_tool("minerva_create_note_tab",
		"Create a new notes tab.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the new tab"
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_list_notes",
		"List all notes in a tab or all tabs.",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Optional tab name. If not specified, lists notes from all tabs."
				}
			},
			"required": []
		}
	)

	_register_tool("minerva_enable_notes",
		"Enable all notes in a tab (makes them active for LLM context).",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Tab name to enable notes in"
				}
			},
			"required": ["tab"]
		}
	)

	_register_tool("minerva_disable_notes",
		"Disable all notes in a tab (excludes them from LLM context).",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Tab name to disable notes in"
				}
			},
			"required": ["tab"]
		}
	)

	_register_tool("minerva_delete_note",
		"Delete a note by its ID.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID of the note to delete"
				}
			},
			"required": ["note_id"]
		}
	)


func _register_editor_tools() -> void:
	_register_tool("minerva_create_text_editor",
		"Create a new text/code editor tab.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the editor tab"
				},
				"content": {
					"type": "string",
					"description": "Optional initial content"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to associate with the editor"
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_create_graphics_editor",
		"Create a new graphics editor tab for image editing.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the editor tab"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to load an image from"
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_get_editor_content",
		"Get the content of a text editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_update_editor",
		"Update the content of a text editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				},
				"content": {
					"type": "string",
					"description": "New content for the editor"
				}
			},
			"required": ["editor_name", "content"]
		}
	)

	_register_tool("minerva_save_editor",
		"Save the editor content to a file.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path. If not specified, uses the associated file."
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_close_editor",
		"Close an editor tab.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab to close"
				},
				"force": {
					"type": "boolean",
					"description": "If true, close without prompting for unsaved changes"
				}
			},
			"required": ["editor_name"]
		}
	)

	# Graphics editor AI tools
	_register_tool("minerva_graphics_get_capabilities",
		"Get available AI models, actions, and parameters for a graphics editor. Call this before generating images to discover what's available.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_graphics_generate",
		"Generate or edit an image using AI (fire-and-forget, returns immediately). NOTE: If you need to SEE the result or ITERATE based on quality, use minerva_graphics_generate_iterative instead - it blocks until the image is visible. This tool is only for when you don't need to evaluate the output.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				},
				"model": {
					"type": "string",
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', or 'mask_edit'"
				},
				"prompt": {
					"type": "string",
					"description": "Positive prompt describing what to generate"
				},
				"negative_prompt": {
					"type": "string",
					"description": "Optional: what to avoid in generation"
				},
				"width": {
					"type": "integer",
					"description": "Image width (64-2048, divisible by 64). Default: 1024"
				},
				"height": {
					"type": "integer",
					"description": "Image height (64-2048, divisible by 64). Default: 1024"
				},
				"steps": {
					"type": "integer",
					"description": "Generation steps (more = higher quality). Default varies by model."
				},
				"source_layer": {
					"type": "string",
					"description": "Layer name for 'edit' and 'mask_edit' actions"
				},
				"mask_layer": {
					"type": "string",
					"description": "Mask layer name for 'mask_edit' action"
				}
			},
			"required": ["editor_name", "model", "action", "prompt"]
		}
	)

	_register_tool("minerva_graphics_generate_iterative",
		"Generate an image with iterative refinement. This tool BLOCKS until the image is fully generated and visible, then returns. After it returns, the new image is visible and you can evaluate it immediately. Use for iterative refinement where you need to see each result before deciding to continue.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				},
				"model": {
					"type": "string",
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', or 'mask_edit'"
				},
				"prompt": {
					"type": "string",
					"description": "Positive prompt describing what to generate"
				},
				"negative_prompt": {
					"type": "string",
					"description": "Optional: what to avoid in generation"
				},
				"width": {
					"type": "integer",
					"description": "Image width (64-2048, divisible by 64). Default: 1024"
				},
				"height": {
					"type": "integer",
					"description": "Image height (64-2048, divisible by 64). Default: 1024"
				},
				"steps": {
					"type": "integer",
					"description": "Generation steps (more = higher quality). Default varies by model."
				},
				"criteria": {
					"type": "string",
					"description": "Success criteria to evaluate against (e.g., 'full front view of star-fighter')"
				}
			},
			"required": ["editor_name", "model", "action", "prompt", "criteria"]
			# Note: iteration is tracked SERVER-SIDE. Do not pass iteration parameter.
		}
	)

#endregion


#region Chat Tool Implementations

func _find_chat_by_id(chat_id: String) -> Variant:
	for history in SingletonObject.ChatList:
		if history.HistoryId == chat_id:
			return history
	return null


func _find_chat_tab_index(chat_id: String) -> int:
	for i in range(SingletonObject.ChatList.size()):
		if SingletonObject.ChatList[i].HistoryId == chat_id:
			return i
	return -1


func _create_chat(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Agent Chat")
	var provider_name: String = args.get("provider", "")

	# Get the chat pane
	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return {"error": "Chat pane not available", "success": false}

	# Map provider name to enum
	var provider_obj = null
	if not provider_name.is_empty():
		var provider_map = {
			"claude_sonnet": SingletonObject.API_MODEL_PROVIDERS.CLAUDE_SONNET,
			"claude_haiku": SingletonObject.API_MODEL_PROVIDERS.CLAUDE_HAIKU,
			"claude_opus": SingletonObject.API_MODEL_PROVIDERS.CLAUDE_OPUS,
			"gpt_nano": SingletonObject.API_MODEL_PROVIDERS.GPT_NANO,
			"gpt_standard": SingletonObject.API_MODEL_PROVIDERS.GPT_STANDARD,
			"gpt_deep": SingletonObject.API_MODEL_PROVIDERS.GPT_DEEP,
			"gemini_flash": SingletonObject.API_MODEL_PROVIDERS.GEMINI_FLASH,
			"gemini_pro": SingletonObject.API_MODEL_PROVIDERS.GEMINI_PRO,
		}
		if provider_map.has(provider_name):
			var enum_val = provider_map[provider_name]
			if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(enum_val):
				provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[enum_val].new()
				print("[MinervaMCPServer] Using provider: %s" % provider_name)

	# Fall back to current selected provider
	if not provider_obj:
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
	print("[MinervaMCPServer] Created chat '%s' with id: %s (model: %s)" % [history.HistoryName, history.HistoryId, provider_display])

	return {
		"success": true,
		"chat_id": history.HistoryId,
		"name": history.HistoryName,
		"provider": provider_display,
		"message": "Chat created. Use the chat_id value (not the name) for subsequent operations."
	}


func _set_system_prompt(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var prompt: String = args.get("prompt", "")

	if chat_id.is_empty():
		return {"error": "chat_id is required", "success": false}

	var history = _find_chat_by_id(chat_id)
	if not history:
		return {"error": "Chat not found: %s" % chat_id, "success": false}

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

	return {"success": true, "message": "System prompt set"}


func _set_agent_mode(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var enabled: bool = args.get("enabled", false)

	if chat_id.is_empty():
		return {"error": "chat_id is required", "success": false}

	var history = _find_chat_by_id(chat_id)
	if not history:
		return {"error": "Chat not found: %s" % chat_id, "success": false}

	history.AgentModeEnabled = enabled

	if args.has("agentic_prompt"):
		history.AgenticSystemPrompt = args.get("agentic_prompt", "")

	if args.has("max_rounds"):
		history.MaxToolCallRounds = int(args.get("max_rounds", 10))

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
		return {"error": "chat_id is required", "success": false}

	if message.is_empty():
		return {"error": "message is required", "success": false}

	var history = _find_chat_by_id(chat_id)
	if not history:
		return {"error": "Chat not found: %s" % chat_id, "success": false}

	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return {"error": "Chat pane not available", "success": false}

	# Find the target chat tab
	var tab_idx = _find_chat_tab_index(chat_id)
	if tab_idx == -1:
		return {"error": "Chat tab not found", "success": false}

	# Save original tab
	var original_tab = chat_pane.current_tab

	# Switch to target chat and execute (fire and forget - no waiting)
	chat_pane.current_tab = tab_idx

	print("[MinervaMCPServer] Sending message to chat '%s': %s" % [history.HistoryName, message.left(50)])
	chat_pane.execute_regular_chat(message)

	# Immediately restore original tab - don't wait for response
	# This prevents breaking the calling agent's loop
	chat_pane.current_tab = original_tab

	return {
		"success": true,
		"message": "Message sent. Use minerva_get_chat_history to check for the response."
	}


func _get_chat_history(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")

	if chat_id.is_empty():
		return {"error": "chat_id is required", "success": false}

	var history = _find_chat_by_id(chat_id)
	if not history:
		return {"error": "Chat not found: %s" % chat_id, "success": false}

	var messages: Array = []
	var role_names = ["user", "assistant", "system", "tool"]

	for item in history.HistoryItemList:
		var role = role_names[item.Role] if item.Role < role_names.size() else "unknown"
		messages.append({
			"role": role,
			"content": item.Message
		})

	return {
		"success": true,
		"chat_id": chat_id,
		"name": history.HistoryName,
		"messages": messages
	}


func _close_chat(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")

	if chat_id.is_empty():
		return {"error": "chat_id is required", "success": false}

	var tab_idx = _find_chat_tab_index(chat_id)
	if tab_idx == -1:
		return {"error": "Chat not found: %s" % chat_id, "success": false}

	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return {"error": "Chat pane not available", "success": false}

	# Close the tab
	chat_pane.get_tab_bar().tab_close_pressed.emit(tab_idx)

	return {"success": true, "message": "Chat closed"}

#endregion


#region Notes Tool Implementations

func _create_note(args: Dictionary) -> Dictionary:
	var title: String = args.get("title", "Untitled")
	var content: String = args.get("content", "")
	var tab_name: String = args.get("tab", "")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	# Create the note
	var NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	var note = NoteScript.create_text_note(title, content)

	# Find or create the tab
	var tab_idx := -1
	if not tab_name.is_empty():
		var note_vbox = notes_container.find_or_create_tab(tab_name)
		tab_idx = notes_container.get_tab_idx_from_control(note_vbox)

	# Add the note
	notes_container.add_note(note, tab_idx)

	return {
		"success": true,
		"note_id": note.uuid,
		"title": title
	}


func _create_note_tab(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Notes")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var note_vbox = notes_container.create_tab(name_)
	var _tab_idx = notes_container.get_tab_idx_from_control(note_vbox)

	return {
		"success": true,
		"tab_name": name_,
		"tab_id": note_vbox.uuid
	}


func _list_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var result: Array = []

	if tab_name.is_empty():
		# List all notes from all tabs
		for i in range(notes_container.get_tab_count()):
			var tab_title = notes_container.get_tab_title(i)
			var notes = notes_container.get_notes(i)
			for note in notes:
				result.append({
					"note_id": note.uuid,
					"title": note.title,
					"enabled": note.enabled,
					"tab": tab_title
				})
	else:
		# List notes from specific tab
		var note_vbox = notes_container.find_tab_by_name(tab_name)
		if not note_vbox:
			return {"error": "Tab not found: %s" % tab_name, "success": false}

		var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
		var notes = notes_container.get_notes(tab_idx)
		for note in notes:
			result.append({
				"note_id": note.uuid,
				"title": note.title,
				"enabled": note.enabled,
				"tab": tab_name
			})

	return {
		"success": true,
		"notes": result,
		"count": result.size()
	}


func _enable_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	if tab_name.is_empty():
		return {"error": "tab is required", "success": false}

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var note_vbox = notes_container.find_tab_by_name(tab_name)
	if not note_vbox:
		return {"error": "Tab not found: %s" % tab_name, "success": false}

	var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
	notes_container.enable_notes(tab_idx)

	return {"success": true, "message": "Notes enabled in tab: %s" % tab_name}


func _disable_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	if tab_name.is_empty():
		return {"error": "tab is required", "success": false}

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var note_vbox = notes_container.find_tab_by_name(tab_name)
	if not note_vbox:
		return {"error": "Tab not found: %s" % tab_name, "success": false}

	var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
	notes_container.disable_notes(tab_idx)

	return {"success": true, "message": "Notes disabled in tab: %s" % tab_name}


func _delete_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")

	if note_id.is_empty():
		return {"error": "note_id is required", "success": false}

	# Find the note by UUID
	var note = SingletonObject.get_registered_object(note_id)
	if not note:
		return {"error": "Note not found: %s" % note_id, "success": false}

	# Remove the note
	note.queue_free()

	return {"success": true, "message": "Note deleted"}

#endregion


#region Editor Tool Implementations

func _find_editor_by_name(name_: String) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	for editor in editor_pane.get_open_editors():
		if editor.tab_title == name_:
			return editor

	# Also check tab titles directly
	for i in range(editor_pane.Tabs.get_tab_count()):
		if editor_pane.Tabs.get_tab_title(i) == name_:
			return editor_pane.Tabs.get_tab_control(i)

	return null


func _create_text_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Untitled")
	var content: String = args.get("content", "")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return {"error": "File not found: %s" % file_path, "success": false}

	# Create the editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.TEXT, file_arg, name_, null)

	# Set content if provided
	if not content.is_empty() and editor.code_edit:
		editor.code_edit.text = content

	return {
		"success": true,
		"editor_name": editor.tab_title
	}


func _create_graphics_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Graphics")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return {"error": "File not found: %s" % file_path, "success": false}

	# Create the graphics editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.GRAPHICS, file_arg, name_, null)

	return {
		"success": true,
		"editor_name": editor.tab_title
	}


func _get_editor_content(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.TEXT:
		return {"error": "Not a text editor", "success": false}

	if not editor.code_edit:
		return {"error": "Editor has no code_edit", "success": false}

	return {
		"success": true,
		"editor_name": editor_name,
		"content": editor.code_edit.text
	}


func _update_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var content: String = args.get("content", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.TEXT:
		return {"error": "Not a text editor", "success": false}

	if not editor.code_edit:
		return {"error": "Editor has no code_edit", "success": false}

	editor.code_edit.text = content

	return {
		"success": true,
		"message": "Editor content updated"
	}


func _save_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var file_path: String = args.get("file_path", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	# Set file path if provided
	if not file_path.is_empty():
		editor.file = file_path

	if editor.file.is_empty():
		return {"error": "No file path specified", "success": false}

	# Save the editor
	editor.save()

	return {
		"success": true,
		"file_path": editor.file
	}


func _close_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var force: bool = args.get("force", false)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var tab_idx = editor_pane.Tabs.get_tab_idx_from_control(editor)
	if tab_idx == -1:
		return {"error": "Editor not in tab container", "success": false}

	# Check for unsaved content
	if not force and not editor.is_content_saved():
		return {
			"error": "Editor has unsaved content. Use force=true to close anyway.",
			"success": false,
			"has_unsaved_content": true
		}

	# Close the tab
	editor_pane.Tabs.remove_child(editor)

	return {"success": true, "message": "Editor closed"}


func _get_graphics_capabilities(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return {"error": "Not a graphics editor: %s" % editor_name, "success": false}

	if not editor.graphics_editor:
		return {"error": "Graphics editor not initialized", "success": false}

	return editor.graphics_editor.get_ai_capabilities()


func _generate_graphics(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return {"error": "Not a graphics editor: %s" % editor_name, "success": false}

	if not editor.graphics_editor:
		return {"error": "Graphics editor not initialized", "success": false}

	var result = editor.graphics_editor.execute_ai_action(args)

	# Add warning that image won't be visible to LLM (non-iterative is fire-and-forget)
	if result.get("success", false):
		result["warning"] = "IMPORTANT: This is the non-iterative tool. The generated image will NOT be visible to you (the LLM). You cannot evaluate or describe this image. If you need to see and evaluate the result, use minerva_graphics_generate_iterative instead."
		result["image_visible"] = false

	return result


func _generate_graphics_iterative(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var max_iterations: int = SingletonObject.max_image_iterations
	var criteria: String = args.get("criteria", "")

	# SESSION-WIDE iteration tracking (prevents bypass via creating new editors)
	var current_time := Time.get_ticks_msec()
	var reset_threshold := 5 * 60 * 1000  # Reset after 5 minutes of inactivity

	# Reset counter if it's been too long since last attempt (allows new sessions)
	if current_time - _session_attempts_reset_time > reset_threshold:
		_session_iterative_attempts = 0

	# Increment attempt counter BEFORE doing anything
	_session_iterative_attempts += 1
	_session_attempts_reset_time = current_time
	var iteration: int = _session_iterative_attempts

	print("[MinervaMCPServer] Iterative generation: %d/%d (session-wide)" % [iteration, max_iterations])

	# Check iteration limit (session-enforced)
	if iteration > max_iterations:
		# Reset for next session
		_session_iterative_attempts = 0
		return {
			"error": "Maximum iterations (%d) reached for this session. Creating new editors will NOT bypass this limit. You must accept the current result or ask the user to increase the limit in settings." % max_iterations,
			"success": false,
			"iteration": iteration,
			"max_iterations": max_iterations
		}

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return {"error": "Editor not found: %s" % editor_name, "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return {"error": "Not a graphics editor: %s" % editor_name, "success": false}

	if not editor.graphics_editor:
		return {"error": "Graphics editor not initialized", "success": false}

	# Start generation
	var result = editor.graphics_editor.execute_ai_action(args)
	print("[MinervaMCPServer] execute_ai_action result: %s" % str(result))
	if not result.get("success"):
		print("[MinervaMCPServer] Generation failed: %s" % result.get("error", "unknown"))
		return result

	var request_id: String = result.get("request_id", "")
	print("[MinervaMCPServer] Waiting for image generation to complete (blocking): %s" % request_id)

	# === BLOCKING: Wait for image generation to complete ===
	var image_state := {"completed": false, "received_id": ""}
	var image_handler := func(_fname: String, rid: String, _buffer: PackedByteArray):
		if rid == request_id:
			image_state.completed = true
			image_state.received_id = rid
			print("[MinervaMCPServer] Image generation signal received for: %s" % rid)

	MediaGen.pass_image_to_editor.connect(image_handler)

	# Wait for image with timeout (4 minutes for slow generation backends)
	var image_timeout := 240.0
	var image_elapsed := 0.0
	while not image_state.completed and image_elapsed < image_timeout:
		await Engine.get_main_loop().create_timer(0.2).timeout
		image_elapsed += 0.2

	# Disconnect the handler
	if MediaGen.pass_image_to_editor.is_connected(image_handler):
		MediaGen.pass_image_to_editor.disconnect(image_handler)

	if not image_state.completed:
		push_error("[MinervaMCPServer] Timeout waiting for image generation")
		return {"error": "Image generation timed out after %.0f seconds" % image_timeout, "success": false}

	print("[MinervaMCPServer] Image generated after %.1f seconds, now preparing for display..." % image_elapsed)

	# Wait for graphics editor to process the image buffer
	await Engine.get_main_loop().create_timer(0.5).timeout

	# === BLOCKING: Wait for note to be ready ===
	if not editor or not is_instance_valid(editor):
		return {"error": "Editor no longer valid", "success": false}

	# Toggle OFF first to clean up any existing state
	print("[MinervaMCPServer] Toggling OFF to clean up existing state...")
	editor.toggle(false)

	# Wait for proxy to be fully cleaned up (event-driven, not arbitrary timeout)
	var cleanup_start := Time.get_ticks_msec()
	while editor._proxy_note != null:
		await Engine.get_main_loop().process_frame
		if Time.get_ticks_msec() - cleanup_start > 5000:  # 5s safety timeout
			push_warning("[MinervaMCPServer] Proxy cleanup taking too long, proceeding anyway")
			break

	print("[MinervaMCPServer] Cleanup complete, setting up signal handler...")

	# === BLOCKING: Wait for note to be ready (using same pattern as image wait) ===
	# Connect handler BEFORE toggle to ensure we don't miss the signal
	var note_state := {"received": false, "note": null}
	var note_handler := func(note: Note):
		print("[MinervaMCPServer] note_ready_for_chat handler fired! note=%s" % note)
		note_state["received"] = true
		note_state["note"] = note

	editor.note_ready_for_chat.connect(note_handler, CONNECT_ONE_SHOT)

	# Toggle ON - this triggers _on_check_button_toggled which creates the proxy and note
	editor.toggle(true)
	print("[MinervaMCPServer] Toggled ON, waiting for note_ready_for_chat signal...")

	# Poll until note is ready or timeout (same pattern that works for image generation)
	var note_timeout := 120.0
	var note_elapsed := 0.0
	while not note_state["received"] and note_elapsed < note_timeout:
		await Engine.get_main_loop().create_timer(0.2).timeout
		note_elapsed += 0.2
		if int(note_elapsed) % 5 == 0 and note_elapsed > 0.3:
			print("[MinervaMCPServer] Still waiting for note... %.1fs elapsed, state=%s" % [note_elapsed, note_state])

	# Clean up handler if we timed out
	if not note_state["received"]:
		if editor.note_ready_for_chat.is_connected(note_handler):
			editor.note_ready_for_chat.disconnect(note_handler)
		push_error("[MinervaMCPServer] Timeout waiting for note_ready_for_chat after %.0f seconds" % note_timeout)
		return {"error": "Note composition timed out after %.0f seconds" % note_timeout, "success": false}

	var received_note = note_state["note"]
	print("[MinervaMCPServer] Note ready! Received: %s" % received_note)

	if received_note == null:
		push_error("[MinervaMCPServer] note_ready_for_chat returned null")
		return {"error": "Note composition failed - received null note", "success": false}

	print("[MinervaMCPServer] Note ready after %.1f seconds. Total time: %.1f seconds" % [note_elapsed, image_elapsed + note_elapsed])

	# === SUCCESS: Image is now visible to the LLM ===
	var response_msg: String
	if iteration < max_iterations:
		response_msg = "Image generation complete (iteration %d/%d). The image is now visible. Evaluate it against the criteria: '%s'. If it meets the criteria, inform the user. If not, call this tool again with an adjusted prompt (iteration is tracked automatically)." % [iteration, max_iterations, criteria]
	else:
		response_msg = "Image generation complete (FINAL iteration %d/%d). The image is now visible. This was the LAST allowed iteration for this session. Creating new editors or using other tools will NOT give you more attempts. Evaluate it against the criteria: '%s' and inform the user of the final result." % [iteration, max_iterations, criteria]

	return {
		"success": true,
		"message": response_msg,
		"iteration": iteration,
		"max_iterations": max_iterations,
		"image_visible": true
	}

#endregion
