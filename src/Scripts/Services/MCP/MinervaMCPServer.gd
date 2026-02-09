class_name MinervaMCPServer
extends RefCounted
## Internal MCP server that allows LLMs to control Minerva's own features.
## Provides tools for managing chats, notes, and editors.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")
const SpreadsheetFileHandlerScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")
const NotesContainerScript := preload("res://Scenes/note/NotesContainer.gd")
const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")

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
	# Always register tools so they're available for HTTP server
	# (internal LLM access is gated by server_enabled flag)
	if mcp_manager:
		_register_chat_tools()
		_register_notes_tools()
		_register_editor_tools()
		_register_spreadsheet_tools()
		_register_kanban_tools()
		_register_pcb_tools()
		_register_video_editor_tools()
		print("[MinervaMCPServer] Registered %d tools" % get_tool_count())


## Register all minerva_* tools in the MCPManager's tool_registry
func register_tools() -> void:
	if not mcp_manager:
		push_error("[MinervaMCPServer] No MCPManager reference")
		return

	# Tools are already registered in _init, this is a no-op now
	pass


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


## Disconnect (disable) the minerva server - disables internal LLM access
## (tools remain registered for HTTP server access)
func disconnect_server() -> void:
	if not server_enabled:
		return

	server_enabled = false
	print("[MinervaMCPServer] Disconnected")


## Execute a minerva_* tool (requires internal connection to be enabled)
func execute_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not server_enabled:
		return {"error": "Minerva server not connected", "success": false}
	return await _execute_tool_impl(tool_name, arguments)


## Execute a minerva_* tool for HTTP/external access (does not require internal connection)
func execute_tool_for_http(tool_name: String, arguments: Dictionary) -> Dictionary:
	return await _execute_tool_impl(tool_name, arguments)


## Internal tool execution implementation
func _execute_tool_impl(tool_name: String, arguments: Dictionary) -> Dictionary:
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
		"minerva_list_editors":
			return _list_editors(arguments)
		"minerva_rename_editor":
			return _rename_editor(arguments)

		# Graphics editor AI tools
		"minerva_graphics_get_capabilities":
			return _get_graphics_capabilities(arguments)
		"minerva_graphics_generate":
			return _generate_graphics(arguments)
		"minerva_graphics_generate_iterative":
			return await _generate_graphics_iterative(arguments)

		# Kanban board tools
		"minerva_kanban_create_task":
			return _kanban_create_task(arguments)
		"minerva_kanban_list_boards":
			return _kanban_list_boards(arguments)
		"minerva_kanban_get_tasks":
			return _kanban_get_tasks(arguments)
		"minerva_kanban_update_task":
			return _kanban_update_task(arguments)
		"minerva_kanban_move_task":
			return _kanban_move_task(arguments)
		"minerva_kanban_delete_task":
			return _kanban_delete_task(arguments)

		# Spreadsheet tools
		"minerva_create_spreadsheet_editor":
			return await _create_spreadsheet_editor(arguments)
		"minerva_get_spreadsheet_data":
			return _get_spreadsheet_data(arguments)
		"minerva_update_spreadsheet_data":
			return _update_spreadsheet_data(arguments)
		"minerva_add_spreadsheet_row":
			return _add_spreadsheet_row(arguments)
		"minerva_add_spreadsheet_column":
			return _add_spreadsheet_column(arguments)
		"minerva_delete_spreadsheet_row":
			return _delete_spreadsheet_row(arguments)
		"minerva_delete_spreadsheet_column":
			return _delete_spreadsheet_column(arguments)
		"minerva_insert_spreadsheet_row":
			return _insert_spreadsheet_row(arguments)
		"minerva_insert_spreadsheet_column":
			return _insert_spreadsheet_column(arguments)
		"minerva_format_cells":
			return _format_cells(arguments)
		"minerva_set_row_height":
			return _set_row_height(arguments)
		"minerva_set_column_width":
			return _set_column_width(arguments)
		"minerva_set_cell_formula":
			return _set_cell_formula(arguments)
		"minerva_create_chart":
			return _create_chart(arguments)
		"minerva_get_chart_image":
			return await _get_chart_image(arguments)
		"minerva_list_charts":
			return _list_charts(arguments)
		"minerva_update_chart":
			return _update_chart(arguments)
		"minerva_delete_chart":
			return _delete_chart(arguments)
		"minerva_refresh_charts":
			return _refresh_charts(arguments)
		"minerva_link_spreadsheet_to_note":
			return _link_spreadsheet_to_note(arguments)
		"minerva_export_to_nudge":
			return await _export_to_nudge(arguments)
		"minerva_undo_spreadsheet":
			return _undo_spreadsheet(arguments)
		"minerva_redo_spreadsheet":
			return _redo_spreadsheet(arguments)
		"minerva_get_spreadsheet_history":
			return _get_spreadsheet_history(arguments)
		"minerva_fill_down":
			return _fill_down_spreadsheet(arguments)
		"minerva_recalculate":
			return _recalculate_spreadsheet(arguments)

		# PCB Editor tools
		"minerva_create_pcb_editor":
			return _create_pcb_editor(arguments)
		"minerva_pcb_set_board_size":
			return _pcb_set_board_size(arguments)
		"minerva_pcb_get_components":
			return _pcb_get_components(arguments)
		"minerva_pcb_describe_component":
			return _pcb_describe_component(arguments)
		"minerva_pcb_spatial_query":
			return _pcb_spatial_query(arguments)
		"minerva_pcb_get_nets":
			return _pcb_get_nets(arguments)
		"minerva_pcb_add_component":
			return _pcb_add_component(arguments)
		"minerva_pcb_move_component":
			return _pcb_move_component(arguments)
		"minerva_pcb_move_relative":
			return _pcb_move_relative(arguments)
		"minerva_pcb_rotate_component":
			return _pcb_rotate_component(arguments)
		"minerva_pcb_delete_component":
			return _pcb_delete_component(arguments)
		"minerva_pcb_connect_net":
			return _pcb_connect_net(arguments)
		"minerva_pcb_export_csv":
			return _pcb_export_csv(arguments)
		"minerva_pcb_export_yaml":
			return _pcb_export_yaml(arguments)
		"minerva_pcb_import_csv":
			return _pcb_import_csv(arguments)
		"minerva_pcb_import_footprint_geometry":
			return _pcb_import_footprint_geometry(arguments)
		"minerva_pcb_import_trace_geometry":
			return _pcb_import_trace_geometry(arguments)
		"minerva_pcb_add_annotation":
			return _pcb_add_annotation(arguments)
		"minerva_pcb_list_annotations":
			return _pcb_list_annotations(arguments)
		"minerva_pcb_remove_annotation":
			return _pcb_remove_annotation(arguments)
		"minerva_pcb_clear_annotations":
			return _pcb_clear_annotations(arguments)
		"minerva_pcb_add_route_hint":
			return _pcb_add_route_hint(arguments)
		"minerva_pcb_list_route_hints":
			return _pcb_list_route_hints(arguments)
		"minerva_pcb_remove_route_hint":
			return _pcb_remove_route_hint(arguments)
		"minerva_pcb_clear_route_hints":
			return _pcb_clear_route_hints(arguments)
		"minerva_pcb_interpret_route_hints":
			return _pcb_interpret_route_hints(arguments)
		"minerva_pcb_get_change_journal":
			return _pcb_get_change_journal(arguments)
		"minerva_pcb_get_pin_position":
			return _pcb_get_pin_position(arguments)
		"minerva_pcb_get_image":
			return await _pcb_get_image(arguments)
		"minerva_pcb_create_note":
			return await _pcb_create_note(arguments)

		# Video editor tools
		"minerva_create_video_editor":
			return _create_video_editor(arguments)
		"minerva_video_add_cut":
			return _video_add_cut(arguments)
		"minerva_video_add_speed_region":
			return _video_add_speed_region(arguments)
		"minerva_video_remove_edit":
			return _video_remove_edit(arguments)
		"minerva_video_set_pip_position":
			return _video_set_pip_position(arguments)
		"minerva_video_set_crop_position":
			return _video_set_crop_position(arguments)
		"minerva_video_get_state":
			return _video_get_state(arguments)
		"minerva_video_export":
			return _video_export(arguments)
		"minerva_video_list_recordings":
			return _video_list_recordings(arguments)

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

	_register_tool("minerva_list_editors",
		"List all open editor tabs (text, graphics, and spreadsheet editors).",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	)

	_register_tool("minerva_rename_editor",
		"Rename an editor tab (text, graphics, or spreadsheet).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Current name/title of the editor tab"
				},
				"new_name": {
					"type": "string",
					"description": "New name for the editor tab"
				}
			},
			"required": ["editor_name", "new_name"]
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
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen', 'qwen_2511_flex')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', 'mask_edit', 'compose_2', or 'compose_3'"
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
				},
				"image1_layer": {
					"type": "string",
					"description": "First image layer name for 'edit' (qwen_2511_flex) or 'compose_2'/'compose_3' actions"
				},
				"image2_layer": {
					"type": "string",
					"description": "Second image layer name for 'compose_2' or 'compose_3' actions"
				},
				"image3_layer": {
					"type": "string",
					"description": "Third image layer name for 'compose_3' action"
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
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen', 'qwen_2511_flex')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', 'mask_edit', 'compose_2', or 'compose_3'"
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
				},
				"source_layer": {
					"type": "string",
					"description": "Layer name for 'edit' and 'mask_edit' actions"
				},
				"image1_layer": {
					"type": "string",
					"description": "First image layer name for 'edit' (qwen_2511_flex) or 'compose_2'/'compose_3' actions"
				},
				"image2_layer": {
					"type": "string",
					"description": "Second image layer name for 'compose_2' or 'compose_3' actions"
				},
				"image3_layer": {
					"type": "string",
					"description": "Third image layer name for 'compose_3' action"
				}
			},
			"required": ["editor_name", "model", "action", "prompt", "criteria"]
			# Note: iteration is tracked SERVER-SIDE. Do not pass iteration parameter.
		}
	)


func _register_spreadsheet_tools() -> void:
	_register_tool("minerva_create_spreadsheet_editor",
		"Create a new spreadsheet editor tab. Returns an editor_name that can be used for subsequent operations.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the spreadsheet tab"
				},
				"csv_content": {
					"type": "string",
					"description": "Optional initial CSV content to populate the spreadsheet"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to load (CSV, TSV, XLSX, or .minsheet)"
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_get_spreadsheet_data",
		"Get the data from a spreadsheet in various formats. Returns data_starts_at_row (1-based) to show where content begins.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"format": {
					"type": "string",
					"description": "Output format: 'csv', 'json', or 'markdown'. Default: 'csv'",
					"enum": ["csv", "json", "markdown"]
				},
				"range": {
					"type": "string",
					"description": "Optional cell range to get (e.g., 'A1:C10'). If not specified, returns all data."
				},
				"include_empty_rows": {
					"type": "boolean",
					"description": "If true, include leading empty rows in output. Default: false (only returns used data range)."
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_update_spreadsheet_data",
		"Update cells in a spreadsheet. Can update individual cells or load entire CSV content.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"csv_content": {
					"type": "string",
					"description": "Full CSV content to replace all data"
				},
				"cells": {
					"type": "array",
					"description": "Array of cell updates: [{\"cell\": \"A1\", \"value\": \"Hello\"}, ...]",
					"items": {
						"type": "object",
						"properties": {
							"cell": {"type": "string", "description": "Cell reference (e.g., 'A1', 'B2')"},
							"value": {"type": "string", "description": "Value to set (string, number, or formula starting with '=')"}
						},
						"required": ["cell", "value"]
					}
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_add_spreadsheet_row",
		"Add a new row to the spreadsheet with optional values.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_row": {
					"type": "integer",
					"description": "Row index to insert at (0-based). If not specified, appends at the end."
				},
				"values": {
					"type": "array",
					"description": "Array of values for the new row (one per column)",
					"items": {"type": "string"}
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_add_spreadsheet_column",
		"Add a new column to the spreadsheet with optional header.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_col": {
					"type": "integer",
					"description": "Column index to insert at (0-based). If not specified, appends at the end."
				},
				"header": {
					"type": "string",
					"description": "Header text for the new column"
				},
				"values": {
					"type": "array",
					"description": "Array of values for the column (starting from row 1 if header is provided)",
					"items": {"type": "string"}
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_delete_spreadsheet_row",
		"Delete a row from the spreadsheet. All rows below shift up. This action can be undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"row": {
					"type": "integer",
					"description": "Row number to delete (1-based, like Excel). Row 1 is the first row."
				}
			},
			"required": ["editor_name", "row"]
		}
	)

	_register_tool("minerva_delete_spreadsheet_column",
		"Delete a column from the spreadsheet. All columns to the right shift left. This action can be undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"column": {
					"type": "integer",
					"description": "Column number to delete (1-based). Column 1 is A, column 2 is B, etc."
				}
			},
			"required": ["editor_name", "column"]
		}
	)

	_register_tool("minerva_insert_spreadsheet_row",
		"Insert an empty row at a specific position. All rows at and below shift down.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_row": {
					"type": "integer",
					"description": "Row index where the empty row will be inserted (0-based)."
				}
			},
			"required": ["editor_name", "at_row"]
		}
	)

	_register_tool("minerva_insert_spreadsheet_column",
		"Insert an empty column at a specific position. All columns at and to the right shift right.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_column": {
					"type": "integer",
					"description": "Column index where the empty column will be inserted (0-based). 0 = A."
				}
			},
			"required": ["editor_name", "at_column"]
		}
	)

	_register_tool("minerva_format_cells",
		"Apply formatting to cells or a range of cells.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"range": {
					"type": "string",
					"description": "Cell range to format (e.g., 'A1', 'A1:C1', 'A:A' for whole column)"
				},
				"bold": {
					"type": "boolean",
					"description": "Set text bold"
				},
				"italic": {
					"type": "boolean",
					"description": "Set text italic"
				},
				"alignment": {
					"type": "string",
					"description": "Text alignment: 'left', 'center', or 'right'",
					"enum": ["left", "center", "right"]
				},
				"text_color": {
					"type": "string",
					"description": "Text color as hex (e.g., '#FF0000' for red)"
				},
				"bg_color": {
					"type": "string",
					"description": "Background color as hex (e.g., '#FFFF00' for yellow)"
				},
				"number_format": {
					"type": "string",
					"description": "Number display format: 'none' (default), 'currency' or 'usd' ($X,XXX.XX), 'percent' (X.XX%), 'decimal' (X.XX)",
					"enum": ["none", "currency", "usd", "percent", "decimal"]
				},
				"wrap_text": {
					"type": "boolean",
					"description": "Enable text wrapping in cell (displays text on multiple lines)"
				}
			},
			"required": ["editor_name", "range"]
		}
	)

	_register_tool("minerva_set_row_height",
		"Set the height of one or more spreadsheet rows. Use to make wrapped text visible.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"rows": {
					"type": "array",
					"description": "Array of row configs. Row numbers are 1-based.",
					"items": {
						"type": "object",
						"properties": {
							"row": {
								"type": "integer",
								"description": "Row number (1-based)"
							},
							"height": {
								"type": "number",
								"description": "Height in pixels (min 16, max 200)"
							}
						},
						"required": ["row", "height"]
					}
				}
			},
			"required": ["editor_name", "rows"]
		}
	)

	_register_tool("minerva_set_column_width",
		"Set the width of one or more spreadsheet columns. Use to make content fully visible.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"columns": {
					"type": "array",
					"description": "Array of column configs. Column can be a letter (A, B, ...) or 1-based number.",
					"items": {
						"type": "object",
						"properties": {
							"column": {
								"type": "string",
								"description": "Column letter (e.g., 'A', 'B') or 1-based number (e.g., '1', '2')"
							},
							"width": {
								"type": "number",
								"description": "Width in pixels (min 30, max 500)"
							}
						},
						"required": ["column", "width"]
					}
				}
			},
			"required": ["editor_name", "columns"]
		}
	)

	_register_tool("minerva_set_cell_formula",
		"Set a formula in a specific cell.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"cell": {
					"type": "string",
					"description": "Cell reference (e.g., 'A1', 'B2')"
				},
				"formula": {
					"type": "string",
					"description": "Formula to set (e.g., '=SUM(A1:A10)', '=A1+B1'). The '=' prefix is optional."
				}
			},
			"required": ["editor_name", "cell", "formula"]
		}
	)

	_register_tool("minerva_create_chart",
		"Create a chart from spreadsheet data.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"title": {
					"type": "string",
					"description": "Chart title"
				},
				"type": {
					"type": "string",
					"description": "Chart type: 'line' or 'bar'. Default: 'line'",
					"enum": ["line", "bar"]
				},
				"x_range": {
					"type": "string",
					"description": "Cell range for X-axis values (e.g., 'A1:A10')"
				},
				"series": {
					"type": "array",
					"description": "Array of series ranges (e.g., ['B1:B10', 'C1:C10'])",
					"items": {"type": "string"}
				},
				"x_is_date": {
					"type": "boolean",
					"description": "Whether X-axis contains date values. Default: false"
				},
				"first_row_is_header": {
					"type": "boolean",
					"description": "Whether first row contains headers (skip for data, use for labels). Default: true"
				}
			},
			"required": ["editor_name", "x_range", "series"]
		}
	)

	_register_tool("minerva_get_chart_image",
		"Export a chart as a base64-encoded PNG image for LLM viewing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_index": {
					"type": "integer",
					"description": "Index of the chart to export (0-based). Default: 0 (first chart)"
				},
				"width": {
					"type": "integer",
					"description": "Image width in pixels. Default: 800"
				},
				"height": {
					"type": "integer",
					"description": "Image height in pixels. Default: 400"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_list_charts",
		"List all charts in a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_update_chart",
		"Update an existing chart's properties. Use this when data ranges change or to modify chart appearance.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_id": {
					"type": "string",
					"description": "The chart ID to update (from minerva_list_charts or minerva_create_chart)"
				},
				"chart_index": {
					"type": "integer",
					"description": "Alternative: chart index (0-based) if chart_id not provided"
				},
				"title": {
					"type": "string",
					"description": "New chart title"
				},
				"type": {
					"type": "string",
					"description": "Chart type: 'line' or 'bar'",
					"enum": ["line", "bar"]
				},
				"x_range": {
					"type": "string",
					"description": "New cell range for X-axis values (e.g., 'A1:A20')"
				},
				"series": {
					"type": "array",
					"description": "New array of series ranges (replaces existing series)",
					"items": {"type": "string"}
				},
				"x_is_date": {
					"type": "boolean",
					"description": "Whether X-axis contains date values"
				},
				"first_row_is_header": {
					"type": "boolean",
					"description": "Whether first row contains headers"
				},
				"x_axis_label": {
					"type": "string",
					"description": "X-axis label"
				},
				"y_axis_label": {
					"type": "string",
					"description": "Y-axis label"
				},
				"show_legend": {
					"type": "boolean",
					"description": "Whether to show the legend"
				},
				"y_auto_scale": {
					"type": "boolean",
					"description": "Whether to auto-scale Y axis"
				},
				"y_min": {
					"type": "number",
					"description": "Y-axis minimum (when y_auto_scale is false)"
				},
				"y_max": {
					"type": "number",
					"description": "Y-axis maximum (when y_auto_scale is false)"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_delete_chart",
		"Delete a chart from a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_id": {
					"type": "string",
					"description": "The chart ID to delete"
				},
				"chart_index": {
					"type": "integer",
					"description": "Alternative: chart index (0-based) if chart_id not provided"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_refresh_charts",
		"Refresh all charts in a spreadsheet to reflect current data. Call this after updating spreadsheet data.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_link_spreadsheet_to_note",
		"Create a linked note from a spreadsheet. The note displays the spreadsheet as a markdown table. Editing the note opens the spreadsheet editor. Changes sync bidirectionally.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab to link"
				},
				"note_title": {
					"type": "string",
					"description": "Title for the new note. Defaults to spreadsheet name if not provided"
				},
				"thread_name": {
					"type": "string",
					"description": "Name of the notes thread/tab to add the note to. Creates new thread if doesn't exist"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_export_to_nudge",
		"Export spreadsheet data to the Nudge MCP hint system for quick LLM retrieval.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"component": {
					"type": "string",
					"description": "Nudge component name for organizing hints (e.g., 'finance', 'inventory')"
				},
				"key": {
					"type": "string",
					"description": "Nudge key for this data (e.g., 'monthly_revenue', 'stock_levels')"
				},
				"format": {
					"type": "string",
					"description": "Export format: 'raw' (full JSON), 'summary' (row/col counts, totals), 'schema' (column names/types), 'timeseries' (date-indexed), 'kv_pairs' (two-column key-value)",
					"enum": ["raw", "summary", "schema", "timeseries", "kv_pairs"]
				},
				"include_charts": {
					"type": "boolean",
					"description": "Include chart descriptions in the export. Default: false"
				}
			},
			"required": ["editor_name", "component", "key"]
		}
	)

	_register_tool("minerva_undo_spreadsheet",
		"Undo the last action in a spreadsheet editor. Returns information about what was undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"count": {
					"type": "integer",
					"description": "Number of actions to undo (default: 1). Use this to undo multiple steps at once."
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_redo_spreadsheet",
		"Redo a previously undone action in a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"count": {
					"type": "integer",
					"description": "Number of actions to redo (default: 1). Use this to redo multiple steps at once."
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_get_spreadsheet_history",
		"Get the undo/redo history status of a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_fill_down",
		"Fill down formulas/values from a source row to target rows. Copies the content from the source row and adjusts relative cell references (e.g., A1 becomes A2, A3, etc.). Absolute references ($A$1) are preserved. This is equivalent to Excel's Ctrl+D fill down feature.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"source_row": {
					"type": "integer",
					"description": "The 1-based row number containing the formulas/values to copy (e.g., 2 for row 2)"
				},
				"target_rows": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Array of 1-based row numbers to fill into (e.g., [3, 4, 5] to fill rows 3-5)"
				},
				"columns": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Array of column letters to fill (e.g., ['B', 'C', 'D'] or ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']). If omitted, fills all columns with data in the source row."
				}
			},
			"required": ["editor_name", "source_row", "target_rows"]
		}
	)

	_register_tool("minerva_recalculate",
		"Recalculate all formulas in a spreadsheet. Use this after bulk operations or when cross-sheet references need refreshing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
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
	var _NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	var note = _NoteScript.create_text_note(title, content)

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


func _list_editors(_args: Dictionary) -> Dictionary:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var editors: Array[Dictionary] = []

	for i in range(editor_pane.Tabs.get_tab_count()):
		var editor = editor_pane.Tabs.get_tab_control(i)
		var tab_title = editor_pane.Tabs.get_tab_title(i)

		var editor_type: String = "unknown"
		if editor.has_method("get") and "type" in editor:
			match editor.type:
				EditorGDScript.Type.TEXT:
					editor_type = "text"
				EditorGDScript.Type.GRAPHICS:
					editor_type = "graphics"
				EditorGDScript.Type.SPREADSHEET:
					editor_type = "spreadsheet"
				EditorGDScript.Type.PCB:
					editor_type = "pcb"

		var editor_info: Dictionary = {
			"name": tab_title,
			"type": editor_type,
			"index": i
		}

		# Add file path if available
		if "file" in editor and editor.file:
			editor_info["file_path"] = editor.file

		# Add saved status if available
		if editor.has_method("is_content_saved"):
			editor_info["saved"] = editor.is_content_saved()

		editors.append(editor_info)

	return {
		"success": true,
		"count": editors.size(),
		"editors": editors
	}


func _rename_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var new_name: String = args.get("new_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if new_name.is_empty():
		return {"error": "new_name is required", "success": false}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Find the editor by name
	for i in range(editor_pane.Tabs.get_tab_count()):
		var tab_title = editor_pane.Tabs.get_tab_title(i)
		if tab_title == editor_name:
			editor_pane.Tabs.set_tab_title(i, new_name)
			# Also update the editor's tab_title property
			var editor_control = editor_pane.Tabs.get_tab_control(i)
			if editor_control and editor_control is Editor:
				editor_control.tab_title = new_name
			return {
				"success": true,
				"old_name": editor_name,
				"new_name": new_name,
				"message": "Editor renamed from '%s' to '%s'" % [editor_name, new_name]
			}

	return {"error": "Editor not found: %s" % editor_name, "success": false}


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


#region Kanban Tool Registration

func _register_kanban_tools() -> void:
	_register_tool("minerva_kanban_create_task",
		"Create a new task on a Kanban board. The task will be added to the specified board with source tracking showing it was created by an agent.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab to add the task to"
				},
				"title": {
					"type": "string",
					"description": "Title of the task"
				},
				"description": {
					"type": "string",
					"description": "Detailed description of the task"
				},
				"priority": {
					"type": "integer",
					"description": "Priority 1-5 (1=highest, 5=lowest). Default: 2"
				},
				"status": {
					"type": "string",
					"description": "Initial status: plan, in_progress, ai_review, human_review, done. Default: plan",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name", "title", "description"]
		}
	)

	_register_tool("minerva_kanban_list_boards",
		"List all open Kanban boards (editor tabs of type KANBAN).",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	)

	_register_tool("minerva_kanban_get_tasks",
		"Get all tasks from a Kanban board, optionally filtered by status.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"status": {
					"type": "string",
					"description": "Optional: Filter by status (plan, in_progress, ai_review, human_review, done)",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name"]
		}
	)

	_register_tool("minerva_kanban_update_task",
		"Update an existing task on a Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to update"
				},
				"title": {
					"type": "string",
					"description": "New title (optional)"
				},
				"description": {
					"type": "string",
					"description": "New description (optional)"
				},
				"priority": {
					"type": "integer",
					"description": "New priority 1-5 (optional)"
				}
			},
			"required": ["board_name", "task_id"]
		}
	)

	_register_tool("minerva_kanban_move_task",
		"Move a task to a different status column on the Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to move"
				},
				"new_status": {
					"type": "string",
					"description": "New status: plan, in_progress, ai_review, human_review, done",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name", "task_id", "new_status"]
		}
	)

	_register_tool("minerva_kanban_delete_task",
		"Delete a task from a Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to delete"
				}
			},
			"required": ["board_name", "task_id"]
		}
	)

#endregion


#region Kanban Tool Implementations

func _find_kanban_board_by_name(name_: String):  # Returns AutocoderKanbanBoard or null
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	# Clean up the name - models sometimes add whitespace/newlines
	var clean_name = name_.strip_edges()
	
	# First try exact match
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN and editor.tab_title == clean_name:
			return editor.kanban_board
	
	# Try case-insensitive match
	var lower_name = clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN and editor.tab_title.to_lower() == lower_name:
			return editor.kanban_board
	
	# Try partial/contains match (in case model adds extra text)
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN:
			if editor.tab_title.to_lower().contains(lower_name) or lower_name.contains(editor.tab_title.to_lower()):
				return editor.kanban_board

	return null


func _get_all_kanban_boards() -> Array[Dictionary]:
	var boards: Array[Dictionary] = []
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return boards

	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN and editor.kanban_board:
			var task_count = 0
			if editor.kanban_board.task_store:
				task_count = editor.kanban_board.task_store.get_task_count()
			boards.append({
				"name": editor.tab_title,
				"session_id": editor.kanban_board.task_store.session_id if editor.kanban_board.task_store else "",
				"task_count": task_count
			})

	return boards


func _status_string_to_enum(status_str: String) -> int:  # Returns AutocoderTask.TaskStatus
	var AutocoderTaskClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTask.gd")
	match status_str.to_lower():
		"plan":
			return AutocoderTaskClass.TaskStatus.PLAN
		"in_progress":
			return AutocoderTaskClass.TaskStatus.IN_PROGRESS
		"ai_review":
			return AutocoderTaskClass.TaskStatus.AI_REVIEW
		"human_review":
			return AutocoderTaskClass.TaskStatus.HUMAN_REVIEW
		"done":
			return AutocoderTaskClass.TaskStatus.DONE
		_:
			return AutocoderTaskClass.TaskStatus.PLAN


func _kanban_create_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var title: String = str(args.get("title", "")).strip_edges()
	var description: String = str(args.get("description", "")).strip_edges()
	var priority: int = int(args.get("priority", 2))
	var status_str: String = str(args.get("status", "plan")).strip_edges()

	if board_name.is_empty():
		return {"error": "board_name is required", "success": false}
	if title.is_empty():
		return {"error": "title is required", "success": false}

	var board = _find_kanban_board_by_name(board_name)
	if not board:
		return {"error": "Kanban board not found: %s" % board_name, "success": false}

	if not board.task_store:
		return {"error": "Kanban board has no task store", "success": false}

	var status = _status_string_to_enum(status_str)

	# Get context for source tracking
	var source_context = "Agent Tool"
	var chat_pane = SingletonObject.Chats
	if chat_pane and chat_pane.current_tab >= 0 and chat_pane.current_tab < SingletonObject.ChatList.size():
		var current_chat = SingletonObject.ChatList[chat_pane.current_tab]
		source_context = "Agent: %s" % current_chat.HistoryName

	var AutocoderTaskClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTask.gd")
	var task = board.task_store.create_task(
		title,
		description,
		status,
		"",  # model
		priority,
		AutocoderTaskClass.SourceType.AGENT_TOOL,
		"",  # source_uuid - could track chat ID here
		source_context
	)

	return {
		"success": true,
		"task_id": task.id,
		"title": task.title,
		"status": task.get_status_name(),
		"message": "Task created on board '%s'" % board_name
	}


func _kanban_list_boards(_args: Dictionary) -> Dictionary:
	var boards = _get_all_kanban_boards()

	return {
		"success": true,
		"boards": boards,
		"count": boards.size()
	}


func _kanban_get_tasks(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var status_filter: String = str(args.get("status", "")).strip_edges()

	if board_name.is_empty():
		return {"error": "board_name is required", "success": false}

	var board = _find_kanban_board_by_name(board_name)
	if not board:
		return {"error": "Kanban board not found: %s" % board_name, "success": false}

	if not board.task_store:
		return {"error": "Kanban board has no task store", "success": false}

	var tasks: Array  # Array of AutocoderTask
	if status_filter.is_empty():
		tasks = board.task_store.get_all_tasks()
	else:
		var status = _status_string_to_enum(status_filter)
		tasks = board.task_store.get_tasks_by_status(status)

	var tasks_data: Array[Dictionary] = []
	for task in tasks:
		tasks_data.append({
			"task_id": task.id,
			"title": task.title,
			"description": task.description,
			"status": task.get_status_name(),
			"priority": task.priority,
			"source": task.get_source_type_name(),
			"created_at": task.created_at
		})

	return {
		"success": true,
		"board_name": board_name,
		"tasks": tasks_data,
		"count": tasks_data.size()
	}


func _kanban_update_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()

	if board_name.is_empty():
		return {"error": "board_name is required", "success": false}
	if task_id.is_empty():
		return {"error": "task_id is required", "success": false}

	var board = _find_kanban_board_by_name(board_name)
	if not board:
		return {"error": "Kanban board not found: %s" % board_name, "success": false}

	if not board.task_store:
		return {"error": "Kanban board has no task store", "success": false}

	var updates: Dictionary = {}
	if args.has("title"):
		updates["title"] = args["title"]
	if args.has("description"):
		updates["description"] = args["description"]
	if args.has("priority"):
		updates["priority"] = args["priority"]

	if updates.is_empty():
		return {"error": "No updates provided", "success": false}

	var success = board.task_store.update_task(task_id, updates)
	if not success:
		return {"error": "Task not found: %s" % task_id, "success": false}

	return {
		"success": true,
		"task_id": task_id,
		"message": "Task updated"
	}


func _kanban_move_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()
	var new_status_str: String = str(args.get("new_status", "")).strip_edges()

	if board_name.is_empty():
		return {"error": "board_name is required", "success": false}
	if task_id.is_empty():
		return {"error": "task_id is required", "success": false}
	if new_status_str.is_empty():
		return {"error": "new_status is required", "success": false}

	var board = _find_kanban_board_by_name(board_name)
	if not board:
		return {"error": "Kanban board not found: %s" % board_name, "success": false}

	if not board.task_store:
		return {"error": "Kanban board has no task store", "success": false}

	var new_status = _status_string_to_enum(new_status_str)
	var success = board.task_store.move_task(task_id, new_status)
	if not success:
		return {"error": "Task not found: %s" % task_id, "success": false}

	return {
		"success": true,
		"task_id": task_id,
		"new_status": new_status_str,
		"message": "Task moved to %s" % new_status_str
	}


func _kanban_delete_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()

	if board_name.is_empty():
		return {"error": "board_name is required", "success": false}
	if task_id.is_empty():
		return {"error": "task_id is required", "success": false}

	var board = _find_kanban_board_by_name(board_name)
	if not board:
		return {"error": "Kanban board not found: %s" % board_name, "success": false}

	if not board.task_store:
		return {"error": "Kanban board has no task store", "success": false}

	var success = board.task_store.delete_task(task_id)
	if not success:
		return {"error": "Task not found: %s" % task_id, "success": false}

	return {
		"success": true,
		"task_id": task_id,
		"message": "Task deleted"
	}

#endregion


#region Spreadsheet Tool Implementations

func _find_spreadsheet_editor(editor_name: String) -> Variant:
	var editor = _find_editor_by_name(editor_name)
	if not editor:
		return null

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.SPREADSHEET:
		return null

	return editor


func _create_spreadsheet_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Spreadsheet")
	var csv_content: String = args.get("csv_content", "")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return {"error": "File not found: %s" % file_path, "success": false}

	# Create the spreadsheet editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.SPREADSHEET, file_arg, name_, null)

	# Wait for the spreadsheet editor to be ready
	if not editor.spreadsheet_editor:
		await Engine.get_main_loop().process_frame

	# Set CSV content if provided (and no file was loaded)
	if not csv_content.is_empty() and file_path.is_empty() and editor.spreadsheet_editor:
		editor.spreadsheet_editor.set_content(csv_content)

	return {
		"success": true,
		"editor_name": editor.tab_title,
		"message": "Spreadsheet editor created. Use this editor_name for subsequent operations."
	}


func _get_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var format_: String = args.get("format", "csv")
	#var range_str: String = args.get("range", "")
	var include_empty_rows: bool = args.get("include_empty_rows", false)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Get the used range to determine where data starts
	var used_range: Rect2i = data.get_used_range()
	var data_starts_at_row: int = used_range.position.y + 1  # Convert to 1-based

	var content: Variant
	match format_:
		"csv":
			if include_empty_rows:
				content = _to_csv_with_empty_rows(data)
			else:
				content = data.to_csv(",")
		"json":
			content = data.to_json_array()
		"markdown":
			content = data.to_markdown()
		_:
			if include_empty_rows:
				content = _to_csv_with_empty_rows(data)
			else:
				content = data.to_csv(",")

	return {
		"success": true,
		"format": format_,
		"data": content,
		"row_count": data.row_count,
		"column_count": data.column_count,
		"data_starts_at_row": data_starts_at_row,
		"has_leading_empty_rows": data_starts_at_row > 1
	}


## Helper to generate CSV including empty rows from row 0
func _to_csv_with_empty_rows(data) -> String:
	var used_range: Rect2i = data.get_used_range()
	if used_range.size == Vector2i.ZERO:
		return ""

	var lines := PackedStringArray()
	var delimiter := ","

	# Start from row 0, not from used_range.position.y
	for row in range(0, used_range.end.y):
		var values := PackedStringArray()
		for col in range(used_range.position.x, used_range.end.x):
			var cell = data.get_cell_if_exists(row, col)
			var val := ""
			if cell and not cell.is_empty():
				val = str(cell.value)
				# Escape delimiter and quotes
				if delimiter in val or '"' in val or '\n' in val:
					val = '"' + val.replace('"', '""') + '"'
			values.append(val)
		lines.append(delimiter.join(values))

	return "\n".join(lines)


func _update_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var csv_content: String = args.get("csv_content", "")
	var cells: Array = args.get("cells", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0

	# If CSV content provided, replace all data
	if not csv_content.is_empty():
		editor.spreadsheet_editor.set_content(csv_content)
		updated_count = -1  # Indicate full replacement

	# Update individual cells (with history recording)
	if cells.size() > 0:
		for cell_update in cells:
			if cell_update is Dictionary:
				var cell_ref: String = cell_update.get("cell", "")
				var value: Variant = cell_update.get("value", "")

				if not cell_ref.is_empty():
					var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
					if pos.x >= 0 and pos.y >= 0:
						# Use history-recording method
						editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, value)
						updated_count += 1

	return {
		"success": true,
		"message": "Spreadsheet updated" if updated_count == -1 else "Updated %d cells" % updated_count
	}


func _add_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Determine row index
	var row_idx: int = at_row if at_row >= 0 else data.row_count

	# Insert the row
	data.insert_row(row_idx)

	# Set values if provided (with history recording)
	for col in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(row_idx, col, values[col])

	# Trigger redraw for row headers
	editor.spreadsheet_editor.row_headers.queue_redraw()

	return {
		"success": true,
		"row_index": row_idx,
		"message": "Row added at index %d" % row_idx
	}


func _add_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_col: int = args.get("at_col", -1)
	var header: String = args.get("header", "")
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Determine column index
	var col_idx: int = at_col if at_col >= 0 else data.column_count

	# Insert the column
	data.insert_column(col_idx)

	# Set header if provided (row 0) with history recording
	var start_row := 0
	if not header.is_empty():
		editor.spreadsheet_editor.set_cell_value_with_history(0, col_idx, header)
		start_row = 1

	# Set values with history recording
	for i in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(start_row + i, col_idx, values[i])

	# Trigger redraw for column headers
	editor.spreadsheet_editor.column_headers.queue_redraw()

	return {
		"success": true,
		"column_index": col_idx,
		"column_label": SpreadsheetDataScript.get_column_label(col_idx),
		"message": "Column added at index %d" % col_idx
	}


func _delete_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var row: int = args.get("row", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if row < 1:
		return {"error": "row number is required and must be >= 1 (1-based indexing)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Convert from 1-based to 0-based indexing
	var internal_row: int = row - 1

	if internal_row >= data.row_count:
		return {"error": "Row %d out of bounds (max row: %d)" % [row, data.row_count], "success": false}

	# Delete the row with history support
	var success = editor.spreadsheet_editor.delete_row_with_history(internal_row)
	if not success:
		return {"error": "Failed to delete row %d" % row, "success": false}

	return {
		"success": true,
		"deleted_row": row,
		"message": "Row %d deleted (can be undone with Ctrl+Z)" % row
	}


func _delete_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var column: int = args.get("column", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if column < 1:
		return {"error": "column number is required and must be >= 1 (1-based indexing)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Convert from 1-based to 0-based indexing
	var internal_col: int = column - 1

	if internal_col >= data.column_count:
		return {"error": "Column %d out of bounds (max column: %d)" % [column, data.column_count], "success": false}

	var col_label = SpreadsheetDataScript.get_column_label(internal_col)

	# Delete the column with history support
	var success = editor.spreadsheet_editor.delete_column_with_history(internal_col)
	if not success:
		return {"error": "Failed to delete column %d (%s)" % [column, col_label], "success": false}

	return {
		"success": true,
		"deleted_column": column,
		"deleted_column_label": col_label,
		"message": "Column %s deleted (can be undone with Ctrl+Z)" % col_label
	}


func _insert_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if at_row < 0:
		return {"error": "at_row is required and must be >= 0", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Insert empty row
	data.insert_row(at_row)

	# Trigger redraw
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_row": at_row,
		"message": "Empty row inserted at index %d" % at_row
	}


func _insert_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_column: int = args.get("at_column", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if at_column < 0:
		return {"error": "at_column is required and must be >= 0", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Insert empty column
	data.insert_column(at_column)

	var col_label = SpreadsheetDataScript.get_column_label(at_column)

	# Trigger redraw
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_column": at_column,
		"inserted_column_label": col_label,
		"message": "Empty column inserted at %s (index %d)" % [col_label, at_column]
	}


func _format_cells(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var range_str: String = args.get("range", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if range_str.is_empty():
		return {"error": "range is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Parse the range
	var cells_to_format: Array[Vector2i] = []

	if range_str.contains(":"):
		# Range like A1:C10
		var parts: PackedStringArray = range_str.split(":")
		var start_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[0].strip_edges())
		var end_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[1].strip_edges())

		if start_pos.x >= 0 and start_pos.y >= 0 and end_pos.x >= 0 and end_pos.y >= 0:
			for row in range(mini(start_pos.y, end_pos.y), maxi(start_pos.y, end_pos.y) + 1):
				for col in range(mini(start_pos.x, end_pos.x), maxi(start_pos.x, end_pos.x) + 1):
					cells_to_format.append(Vector2i(col, row))
	else:
		# Single cell like A1
		var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(range_str)
		if pos.x >= 0 and pos.y >= 0:
			cells_to_format.append(Vector2i(pos.x, pos.y))

	if cells_to_format.is_empty():
		return {"error": "Invalid range: %s" % range_str, "success": false}

	# Build format options dictionary
	var format_options: Dictionary = {}

	if args.has("bold"):
		format_options["bold"] = args.get("bold", false)
	if args.has("italic"):
		format_options["italic"] = args.get("italic", false)
	if args.has("alignment"):
		var align_str: String = args.get("alignment", "left")
		match align_str:
			"left":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_LEFT
			"center":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_CENTER
			"right":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_RIGHT
	if args.has("text_color"):
		format_options["text_color"] = Color.html(args.get("text_color", "#FFFFFF"))
	if args.has("bg_color"):
		format_options["bg_color"] = Color.html(args.get("bg_color", "#000000"))
	if args.has("number_format"):
		format_options["number_format"] = args.get("number_format", "none")
	if args.has("wrap_text"):
		format_options["wrap_text"] = args.get("wrap_text", false)

	# Apply formatting with history recording
	var formatted_count := 0
	for cell_pos in cells_to_format:
		editor.spreadsheet_editor.format_cell_with_history(cell_pos.y, cell_pos.x, format_options)
		formatted_count += 1

	return {
		"success": true,
		"cells_formatted": formatted_count,
		"message": "Formatted %d cells" % formatted_count
	}


func _set_row_height(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var rows: Array = args.get("rows", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if rows.is_empty():
		return {"error": "rows array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0
	for row_config in rows:
		if not row_config is Dictionary:
			continue
		var row_1based: int = row_config.get("row", -1)
		var height: float = row_config.get("height", -1.0)
		if row_1based < 1 or height < 0:
			continue

		var row := row_1based - 1  # Convert to 0-based
		if row < 0 or row >= data.row_count:
			continue

		height = clampf(height, SpreadsheetDataScript.MIN_ROW_HEIGHT, SpreadsheetDataScript.MAX_ROW_HEIGHT)
		var old_height: float = data.get_row_height(row)
		data.set_row_height(row, height)
		if height != old_height:
			editor.spreadsheet_editor.history.record_row_resize(row, old_height, height)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"rows_updated": updated_count,
		"message": "Updated height for %d rows" % updated_count
	}


func _set_column_width(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if columns.is_empty():
		return {"error": "columns array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0
	for col_config in columns:
		if not col_config is Dictionary:
			continue
		var col_str: String = str(col_config.get("column", ""))
		var width: float = col_config.get("width", -1.0)
		if col_str.is_empty() or width < 0:
			continue

		# Parse column: letter (A, B, ...) or 1-based number
		var col: int = -1
		if col_str.is_valid_int():
			col = int(col_str) - 1  # Convert 1-based to 0-based
		else:
			col = SpreadsheetDataScript.parse_column_label(col_str.to_upper())

		if col < 0 or col >= data.column_count:
			continue

		width = clampf(width, SpreadsheetDataScript.MIN_COLUMN_WIDTH, SpreadsheetDataScript.MAX_COLUMN_WIDTH)
		var old_width: float = data.get_column_width(col)
		data.set_column_width(col, width)
		if width != old_width:
			editor.spreadsheet_editor.history.record_column_resize(col, old_width, width)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"columns_updated": updated_count,
		"message": "Updated width for %d columns" % updated_count
	}


func _set_cell_formula(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var cell_ref: String = args.get("cell", "")
	var formula: String = args.get("formula", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if cell_ref.is_empty():
		return {"error": "cell is required", "success": false}

	if formula.is_empty():
		return {"error": "formula is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Parse cell reference
	var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
	if pos.x < 0 or pos.y < 0:
		return {"error": "Invalid cell reference: %s" % cell_ref, "success": false}

	# Ensure formula starts with =
	if not formula.begins_with("="):
		formula = "=" + formula

	# Set the formula with history recording
	editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, formula)

	# Get the computed result
	var cell = data.get_cell(pos.y, pos.x)
	var result: String = cell.get_display_text()

	return {
		"success": true,
		"cell": cell_ref,
		"formula": formula,
		"result": result
	}


func _create_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var title: String = args.get("title", "Chart")
	var chart_type: String = args.get("type", "line")
	var x_range: String = args.get("x_range", "")
	var series: Array = args.get("series", [])
	var x_is_date: bool = args.get("x_is_date", false)
	var first_row_is_header: bool = args.get("first_row_is_header", true)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if x_range.is_empty():
		return {"error": "x_range is required", "success": false}

	if series.is_empty():
		return {"error": "series is required (array of cell ranges)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Create the chart
	var chart := SpreadsheetChartScript.new()
	chart.title = title
	chart.type = SpreadsheetChartScript.ChartType.LINE if chart_type == "line" else SpreadsheetChartScript.ChartType.BAR
	chart.x_range = x_range
	chart.x_is_date = x_is_date
	chart.first_row_is_header = first_row_is_header

	# Add series
	for series_range in series:
		if series_range is String:
			chart.add_series(series_range)

	# Add the chart
	editor.spreadsheet_editor.add_chart(chart)

	return {
		"success": true,
		"chart_id": chart.id,
		"chart_count": editor.spreadsheet_editor.charts.size(),
		"message": "Chart created successfully"
	}


func _get_chart_image(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_index: int = args.get("chart_index", 0)
	var width: int = args.get("width", 800)
	var height: int = args.get("height", 400)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var charts = editor.spreadsheet_editor.charts
	if chart_index < 0 or chart_index >= charts.size():
		return {"error": "Chart index out of range (have %d charts)" % charts.size(), "success": false}

	var chart_canvas = editor.spreadsheet_editor._chart_canvas
	if not chart_canvas:
		return {"error": "Chart canvas not available", "success": false}

	# Make sure the chart canvas has the right chart selected
	var target_chart = charts[chart_index]
	chart_canvas.set_chart(target_chart)
	chart_canvas.update_from_spreadsheet(editor.spreadsheet_editor.spreadsheet_data)

	# Capture the chart as base64 PNG
	var base64_png: String = await chart_canvas.capture_to_base64_png(width, height)

	if base64_png.is_empty():
		return {"error": "Failed to capture chart image", "success": false}

	return {
		"success": true,
		"chart_index": chart_index,
		"chart_title": target_chart.title,
		"width": width,
		"height": height,
		"format": "png",
		"encoding": "base64",
		"image_data": base64_png
	}


func _list_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var charts_info: Array = []
	for i in range(editor.spreadsheet_editor.charts.size()):
		var chart = editor.spreadsheet_editor.charts[i]
		var series_info: Array = []
		for s in chart.series:
			series_info.append({
				"range": s.get("range", ""),
				"name": s.get("name", "")
			})

		charts_info.append({
			"index": i,
			"id": chart.id,
			"title": chart.title,
			"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
			"x_range": chart.x_range,
			"x_is_date": chart.x_is_date,
			"first_row_is_header": chart.first_row_is_header,
			"series": series_info
		})

	return {
		"success": true,
		"chart_count": charts_info.size(),
		"charts": charts_info
	}


func _update_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = args.get("chart_index", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return {"error": "Chart not found. Provide valid chart_id or chart_index.", "success": false}

	# Build properties dictionary from args
	var properties: Dictionary = {}
	if args.has("title"):
		properties["title"] = args["title"]
	if args.has("type"):
		properties["type"] = args["type"]
	if args.has("x_range"):
		properties["x_range"] = args["x_range"]
	if args.has("series"):
		properties["series"] = args["series"]
	if args.has("x_is_date"):
		properties["x_is_date"] = args["x_is_date"]
	if args.has("first_row_is_header"):
		properties["first_row_is_header"] = args["first_row_is_header"]
	if args.has("x_axis_label"):
		properties["x_axis_label"] = args["x_axis_label"]
	if args.has("y_axis_label"):
		properties["y_axis_label"] = args["y_axis_label"]
	if args.has("show_legend"):
		properties["show_legend"] = args["show_legend"]
	if args.has("y_auto_scale"):
		properties["y_auto_scale"] = args["y_auto_scale"]
	if args.has("y_min"):
		properties["y_min"] = args["y_min"]
	if args.has("y_max"):
		properties["y_max"] = args["y_max"]

	if properties.is_empty():
		return {"error": "No properties to update. Provide at least one property.", "success": false}

	# Update the chart
	var success: bool = editor.spreadsheet_editor.update_chart_properties(target_index, properties)

	if not success:
		return {"error": "Failed to update chart", "success": false}

	var chart = editor.spreadsheet_editor.charts[target_index]
	return {
		"success": true,
		"chart_id": chart.id,
		"chart_index": target_index,
		"updated_properties": properties.keys(),
		"message": "Chart updated successfully"
	}


func _delete_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = args.get("chart_index", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return {"error": "Chart not found. Provide valid chart_id or chart_index.", "success": false}

	var deleted_id: String = editor.spreadsheet_editor.charts[target_index].id
	editor.spreadsheet_editor.remove_chart(target_index)

	return {
		"success": true,
		"deleted_chart_id": deleted_id,
		"remaining_charts": editor.spreadsheet_editor.charts.size(),
		"message": "Chart deleted successfully"
	}


func _refresh_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	editor.spreadsheet_editor._update_all_charts()

	return {
		"success": true,
		"charts_refreshed": editor.spreadsheet_editor.charts.size(),
		"message": "All charts refreshed"
	}


func _link_spreadsheet_to_note(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var note_title: String = args.get("note_title", "")
	var thread_name: String = args.get("thread_name", "Spreadsheets")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Use spreadsheet name as note title if not provided
	if note_title.is_empty():
		note_title = editor_name

	# Get markdown content from spreadsheet
	var data = editor.spreadsheet_editor.spreadsheet_data
	var markdown_content: String = data.to_markdown()

	# Create the linked note
	var note = NoteScript.create_spreadsheet_note(note_title, editor_name, markdown_content)

	# Find or create the notes thread
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var thread_vbox = notes_container.find_or_create_tab(thread_name)
	thread_vbox.add_note(note)

	return {
		"success": true,
		"note_uuid": note.uuid,
		"note_title": note_title,
		"thread_name": thread_name,
		"linked_spreadsheet": editor_name,
		"message": "Created linked note '%s' in thread '%s'. Edit button opens spreadsheet." % [note_title, thread_name]
	}


func _export_to_nudge(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component: String = args.get("component", "")
	var key: String = args.get("key", "")
	var format_: String = args.get("format", "summary")
	var include_charts: bool = args.get("include_charts", false)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if component.is_empty():
		return {"error": "component is required", "success": false}

	if key.is_empty():
		return {"error": "key is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data

	# Build the export value based on format
	var export_value: Variant

	match format_:
		"raw":
			export_value = _export_raw(data)
		"summary":
			export_value = _export_summary(data, editor.spreadsheet_editor)
		"schema":
			export_value = _export_schema(data)
		"timeseries":
			export_value = _export_timeseries(data)
		"kv_pairs":
			export_value = _export_kv_pairs(data)
		_:
			export_value = _export_summary(data, editor.spreadsheet_editor)

	# Add chart info if requested
	if include_charts and editor.spreadsheet_editor.charts.size() > 0:
		var charts_info: Array = []
		for chart in editor.spreadsheet_editor.charts:
			charts_info.append({
				"id": chart.id,
				"title": chart.title,
				"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
				"x_range": chart.x_range,
				"series_count": chart.series.size()
			})
		if export_value is Dictionary:
			export_value["charts"] = charts_info

	# Call Nudge MCP to set the hint
	var nudge_result: Dictionary = await _call_nudge_set_hint(component, key, export_value)

	if nudge_result.has("error"):
		return {"error": "Nudge export failed: %s" % nudge_result.get("error", "Unknown error"), "success": false}

	return {
		"success": true,
		"component": component,
		"key": key,
		"format": format_,
		"message": "Exported spreadsheet data to Nudge as %s/%s" % [component, key]
	}


## Export spreadsheet as raw JSON data
func _export_raw(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var cells_data: Array = []

	for row in range(bounds.position.y, bounds.position.y + bounds.size.y):
		var row_data: Array = []
		for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
			row_data.append(data.get_cell_display(row, col))
		cells_data.append(row_data)

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"data": cells_data
	}


## Export spreadsheet summary (counts, headers, totals)
func _export_summary(data: SpreadsheetDataScript, spreadsheet_editor) -> Dictionary:
	var bounds := data.get_used_range()

	# Get headers (first row)
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Calculate numeric totals per column
	var totals: Dictionary = {}
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var total: float = 0.0
		var has_numbers := false
		for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
			var cell = data.get_cell_if_exists(row, col)
			if cell and cell.type == SpreadsheetCellScript.CellType.NUMBER:
				total += float(cell.value)
				has_numbers = true
		if has_numbers:
			var header: String = headers[col - bounds.position.x] if col - bounds.position.x < headers.size() else "Column %d" % col
			totals[header] = total

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"headers": headers,
		"totals": totals,
		"chart_count": spreadsheet_editor.charts.size() if spreadsheet_editor else 0
	}


## Export spreadsheet schema (column names and types)
func _export_schema(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var columns: Array = []

	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var header: String = data.get_cell_display(bounds.position.y, col)

		# Detect column type from first few data cells
		var detected_type := "text"
		var sample_values: Array = []
		for row in range(bounds.position.y + 1, mini(bounds.position.y + 4, bounds.position.y + bounds.size.y)):
			var cell = data.get_cell_if_exists(row, col)
			if cell:
				sample_values.append(data.get_cell_display(row, col))
				if cell.type == SpreadsheetCellScript.CellType.NUMBER:
					detected_type = "number"
				elif cell.type == SpreadsheetCellScript.CellType.DATE:
					detected_type = "date"
				elif cell.type == SpreadsheetCellScript.CellType.FORMULA:
					detected_type = "formula"

		columns.append({
			"name": header,
			"type": detected_type,
			"samples": sample_values
		})

	return {
		"column_count": bounds.size.x,
		"row_count": bounds.size.y - 1,  # Exclude header
		"columns": columns
	}


## Export as time series (first column as date keys)
func _export_timeseries(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var series: Dictionary = {}

	# Get column headers
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Build time series with date as key
	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var date_key: String = data.get_cell_display(row, bounds.position.x)
		var values: Dictionary = {}

		for col in range(bounds.position.x + 1, bounds.position.x + bounds.size.x):
			var header: String = headers[col - bounds.position.x]
			values[header] = data.get_cell_display(row, col)

		series[date_key] = values

	return {
		"date_column": headers[0] if headers.size() > 0 else "Date",
		"value_columns": headers.slice(1) if headers.size() > 1 else [],
		"series": series
	}


## Export as key-value pairs from first two columns
func _export_kv_pairs(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var pairs: Dictionary = {}

	if bounds.size.x < 2:
		return {"error": "Need at least 2 columns for key-value pairs"}

	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var key_val: String = data.get_cell_display(row, bounds.position.x)
		var value_val: String = data.get_cell_display(row, bounds.position.x + 1)
		if not key_val.is_empty():
			pairs[key_val] = value_val

	return pairs


## Call Nudge MCP server to set a hint
func _call_nudge_set_hint(component: String, key: String, value: Variant) -> Dictionary:
	# Try to find the Nudge MCP server connection
	if not mcp_manager:
		return {"error": "MCP manager not available"}

	# Check if Nudge server is connected
	if not mcp_manager.is_server_connected("nudge"):
		return {"error": "Nudge MCP server not connected"}

	# Call the nudge_set_hint tool
	var result: Dictionary = await mcp_manager.execute_tool("nudge_set_hint", {
		"component": component,
		"key": key,
		"value": value
	})

	return result


## Undo the last action(s) in a spreadsheet
func _undo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = args.get("count", 1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_undo():
		return {
			"success": false,
			"message": "Nothing to undo",
			"undo_count": 0,
			"redo_count": spreadsheet.get_redo_count()
		}

	var undone := 0
	for i in range(count):
		if spreadsheet.undo():
			undone += 1
		else:
			break

	return {
		"success": true,
		"undone_count": undone,
		"remaining_undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count(),
		"message": "Undid %d action(s)" % undone
	}


## Redo a previously undone action in a spreadsheet
func _redo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = args.get("count", 1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_redo():
		return {
			"success": false,
			"message": "Nothing to redo",
			"undo_count": spreadsheet.get_undo_count(),
			"redo_count": 0
		}

	var redone := 0
	for i in range(count):
		if spreadsheet.redo():
			redone += 1
		else:
			break

	return {
		"success": true,
		"redone_count": redone,
		"undo_count": spreadsheet.get_undo_count(),
		"remaining_redo_count": spreadsheet.get_redo_count(),
		"message": "Redid %d action(s)" % redone
	}


## Get the undo/redo history status of a spreadsheet
func _get_spreadsheet_history(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	return {
		"success": true,
		"can_undo": spreadsheet.can_undo(),
		"can_redo": spreadsheet.can_redo(),
		"undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count()
	}


## Fill down formulas/values from source row to target rows
func _fill_down_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var source_row: int = args.get("source_row", 0)
	var target_rows: Array = args.get("target_rows", [])
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if source_row < 1:
		return {"error": "source_row must be >= 1 (1-based row number)", "success": false}

	if target_rows.is_empty():
		return {"error": "target_rows array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor
	var data = spreadsheet.spreadsheet_data

	# Convert 1-based to 0-based
	var source_row_idx: int = source_row - 1

	# Determine columns to fill
	var col_indices: Array[int] = []
	if columns.is_empty():
		# Fill all columns that have data in source row
		for col in range(data.column_count):
			var cell = data.get_cell_if_exists(source_row_idx, col)
			if cell and not cell.is_empty():
				col_indices.append(col)
	else:
		# Parse column letters to indices
		for col_letter in columns:
			var col_idx: int = SpreadsheetDataScript.parse_column_label(str(col_letter).to_upper())
			if col_idx >= 0:
				col_indices.append(col_idx)

	if col_indices.is_empty():
		return {"error": "No columns to fill (source row is empty or columns not found)", "success": false}

	# Capture old cells for history
	var old_cells: Dictionary = {}
	var new_cells: Dictionary = {}
	var filled_count: int = 0

	# Fill each target row
	for target_row in target_rows:
		var target_row_idx: int = int(target_row) - 1  # Convert to 0-based
		if target_row_idx < 0 or target_row_idx == source_row_idx:
			continue

		var row_offset: int = target_row_idx - source_row_idx

		for col in col_indices:
			var source_cell = data.get_cell_if_exists(source_row_idx, col)
			if not source_cell:
				continue

			var key := SpreadsheetDataScript.cell_key(target_row_idx, col)

			# Capture old value
			var old_cell = data.get_cell_if_exists(target_row_idx, col)
			if old_cell:
				old_cells[key] = old_cell.to_dict()
			else:
				old_cells[key] = {}

			# Determine what to set
			if source_cell.has_formula():
				# Adjust the formula's row references
				var adjusted_formula: String = spreadsheet._adjust_formula_row_refs(source_cell.formula, row_offset)
				data.set_cell_value(target_row_idx, col, adjusted_formula)
			else:
				# Just copy the value (no adjustment needed)
				data.set_cell_value(target_row_idx, col, source_cell.value)

			# Capture new value
			var new_cell = data.get_cell_if_exists(target_row_idx, col)
			if new_cell:
				new_cells[key] = new_cell.to_dict()
			filled_count += 1

	# Record in history
	if not new_cells.is_empty():
		spreadsheet.history.record_range_edit(source_row_idx + 1, col_indices[0], old_cells, new_cells)

	spreadsheet.cells_canvas.queue_redraw()
	spreadsheet.content_changed.emit()

	# Build column letters for response
	var col_letters: Array[String] = []
	for col in col_indices:
		col_letters.append(SpreadsheetDataScript.get_column_label(col))

	return {
		"success": true,
		"filled_cells": filled_count,
		"source_row": source_row,
		"target_rows": target_rows,
		"columns": col_letters,
		"message": "Filled %d cells from row %d to rows %s in columns %s" % [filled_count, source_row, str(target_rows), ", ".join(col_letters)]
	}


## Recalculate all formulas in a spreadsheet
func _recalculate_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor
	spreadsheet._recalculate_all()

	return {
		"success": true,
		"message": "Recalculated all formulas in %s" % editor_name
	}

#endregion


#region PCB Editor Tool Registration

const PCBEditorScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBEditor.gd")
const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBTraceScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBTrace.gd")
const PCBAnnotationScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd")
const PCBRouteHintScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBRouteHint.gd")

func _register_pcb_tools() -> void:
	_register_tool("minerva_create_pcb_editor",
		"Create a new PCB Editor tab for designing printed circuit board layouts.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the PCB editor tab"
				},
				"board_width": {
					"type": "number",
					"description": "Board width in mm. Default: 100"
				},
				"board_height": {
					"type": "number",
					"description": "Board height in mm. Default: 100"
				}
			},
			"required": ["name"]
		}
	)

	_register_tool("minerva_pcb_get_components",
		"Get all components from a PCB editor with their positions and connections.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_set_board_size",
		"Set the PCB board dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"width": {
					"type": "number",
					"description": "Board width in mm"
				},
				"height": {
					"type": "number",
					"description": "Board height in mm"
				}
			},
			"required": ["editor_name", "width", "height"]
		}
	)

	_register_tool("minerva_pcb_describe_component",
		"Get detailed spatial context for a component including nearby components, connections, and region.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID (e.g., 'SW1', 'U3')"
				}
			},
			"required": ["editor_name", "component_id"]
		}
	)

	_register_tool("minerva_pcb_spatial_query",
		"Query components based on spatial relationships (e.g., 'what components are near U3?').",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"query": {
					"type": "string",
					"description": "Natural language spatial query"
				},
				"reference_component": {
					"type": "string",
					"description": "Component ID to query relative to"
				},
				"radius_mm": {
					"type": "number",
					"description": "Search radius in mm. Default: 20"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_get_nets",
		"Get all electrical nets (connections) from a PCB.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_get_pin_position",
		"Get the world position and info for a specific pin on a component. Useful for calculating waypoints or verifying pin locations before creating route hints.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID (e.g., 'U3', 'R1')"
				},
				"pin": {
					"type": "string",
					"description": "Pin name or number (e.g., '1', 'VCC', 'SDA')"
				}
			},
			"required": ["editor_name", "component_id", "pin"]
		}
	)

	_register_tool("minerva_pcb_add_component",
		"Add a new component to the PCB. NOTE: Component dimensions are estimated defaults based on footprint type. For accurate sizing from KiCAD libraries, run pcb-architect's footprint-geometry command and then call minerva_pcb_import_footprint_geometry to update components with real dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"id": {
					"type": "string",
					"description": "Component ID (e.g., 'R15', 'U3'). Auto-generated if not specified."
				},
				"footprint": {
					"type": "string",
					"description": "Footprint type: RESISTOR, CAPACITOR, IC_DIP, IC_QFP, SWITCH, CONNECTOR, LED, DIODE, TRANSISTOR, HEADER, MOUNTING_HOLE, MODULE",
					"enum": ["RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR", "LED", "DIODE", "TRANSISTOR", "HEADER", "MOUNTING_HOLE", "MODULE"]
				},
				"x": {
					"type": "number",
					"description": "X position in mm"
				},
				"y": {
					"type": "number",
					"description": "Y position in mm"
				},
				"rotation": {
					"type": "number",
					"description": "Rotation in degrees (0, 90, 180, 270). Default: 0"
				},
				"value": {
					"type": "string",
					"description": "Component value (e.g., '10K', '100nF')"
				},
				"pin_count": {
					"type": "integer",
					"description": "Number of pins for HEADER/CONNECTOR (single row) or IC_DIP/MODULE (dual row, must be even)"
				},
				"width": {
					"type": "number",
					"description": "Custom width in mm (overrides default)"
				},
				"height": {
					"type": "number",
					"description": "Custom height in mm (overrides default)"
				},
				"pin_names": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Custom pin names (e.g., ['GND', 'VCC', 'SDA', 'SCL'] for a 4-pin header)"
				},
				"snap_to_grid": {
					"type": "boolean",
					"description": "Whether to snap position to grid (default: true). Set to false for exact positioning."
				}
			},
			"required": ["editor_name", "footprint", "x", "y"]
		}
	)

	_register_tool("minerva_pcb_move_component",
		"Move a component to an absolute position.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to move"
				},
				"x": {
					"type": "number",
					"description": "New X position in mm"
				},
				"y": {
					"type": "number",
					"description": "New Y position in mm"
				}
			},
			"required": ["editor_name", "component_id", "x", "y"]
		}
	)

	_register_tool("minerva_pcb_move_relative",
		"Move a component using natural language direction (e.g., 'down a bit', 'closer to U3').",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to move"
				},
				"direction": {
					"type": "string",
					"description": "Natural language direction: 'up', 'down', 'left', 'right', 'closer to X', 'away from X', 'toward center', etc."
				}
			},
			"required": ["editor_name", "component_id", "direction"]
		}
	)

	_register_tool("minerva_pcb_rotate_component",
		"Rotate a component. Positive degrees rotate counter-clockwise (CCW), negative rotate clockwise (CW).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to rotate"
				},
				"degrees": {
					"type": "number",
					"description": "Rotation angle. Positive = counter-clockwise (CCW), negative = clockwise (CW). Common values: 90 (CCW), -90 (CW), 180."
				}
			},
			"required": ["editor_name", "component_id", "degrees"]
		}
	)

	_register_tool("minerva_pcb_delete_component",
		"Delete a component from the PCB.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to delete"
				}
			},
			"required": ["editor_name", "component_id"]
		}
	)

	_register_tool("minerva_pcb_connect_net",
		"Connect component pins to a net (creates net if it doesn't exist).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"net_name": {
					"type": "string",
					"description": "Net name (e.g., 'VCC', 'GND', 'SDA')"
				},
				"pins": {
					"type": "array",
					"description": "Array of pin connections: [{\"component\": \"U1\", \"pin\": \"8\"}, ...]",
					"items": {
						"type": "object",
						"properties": {
							"component": {"type": "string"},
							"pin": {"type": "string"}
						}
					}
				}
			},
			"required": ["editor_name", "net_name", "pins"]
		}
	)

	_register_tool("minerva_pcb_export_csv",
		"Export PCB component placement as CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_export_yaml",
		"Export PCB as YAML (compatible with pcb-architect).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_import_csv",
		"Import component placement from CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"csv_content": {
					"type": "string",
					"description": "CSV content with columns: id,footprint,x,y,rotation,layer,value"
				}
			},
			"required": ["editor_name", "csv_content"]
		}
	)

	_register_tool("minerva_pcb_import_footprint_geometry",
		"IMPORTANT: Call this after adding components to get accurate dimensions from KiCAD footprint libraries. Without this, components use estimated sizes that may not match actual footprints. Run 'pcb-architect footprint-geometry board.yaml -o geometry.json' to generate the input data. Updates component pads with accurate shapes, sizes, drill holes, and body dimensions. Can also correct positions if YAML used different coordinate conventions (use position_is_center and/or invert_y flags).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"geometry": {
					"type": "object",
					"description": "Footprint geometry JSON from pcb-architect footprint-geometry command. Contains board_name and components with pad arrays.",
					"properties": {
						"board_name": {"type": "string"},
						"components": {
							"type": "object",
							"additionalProperties": {
								"type": "object",
								"properties": {
									"footprint_id": {"type": "string"},
									"footprint_found": {"type": "boolean"},
									"bounding_box": {"type": "object"},
									"pads": {
										"type": "array",
										"items": {
											"type": "object",
											"properties": {
												"number": {"type": "string"},
												"type": {"type": "string", "enum": ["smd", "thru_hole", "np_thru_hole"]},
												"shape": {"type": "string", "enum": ["rect", "circle", "oval", "roundrect", "custom"]},
												"position": {"type": "object"},
												"size": {"type": "object"},
												"drill": {"type": "number"},
												"layers": {"type": "array", "items": {"type": "string"}}
											}
										}
									}
								}
							}
						}
					}
				},
				"position_is_center": {
					"type": "boolean",
					"description": "If true, current component positions are geometric centers (not footprint origins). Will adjust positions by subtracting bounding_box center offset. Default: false"
				},
				"invert_y": {
					"type": "boolean",
					"description": "If true, Y coordinates are inverted (Y=0 at bottom instead of top). Will flip Y relative to board height. Default: false"
				}
			},
			"required": ["editor_name", "geometry"]
		}
	)

	_register_tool("minerva_pcb_import_trace_geometry",
		"Import routed traces and vias from pcb-architect's trace-geometry command output. Clears existing traces and imports new ones. Trace segments are automatically connected into polylines.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"trace_data": {
					"type": "object",
					"description": "Trace geometry JSON from pcb-architect trace-geometry command",
					"properties": {
						"traces": {
							"type": "array",
							"description": "Array of trace segments",
							"items": {
								"type": "object",
								"properties": {
									"start": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"end": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"width": {"type": "number"},
									"layer": {"type": "string"},
									"net_name": {"type": "string"}
								}
							}
						},
						"vias": {
							"type": "array",
							"description": "Array of vias",
							"items": {
								"type": "object",
								"properties": {
									"position": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"size": {"type": "number"},
									"drill": {"type": "number"},
									"net_name": {"type": "string"},
									"layers": {"type": "array", "items": {"type": "string"}}
								}
							}
						}
					}
				}
			},
			"required": ["editor_name", "trace_data"]
		}
	)

	# Annotation tools
	_register_tool("minerva_pcb_add_annotation",
		"Add an annotation to the PCB (arrow, text, region, or polyline). Annotations are visual overlays for collaboration between human and AI.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"type": {
					"type": "string",
					"description": "Annotation type: 'arrow', 'text', 'region', or 'polyline'",
					"enum": ["arrow", "text", "region", "polyline"]
				},
				"positions": {
					"type": "array",
					"description": "Array of positions: arrow=[start,end], text=[position], region=[corner1,corner2], polyline=[point1,...,pointN]",
					"items": {
						"type": "object",
						"properties": {
							"x": {"type": "number"},
							"y": {"type": "number"}
						}
					}
				},
				"text": {
					"type": "string",
					"description": "Text content for text annotations, or label for other types"
				},
				"color": {
					"type": "string",
					"description": "Optional color as hex (e.g., '#FF0000'). Defaults to AI color (cyan)"
				},
				"associated_component": {
					"type": "string",
					"description": "Optional: component ID this annotation relates to"
				},
				"associated_net": {
					"type": "string",
					"description": "Optional: net name this annotation relates to"
				}
			},
			"required": ["editor_name", "type", "positions"]
		}
	)

	_register_tool("minerva_pcb_list_annotations",
		"List all annotations on a PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional filter by author: 'human', 'ai', or omit for all"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_remove_annotation",
		"Remove a specific annotation by ID.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"annotation_id": {
					"type": "string",
					"description": "ID of the annotation to remove"
				}
			},
			"required": ["editor_name", "annotation_id"]
		}
	)

	_register_tool("minerva_pcb_clear_annotations",
		"Clear annotations from the PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: clear only annotations by 'human' or 'ai'. Omit to clear all."
				}
			},
			"required": ["editor_name"]
		}
	)

	# Route hint tools
	_register_tool("minerva_pcb_add_route_hint",
		"Add a routing hint to suggest trace paths. Supports waypoint-only hints, single trace hints, and bus hints with varying levels of detail.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"hint_type": {
					"type": "string",
					"enum": ["waypoint", "single_trace", "bus"],
					"description": "Type of hint: 'waypoint' (just bend points), 'single_trace' (one net), 'bus' (parallel traces)"
				},
				"source_pins": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Source pin(s) in format 'Component.Pin' (e.g., ['U1.15'] or ['U1.15', 'U1.16', 'U1.17'])"
				},
				"dest_pins": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Destination pin(s) in format 'Component.Pin'"
				},
				"waypoints": {
					"type": "array",
					"items": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
					"description": "Waypoints/bend points for the route path"
				},
				"layer": {
					"type": "string",
					"description": "Target layer (e.g., 'F.Cu', 'B.Cu'). Empty = unspecified."
				},
				"width": {
					"type": "number",
					"description": "Trace width in mm. 0 = use default."
				},
				"bus_spacing": {
					"type": "number",
					"description": "Spacing between bus traces in mm (for bus hints). 0 = use default."
				},
				"text": {
					"type": "string",
					"description": "Additional notes or description"
				},
				"client_id": {
					"type": "string",
					"description": "Optional idempotency key. If a hint with this client_id already exists, the existing hint is returned instead of creating a duplicate."
				}
			},
			"required": ["editor_name", "hint_type"]
		}
	)

	_register_tool("minerva_pcb_list_route_hints",
		"List all routing hints on a PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: filter by 'human' or 'ai'"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_remove_route_hint",
		"Remove a specific routing hint by ID.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"hint_id": {
					"type": "string",
					"description": "ID of the route hint to remove"
				}
			},
			"required": ["editor_name", "hint_id"]
		}
	)

	_register_tool("minerva_pcb_clear_route_hints",
		"Clear routing hints from the PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: clear only hints by 'human' or 'ai'. Omit to clear all."
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_interpret_route_hints",
		"Interpret freeform annotations (arrows, polylines, text) as routing hints. Returns structured route hints inferred from annotation positions and text patterns.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_get_image",
		"Export a PCB view as a base64-encoded PNG image for LLM viewing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"width": {
					"type": "integer",
					"description": "Image width in pixels. Default: 800"
				},
				"height": {
					"type": "integer",
					"description": "Image height in pixels. Default: 600"
				},
				"show_grid": {
					"type": "boolean",
					"description": "Show alignment grid. Default: current setting"
				},
				"show_ratsnest": {
					"type": "boolean",
					"description": "Show unrouted connections. Default: current setting"
				},
				"show_annotations": {
					"type": "boolean",
					"description": "Show annotations. Default: current setting"
				},
				"show_route_hints": {
					"type": "boolean",
					"description": "Show route hints. Default: current setting"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_create_note",
		"Create a note from a PCB editor. The note displays the PCB as an image preview. Clicking Edit restores the full PCB state (components, nets, annotations, route hints).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"note_title": {
					"type": "string",
					"description": "Title for the new note. Defaults to editor name if not provided"
				},
				"thread_name": {
					"type": "string",
					"description": "Name of the notes thread/tab to add the note to. Defaults to 'PCB Boards'"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_pcb_get_change_journal",
		"Get the change journal for a PCB editor. Returns an append-only log of forward actions (moves, rotations, deletions, etc.) with timestamps.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"since_timestamp": {
					"type": "number",
					"description": "Optional Unix timestamp to filter entries from. Only entries at or after this time are returned."
				},
				"limit": {
					"type": "integer",
					"description": "Maximum number of entries to return (most recent). Default: 50"
				}
			},
			"required": ["editor_name"]
		}
	)

#endregion


#region PCB Editor Tool Implementations

## Find a PCB editor by name
func _find_pcb_editor(name_: String):  # Returns PCBEditor or null
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name = name_.strip_edges()

	# Look for PCB editor type
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.PCB and editor.tab_title == clean_name:
			return editor.pcb_editor

	# Case-insensitive match
	var lower_name = clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.PCB and editor.tab_title.to_lower() == lower_name:
			return editor.pcb_editor

	return null


## Create a new PCB editor
func _create_pcb_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "")
	var board_width: float = args.get("board_width", 100.0)
	var board_height: float = args.get("board_height", 100.0)

	if name_.is_empty():
		return {"error": "name is required", "success": false}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Create new PCB editor tab
	var editor = editor_pane.add_pcb_editor(name_)
	if not editor or not editor.pcb_editor:
		return {"error": "Failed to create PCB editor", "success": false}

	# Set board size
	var data = editor.pcb_editor.get_data()
	if data:
		data.board_width = board_width
		data.board_height = board_height
		data.board_name = name_

	return {
		"success": true,
		"editor_name": name_,
		"board_width": board_width,
		"board_height": board_height
	}


## Set board dimensions
func _pcb_set_board_size(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var width: float = args.get("width", 100.0)
	var height: float = args.get("height", 100.0)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	data.board_width = width
	data.board_height = height
	data.data_changed.emit()

	return {
		"success": true,
		"board_width": width,
		"board_height": height
	}


## Get all components from a PCB
func _pcb_get_components(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var components: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		var comp_info := {
			"id": comp.id,
			"footprint": PCBComponentScript.FootprintType.keys()[comp.footprint],
			"x": comp.position.x,
			"y": comp.position.y,
			"rotation": comp.rotation,
			"layer": comp.layer,
			"pins": comp.pins.keys()
		}
		if comp.properties.has("value"):
			comp_info["value"] = comp.properties["value"]
		components.append(comp_info)

	return {
		"success": true,
		"component_count": components.size(),
		"components": components
	}


## Describe component context
func _pcb_describe_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var context = pcb_editor.describe_component(component_id)
	if context.is_empty():
		return {"error": "Component not found: %s" % component_id, "success": false}

	context["success"] = true
	return context


## Spatial query
func _pcb_spatial_query(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var reference_component: String = args.get("reference_component", "")
	var radius: float = args.get("radius_mm", 20.0)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	if reference_component.is_empty():
		# Return all components if no reference
		return _pcb_get_components(args)

	var nearby = pcb_editor.get_nearby_components(reference_component, radius)
	var results: Array = []

	var spatial_index = pcb_editor.get_spatial_index()
	for comp_id in nearby:
		var desc = spatial_index.describe_relative_position(reference_component, comp_id)
		results.append({
			"id": comp_id,
			"relationship": desc
		})

	return {
		"success": true,
		"reference": reference_component,
		"radius_mm": radius,
		"nearby_count": results.size(),
		"nearby": results
	}


## Get all nets
func _pcb_get_nets(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var nets_arr: Array = []
	for net_name in data.nets:
		var net = data.nets[net_name]
		var pins_arr: Array = []
		for pin in net.pins:
			pins_arr.append("%s.%s" % [pin.get("component_id", ""), pin.get("pin_name", "")])

		nets_arr.append({
			"name": net.name,
			"pins": pins_arr,
			"is_power": net.is_power_net
		})

	return {
		"success": true,
		"net_count": nets_arr.size(),
		"nets": nets_arr
	}


## Get pin world position and info
func _pcb_get_pin_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var pin: String = args.get("pin", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}
	if pin.is_empty():
		return {"error": "pin is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var comp = data.get_component(component_id)
	if not comp:
		return {"error": "Component not found: %s" % component_id, "success": false}

	# Build available pins list for self-correction on error
	var available_pins: Array = []
	for pin_name in comp.pins:
		var _symbolic_name: String = comp.get_pin_name(str(pin_name))
		var entry := {"pin": str(pin_name)}
		if not _symbolic_name.is_empty():
			entry["name"] = _symbolic_name
		available_pins.append(entry)

	if not comp.pins.has(pin):
		return {
			"error": "Pin '%s' not found on component '%s'" % [pin, component_id],
			"success": false,
			"available_pins": available_pins
		}

	var world_pos: Vector2 = comp.get_pin_world_position(pin)
	var symbolic_name: String = comp.get_pin_name(pin)

	var result := {
		"success": true,
		"world_position": {"x": float(world_pos.x), "y": float(world_pos.y)},
		"component_position": {"x": float(comp.position.x), "y": float(comp.position.y)},
		"component_rotation": float(comp.rotation),
		"pin": str(pin),
		"pin_name": symbolic_name,
		"available_pins": available_pins
	}

	return result


## Add a component
func _pcb_add_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var footprint_str: String = args.get("footprint", "")
	var x: float = args.get("x", 50.0)
	var y: float = args.get("y", 50.0)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if footprint_str.is_empty():
		return {"error": "footprint is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Parse footprint type
	var footprint_idx := PCBComponentScript.FootprintType.keys().find(footprint_str.to_upper())
	if footprint_idx < 0:
		return {"error": "Invalid footprint type: %s" % footprint_str, "success": false}

	# Create component
	var component_id: String = args.get("id", "")
	if component_id.is_empty():
		var prefix = footprint_str[0] if footprint_str.length() > 0 else "U"
		component_id = data.generate_component_id(prefix)

	var comp = PCBComponentScript.new()
	comp.id = component_id
	comp.footprint = footprint_idx
	# Use exact position if snap_to_grid is false, otherwise snap
	var snap: bool = args.get("snap_to_grid", true)
	if snap:
		comp.position = data.snap_to_grid(Vector2(x, y))
	else:
		comp.position = Vector2(x, y)
	comp.rotation = args.get("rotation", 0.0)

	# Setup pins based on footprint type and optional pin_count
	var pin_count: int = args.get("pin_count", 0)
	var pin_names: Array = args.get("pin_names", [])

	if pin_count > 0:
		# Custom pin count specified
		match footprint_idx:
			PCBComponentScript.FootprintType.HEADER, PCBComponentScript.FootprintType.CONNECTOR:
				comp.setup_header_pins(pin_count, pin_names)
			PCBComponentScript.FootprintType.IC_DIP:
				comp.setup_dip_pins(pin_count)
			PCBComponentScript.FootprintType.MODULE:
				# MODULE uses wider row spacing and body extends beyond pins
				comp.setup_module_pins(pin_count)
			_:
				comp.setup_standard_pins()
	else:
		comp.setup_standard_pins()

	# Apply custom size if specified (use set_size to update local_bounds too)
	var custom_width: float = args.get("width", comp.width)
	var custom_height: float = args.get("height", comp.height)
	if args.has("width") or args.has("height"):
		comp.set_size(custom_width, custom_height)

	if args.has("value"):
		comp.properties["value"] = args.get("value")

	data.save_to_history("Add " + component_id)
	data.add_component(comp)

	return {
		"success": true,
		"component_id": component_id,
		"x": comp.position.x,
		"y": comp.position.y,
		"pin_count": comp.pins.size()
	}


## Move component absolute
func _pcb_move_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var x: float = args.get("x", 0.0)
	var y: float = args.get("y", 0.0)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	if not data.has_component(component_id):
		return {"error": "Component not found: %s" % component_id, "success": false}

	var new_pos = data.snap_to_grid(Vector2(x, y))
	data.save_to_history("Move " + component_id)
	data.move_component(component_id, new_pos)

	return {
		"success": true,
		"component_id": component_id,
		"x": new_pos.x,
		"y": new_pos.y
	}


## Move component relative
func _pcb_move_relative(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var direction: String = args.get("direction", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}
	if direction.is_empty():
		return {"error": "direction is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var new_pos = pcb_editor.move_component_relative(component_id, direction)

	return {
		"success": true,
		"component_id": component_id,
		"new_x": new_pos.x,
		"new_y": new_pos.y,
		"interpreted_direction": direction
	}


## Rotate component
func _pcb_rotate_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var degrees = args.get("degrees", 90)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var comp = data.get_component(component_id)
	if not comp:
		return {"error": "Component not found: %s" % component_id, "success": false}

	var new_rotation: float = comp.rotation
	if degrees is String:
		if degrees.to_lower() == "clockwise":
			new_rotation = fmod(comp.rotation + 90.0, 360.0)
		elif degrees.to_lower() == "counterclockwise":
			new_rotation = fmod(comp.rotation - 90.0 + 360.0, 360.0)
	else:
		new_rotation = float(degrees)

	data.save_to_history("Rotate " + component_id)
	data.rotate_component(component_id, new_rotation)

	return {
		"success": true,
		"component_id": component_id,
		"rotation": new_rotation
	}


## Delete component
func _pcb_delete_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if component_id.is_empty():
		return {"error": "component_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	if not data.has_component(component_id):
		return {"error": "Component not found: %s" % component_id, "success": false}

	data.save_to_history("Delete " + component_id)
	data.remove_component(component_id)

	return {
		"success": true,
		"deleted": component_id
	}


## Connect pins to net
func _pcb_connect_net(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var net_name: String = args.get("net_name", "")
	var pins: Array = args.get("pins", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if net_name.is_empty():
		return {"error": "net_name is required", "success": false}
	if pins.is_empty():
		return {"error": "pins array is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Collect operations first
	var operations: Array = []
	for pin_info in pins:
		if pin_info is Dictionary:
			var comp_id: String = pin_info.get("component", "")
			var pin_name: String = pin_info.get("pin", "")
			if not comp_id.is_empty() and not pin_name.is_empty():
				operations.append({"component": comp_id, "pin": pin_name})

	# Build result and test serialization before committing
	var connected: Array = []
	for op in operations:
		connected.append("%s.%s" % [str(op.component), str(op.pin)])

	var result := {
		"success": true,
		"net_name": str(net_name),
		"connected_pins": connected
	}
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return {"error": "Internal serialization error", "success": false}

	# Commit all operations
	for op in operations:
		data.connect_pin_to_net(net_name, op.component, op.pin)

	return result


## Export CSV
func _pcb_export_csv(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var csv = pcb_editor.export_csv()
	return {
		"success": true,
		"csv": csv
	}


## Export YAML
func _pcb_export_yaml(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var yaml = pcb_editor.export_yaml()
	return {
		"success": true,
		"yaml": yaml
	}


## Import CSV
func _pcb_import_csv(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var csv_content: String = args.get("csv_content", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if csv_content.is_empty():
		return {"error": "csv_content is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	pcb_editor.import_csv(csv_content)

	var data = pcb_editor.get_data()
	return {
		"success": true,
		"component_count": data.get_component_count() if data else 0
	}


## Import footprint geometry from pcb-architect
func _pcb_import_footprint_geometry(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var geometry_data: Dictionary = args.get("geometry", {})
	var position_is_center: bool = args.get("position_is_center", false)
	var invert_y: bool = args.get("invert_y", false)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if geometry_data.is_empty():
		return {"error": "geometry data is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var components_data: Dictionary = geometry_data.get("components", {})
	var updated_count := 0
	var position_adjusted_count := 0
	var missing: Array = []

	for comp_id in components_data:
		var comp = data.get_component(comp_id)
		if not comp:
			missing.append(comp_id)
			continue

		var comp_geometry: Dictionary = components_data[comp_id]
		if comp_geometry.get("footprint_found", false):
			# First load the pad geometry (this sets bbox_center_offset)
			comp.load_pad_geometry(comp_geometry)
			updated_count += 1

			# Then apply position corrections if requested
			if position_is_center or invert_y:
				var new_pos: Vector2 = comp.position

				# Order matters: first invert Y, then convert from center to origin

				# If Y is inverted (Y=0 at bottom), flip relative to board height
				if invert_y:
					new_pos.y = data.board_height - new_pos.y

				# If positions are geometric centers, convert to footprint origin
				# by subtracting the center offset (accounting for rotation)
				if position_is_center:
					var xform: Transform2D = comp.get_transform()
					var center_offset: Vector2 = xform * comp.bbox_center_offset
					new_pos -= center_offset

				comp.position = new_pos
				position_adjusted_count += 1
		else:
			missing.append(comp_id)

	# Save history so this operation can be undone
	data.save_to_history("Import footprint geometry")

	# Trigger redraw and zoom to fit the updated layout
	data.data_changed.emit()
	if pcb_editor.canvas:
		pcb_editor.canvas.zoom_to_fit()

	var result := {
		"success": true,
		"updated_count": updated_count,
		"missing_footprints": missing,
		"board_name": geometry_data.get("board_name", "")
	}

	if position_is_center or invert_y:
		result["position_adjusted_count"] = position_adjusted_count
		result["position_corrections_applied"] = {
			"position_is_center": position_is_center,
			"invert_y": invert_y,
			"board_height": data.board_height
		}

	return result


## Import trace geometry from pcb-architect
func _pcb_import_trace_geometry(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var trace_data: Dictionary = args.get("trace_data", {})

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if trace_data.is_empty():
		return {"error": "trace_data is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Clear existing traces
	data.clear_traces()

	# Group trace segments by net and layer into polylines
	var traces_input: Array = trace_data.get("traces", [])
	var trace_groups: Dictionary = {}  # "net_layer" -> {net_name, layer, width, segments}

	for seg in traces_input:
		var net_name: String = seg.get("net_name", "")
		var layer: String = seg.get("layer", "F.Cu")
		var key := "%s_%s" % [net_name, layer]

		if not trace_groups.has(key):
			trace_groups[key] = {
				"net_name": net_name,
				"layer": "top" if layer == "F.Cu" else "bottom",
				"width": seg.get("width", 0.3),
				"segments": []
			}

		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0))
		})

	# Convert segment groups to PCBTrace objects with connected waypoints
	var trace_count := 0
	for key in trace_groups:
		var group = trace_groups[key]
		var segments: Array = group.segments

		# Build connected polylines from segments
		var polylines := _build_polylines_from_segments(segments)

		for polyline in polylines:
			if polyline.size() < 2:
				continue

			var trace := PCBTraceScript.new()
			trace.id = "trace_%d" % trace_count
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width

			for point in polyline:
				trace.waypoints.append(point)

			data.add_trace(trace)
			trace_count += 1

	# Import vias
	var vias_input: Array = trace_data.get("vias", [])
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		data.add_via({
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", ["F.Cu", "B.Cu"])
		})

	# Save history so this operation can be undone/redone
	data.save_to_history("Import traces")

	if pcb_editor.canvas:
		pcb_editor.canvas.queue_redraw()
		pcb_editor.canvas.zoom_to_fit()

	return {
		"success": true,
		"trace_count": trace_count,
		"via_count": vias_input.size()
	}


## Helper function to connect segments into polylines
func _build_polylines_from_segments(segments: Array) -> Array:
	if segments.is_empty():
		return []

	var result: Array = []
	var used: Array = []
	used.resize(segments.size())
	used.fill(false)

	for i in range(segments.size()):
		if used[i]:
			continue

		var polyline: Array[Vector2] = [segments[i].start, segments[i].end]
		used[i] = true

		# Try to extend the polyline by finding connected segments
		var changed := true
		while changed:
			changed = false
			for j in range(segments.size()):
				if used[j]:
					continue

				var seg = segments[j]
				# Check if segment connects to end of polyline
				if seg.start.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.end)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.start)
					used[j] = true
					changed = true
				# Check if segment connects to start of polyline
				elif seg.end.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.start)
					used[j] = true
					changed = true
				elif seg.start.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.end)
					used[j] = true
					changed = true

		result.append(polyline)

	return result


## Add annotation
func _pcb_add_annotation(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var type_str: String = args.get("type", "")
	var positions_arr: Array = args.get("positions", [])
	var text_content: String = args.get("text", "")
	var color_str: String = args.get("color", "")
	var associated_comp: String = args.get("associated_component", "")
	var associated_net: String = args.get("associated_net", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if type_str.is_empty():
		return {"error": "type is required (arrow, text, region, polyline)", "success": false}
	if positions_arr.is_empty():
		return {"error": "positions array is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Convert positions
	var positions: Array[Vector2] = []
	for pos_data in positions_arr:
		if pos_data is Dictionary:
			positions.append(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))

	# Create annotation based on type
	var annotation: PCBAnnotationScript = null
	match type_str.to_lower():
		"arrow":
			if positions.size() < 2:
				return {"error": "arrow requires 2 positions (start, end)", "success": false}
			annotation = PCBAnnotationScript.create_arrow(positions[0], positions[1], text_content, "ai")
		"text":
			if positions.size() < 1:
				return {"error": "text requires 1 position", "success": false}
			if text_content.is_empty():
				return {"error": "text annotation requires text content", "success": false}
			annotation = PCBAnnotationScript.create_text(positions[0], text_content, "ai")
		"region":
			if positions.size() < 2:
				return {"error": "region requires 2 positions (corners)", "success": false}
			annotation = PCBAnnotationScript.create_region(positions[0], positions[1], text_content, "ai")
		"polyline":
			if positions.size() < 2:
				return {"error": "polyline requires at least 2 positions", "success": false}
			annotation = PCBAnnotationScript.create_polyline(positions, text_content, "ai")
		_:
			return {"error": "Unknown annotation type: %s" % type_str, "success": false}

	# Apply optional settings
	if not color_str.is_empty():
		annotation.color = Color.from_string(color_str, annotation.color)
	if not associated_comp.is_empty():
		annotation.associated_component = associated_comp
	if not associated_net.is_empty():
		annotation.associated_net = associated_net

	# Transactional: build result and test serialization before committing
	var result := {
		"success": true,
		"annotation_id": str(annotation.id),
		"type": str(type_str),
		"description": str(annotation.get_description())
	}
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return {"error": "Internal serialization error", "success": false}

	data.add_annotation(annotation)
	return result


## List annotations
func _pcb_list_annotations(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var annotations_list: Array = []
	var all_annotations: Array

	if author_filter.is_empty():
		all_annotations = data.get_all_annotations()
	else:
		all_annotations = data.get_annotations_by_author(author_filter)

	for ann in all_annotations:
		# Convert positions to serializable format
		var positions_arr: Array = []
		for pos in ann.positions:
			positions_arr.append({"x": pos.x, "y": pos.y})

		var ann_data := {
			"id": ann.id,
			"type": PCBAnnotationScript.AnnotationType.keys()[ann.type],
			"positions": positions_arr,
			"text": ann.text,
			"author": ann.author,
			"color": ann.color.to_html()
		}
		if not ann.associated_component.is_empty():
			ann_data["associated_component"] = ann.associated_component
		if not ann.associated_net.is_empty():
			ann_data["associated_net"] = ann.associated_net
		annotations_list.append(ann_data)

	return {
		"success": true,
		"count": annotations_list.size(),
		"annotations": annotations_list
	}


## Remove annotation
func _pcb_remove_annotation(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var annotation_id: String = args.get("annotation_id", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if annotation_id.is_empty():
		return {"error": "annotation_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	if not data.get_annotation(annotation_id):
		return {"error": "Annotation not found: %s" % annotation_id, "success": false}

	data.remove_annotation(annotation_id)

	return {
		"success": true,
		"removed": annotation_id
	}


## Clear annotations
func _pcb_clear_annotations(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Count before clearing
	var count_before := 0
	if author_filter.is_empty():
		count_before = data.get_all_annotations().size()
	else:
		count_before = data.get_annotations_by_author(author_filter).size()

	data.clear_annotations(author_filter)

	return {
		"success": true,
		"cleared_count": count_before,
		"filter": author_filter if not author_filter.is_empty() else "all"
	}


## Add a routing hint
func _pcb_add_route_hint(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var hint_type_str: String = args.get("hint_type", "")
	var source_pins_arr: Array = args.get("source_pins", [])
	var dest_pins_arr: Array = args.get("dest_pins", [])
	var waypoints_arr: Array = args.get("waypoints", [])
	var layer: String = args.get("layer", "")
	var width: float = args.get("width", 0.0)
	var bus_spacing: float = args.get("bus_spacing", 0.0)
	var text: String = args.get("text", "")
	var client_id: String = args.get("client_id", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if hint_type_str.is_empty():
		return {"error": "hint_type is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Convert waypoints to Vector2 array
	var waypoints: Array[Vector2] = []
	for wp_data in waypoints_arr:
		if wp_data is Dictionary:
			waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))

	# Convert pin arrays to typed arrays
	var source_pins: Array[String] = []
	for pin in source_pins_arr:
		source_pins.append(str(pin))
	var dest_pins: Array[String] = []
	for pin in dest_pins_arr:
		dest_pins.append(str(pin))

	# Create hint based on type
	var hint: PCBRouteHintScript
	match hint_type_str.to_lower():
		"waypoint":
			hint = PCBRouteHintScript.create_waypoint_hint(waypoints, text, "ai")
		"single_trace":
			if source_pins.is_empty() or dest_pins.is_empty():
				return {"error": "single_trace hint requires source_pins and dest_pins", "success": false}
			if source_pins[0] == dest_pins[0]:
				return {"error": "single_trace hint cannot have the same source and destination pin: %s" % source_pins[0], "success": false}
			hint = PCBRouteHintScript.create_single_trace_hint(
				source_pins[0], dest_pins[0], waypoints, layer, width, text, "ai"
			)
		"bus":
			if source_pins.is_empty() or dest_pins.is_empty():
				return {"error": "bus hint requires source_pins and dest_pins", "success": false}
			if source_pins.size() != dest_pins.size():
				return {"error": "bus hint requires equal number of source and dest pins", "success": false}
			hint = PCBRouteHintScript.create_bus_hint(
				source_pins, dest_pins, waypoints, layer, width, bus_spacing, text, "ai"
			)
		_:
			return {"error": "Invalid hint_type: %s. Must be 'waypoint', 'single_trace', or 'bus'" % hint_type_str, "success": false}

	# Set layer if specified
	if not layer.is_empty():
		hint.layer = layer

	# Set client_id for idempotency
	if not client_id.is_empty():
		hint.client_id = client_id

	var created_id := hint.id
	var returned_hint = data.add_route_hint(hint)
	if returned_hint == null:
		return {"error": "Route hint was rejected (self-referencing)", "success": false}

	var is_duplicate: bool = (returned_hint.id != created_id)

	var result := {
		"success": true,
		"hint_id": str(returned_hint.id),
		"hint_type": hint_type_str,
		"detail_level": str(PCBRouteHintScript.DetailLevel.keys()[returned_hint.detail_level]),
		"waypoint_count": int(waypoints.size()),
		"description": str(returned_hint.get_description())
	}
	if is_duplicate:
		result["duplicate"] = true

	# Transactional: test serialization before returning
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return {"error": "Internal serialization error", "success": false}

	return result


## List route hints
func _pcb_list_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# First, just return count and IDs to test
	var hint_ids: Array = []
	for hint_id in data.route_hints:
		hint_ids.append(str(hint_id))

	if hint_ids.is_empty():
		return {"success": true, "count": 0, "hints": []}

	var hints_arr: Array = []
	for hint_id in data.route_hints:
		var hint = data.route_hints[hint_id]
		if not author_filter.is_empty() and hint.author != author_filter:
			continue

		# Convert typed arrays to regular arrays for JSON serialization
		var src_pins: Array = []
		for pin in hint.source_pins:
			src_pins.append(str(pin))
		var dst_pins: Array = []
		for pin in hint.dest_pins:
			dst_pins.append(str(pin))

		# Convert waypoints
		var waypoints_data: Array = []
		for wp in hint.waypoints:
			waypoints_data.append({"x": float(wp.x), "y": float(wp.y)})

		var hint_dict: Dictionary = {
			"id": str(hint.id),
			"hint_type": str(PCBRouteHintScript.HintType.keys()[hint.hint_type]),
			"detail_level": str(PCBRouteHintScript.DetailLevel.keys()[hint.detail_level]),
			"author": str(hint.author),
			"layer": str(hint.layer),
			"width": float(hint.width),
			"source_pins": src_pins,
			"dest_pins": dst_pins,
			"text": str(hint.text),
			"waypoints": waypoints_data
		}

		if hint.hint_type == PCBRouteHintScript.HintType.BUS:
			hint_dict["bus_spacing"] = float(hint.bus_spacing)

		hints_arr.append(hint_dict)

	return {
		"success": true,
		"count": hints_arr.size(),
		"hints": hints_arr
	}


## Remove a route hint
func _pcb_remove_route_hint(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var hint_id: String = args.get("hint_id", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}
	if hint_id.is_empty():
		return {"error": "hint_id is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	if not data.get_route_hint(hint_id):
		return {"error": "Route hint not found: %s" % hint_id, "success": false}

	data.remove_route_hint(hint_id)

	return {
		"success": true,
		"removed": hint_id
	}


## Clear route hints
func _pcb_clear_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Count before clearing
	var count_before := 0
	if author_filter.is_empty():
		count_before = data.get_all_route_hints().size()
	else:
		count_before = data.get_route_hints_by_author(author_filter).size()

	data.clear_route_hints(author_filter)

	return {
		"success": true,
		"cleared_count": count_before,
		"filter": author_filter if not author_filter.is_empty() else "all"
	}


## Interpret freeform annotations as route hints
func _pcb_interpret_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	# Get all annotations
	var annotations = data.get_all_annotations()
	var components = data.get_all_components()

	# Build component lookup by position for proximity matching
	var component_positions: Dictionary = {}  # component_id -> center position
	for comp in components:
		var center_x: float = comp.x + comp.width / 2.0
		var center_y: float = comp.y + comp.height / 2.0
		component_positions[comp.id] = Vector2(center_x, center_y)

	# Analyze annotations for routing hints
	var interpreted_hints: Array = []

	for annotation in annotations:
		var hint_info: Dictionary = {
			"annotation_id": annotation.id,
			"annotation_type": PCBAnnotationScript.AnnotationType.keys()[annotation.type],
			"author": annotation.author,
			"text": annotation.text,
			"interpretation": {}
		}

		match annotation.type:
			PCBAnnotationScript.AnnotationType.ARROW:
				# Arrow might indicate routing direction between components
				if annotation.positions.size() >= 2:
					var start: Vector2 = annotation.positions[0]
					var end: Vector2 = annotation.positions[1]
					hint_info["interpretation"]["start"] = {"x": start.x, "y": start.y}
					hint_info["interpretation"]["end"] = {"x": end.x, "y": end.y}
					hint_info["interpretation"]["direction_vector"] = {
						"x": end.x - start.x,
						"y": end.y - start.y
					}

					# Find nearest components to start and end
					var nearest_start := _find_nearest_component(start, component_positions)
					var nearest_end := _find_nearest_component(end, component_positions)
					if not nearest_start.is_empty():
						hint_info["interpretation"]["near_start_component"] = nearest_start
					if not nearest_end.is_empty():
						hint_info["interpretation"]["near_end_component"] = nearest_end

					hint_info["interpretation"]["suggested_use"] = "routing_direction"

			PCBAnnotationScript.AnnotationType.POLYLINE:
				# Polyline might be a trace path suggestion
				if annotation.positions.size() >= 2:
					var waypoints_data: Array = []
					for pos in annotation.positions:
						waypoints_data.append({"x": pos.x, "y": pos.y})
					hint_info["interpretation"]["waypoints"] = waypoints_data
					hint_info["interpretation"]["waypoint_count"] = annotation.positions.size()

					# Find components near start and end
					var start: Vector2 = annotation.positions[0]
					var end: Vector2 = annotation.positions[annotation.positions.size() - 1]
					var nearest_start := _find_nearest_component(start, component_positions)
					var nearest_end := _find_nearest_component(end, component_positions)
					if not nearest_start.is_empty():
						hint_info["interpretation"]["near_start_component"] = nearest_start
					if not nearest_end.is_empty():
						hint_info["interpretation"]["near_end_component"] = nearest_end

					hint_info["interpretation"]["suggested_use"] = "trace_path"

			PCBAnnotationScript.AnnotationType.TEXT:
				# Text might contain routing instructions
				hint_info["interpretation"]["position"] = {
					"x": annotation.positions[0].x if annotation.positions.size() > 0 else 0,
					"y": annotation.positions[0].y if annotation.positions.size() > 0 else 0
				}

				# Check for common routing keywords
				var text_lower: String = annotation.text.to_lower()
				var keywords: Array = []
				if "route" in text_lower:
					keywords.append("route")
				if "trace" in text_lower:
					keywords.append("trace")
				if "bus" in text_lower:
					keywords.append("bus")
				if "layer" in text_lower or "f.cu" in text_lower or "b.cu" in text_lower:
					keywords.append("layer")
				if "via" in text_lower:
					keywords.append("via")
				if not keywords.is_empty():
					hint_info["interpretation"]["routing_keywords"] = keywords

				# Find nearest component
				if annotation.positions.size() > 0:
					var nearest := _find_nearest_component(annotation.positions[0], component_positions)
					if not nearest.is_empty():
						hint_info["interpretation"]["near_component"] = nearest

				hint_info["interpretation"]["suggested_use"] = "instruction"

			PCBAnnotationScript.AnnotationType.REGION:
				# Region might highlight an area for routing consideration
				if annotation.positions.size() >= 2:
					hint_info["interpretation"]["bounds"] = {
						"min": {"x": annotation.positions[0].x, "y": annotation.positions[0].y},
						"max": {"x": annotation.positions[1].x, "y": annotation.positions[1].y}
					}

					# Find components within region
					var rect: Rect2 = annotation.get_bounding_rect()
					var components_in_region: Array = []
					for comp_id in component_positions:
						if rect.has_point(component_positions[comp_id]):
							components_in_region.append(comp_id)
					if not components_in_region.is_empty():
						hint_info["interpretation"]["components_in_region"] = components_in_region

					hint_info["interpretation"]["suggested_use"] = "routing_region"

		interpreted_hints.append(hint_info)

	return {
		"success": true,
		"annotation_count": annotations.size(),
		"interpretations": interpreted_hints,
		"note": "These are suggested interpretations. Use minerva_pcb_add_route_hint to create structured hints based on this analysis."
	}


## Get PCB change journal
func _pcb_get_change_journal(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var since_timestamp: float = args.get("since_timestamp", 0.0)
	var limit: int = args.get("limit", 50)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	var data = pcb_editor.get_data()
	if not data:
		return {"error": "PCB data not available", "success": false}

	var entries: Array = data.get_change_journal(since_timestamp)

	# Slice to limit (most recent entries)
	if limit > 0 and entries.size() > limit:
		entries = entries.slice(entries.size() - limit)

	return {
		"success": true,
		"total_entries": data.change_journal.size(),
		"returned_entries": entries.size(),
		"entries": entries
	}


## Helper: find nearest component to a position
func _find_nearest_component(pos: Vector2, component_positions: Dictionary, max_distance: float = 20.0) -> String:
	var nearest_id := ""
	var nearest_dist := max_distance

	for comp_id in component_positions:
		var comp_pos: Vector2 = component_positions[comp_id]
		var dist := pos.distance_to(comp_pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = comp_id

	return nearest_id


## Export PCB view as base64-encoded PNG image
func _pcb_get_image(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var width: int = args.get("width", 800)
	var height: int = args.get("height", 600)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	if not pcb_editor.canvas:
		return {"error": "PCB canvas not available", "success": false}

	var canvas = pcb_editor.canvas
	var data = pcb_editor.get_data()

	# Store original display settings to restore after capture
	var orig_show_grid: bool = canvas.show_grid
	var orig_show_ratsnest: bool = canvas.show_ratsnest
	var orig_show_annotations: bool = canvas.show_annotations
	var orig_show_route_hints: bool = canvas.show_route_hints

	# Apply temporary overrides if specified
	if args.has("show_grid"):
		canvas.show_grid = args.get("show_grid")
	if args.has("show_ratsnest"):
		canvas.show_ratsnest = args.get("show_ratsnest")
	if args.has("show_annotations"):
		canvas.show_annotations = args.get("show_annotations")
	if args.has("show_route_hints"):
		canvas.show_route_hints = args.get("show_route_hints")

	# Capture the image
	var base64_png: String = await canvas.capture_to_base64_png(width, height)

	# Restore original settings
	canvas.show_grid = orig_show_grid
	canvas.show_ratsnest = orig_show_ratsnest
	canvas.show_annotations = orig_show_annotations
	canvas.show_route_hints = orig_show_route_hints

	if base64_png.is_empty():
		return {"error": "Failed to capture PCB image", "success": false}

	# Gather metadata about the board
	var metadata := {}
	if data:
		metadata["board_width_mm"] = data.board_width
		metadata["board_height_mm"] = data.board_height
		metadata["component_count"] = data.components.size()
		metadata["net_count"] = data.nets.size()
		if data.annotations:
			metadata["annotation_count"] = data.annotations.size()
		if data.route_hints:
			metadata["route_hint_count"] = data.route_hints.size()

	return {
		"success": true,
		"image_data": base64_png,
		"format": "png",
		"encoding": "base64",
		"width": width,
		"height": height,
		"metadata": metadata
	}


## Create a PCB note with full state restoration
func _pcb_create_note(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var note_title: String = args.get("note_title", "")
	var thread_name: String = args.get("thread_name", "PCB Boards")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var pcb_editor = _find_pcb_editor(editor_name)
	if not pcb_editor:
		return {"error": "PCB editor not found: %s" % editor_name, "success": false}

	if not pcb_editor.canvas:
		return {"error": "PCB canvas not available", "success": false}

	# Use editor name as note title if not provided
	if note_title.is_empty():
		note_title = editor_name

	# Capture image and get PCB data
	var pcb_image: Image = await pcb_editor.canvas.capture_to_image(800, 600)
	var pcb_data: Dictionary = pcb_editor.data.to_dict()

	# Create the PCB note with full state
	var note = NoteScript.create_pcb_note(note_title, pcb_image, pcb_data)

	# Find or create the notes thread
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var thread_vbox = notes_container.find_or_create_tab(thread_name)
	thread_vbox.add_note(note)

	return {
		"success": true,
		"note_uuid": note.uuid,
		"note_title": note_title,
		"thread_name": thread_name,
		"component_count": pcb_data.get("components", {}).size(),
		"net_count": pcb_data.get("nets", {}).size(),
		"message": "Created PCB note '%s' in thread '%s'. Edit button restores full state." % [note_title, thread_name]
	}

#endregion


#region Video Editor Tools

func _register_video_editor_tools() -> void:
	_register_tool("minerva_create_video_editor",
		"Open a recording in the video editor. Creates a new editor tab for editing a recorded video.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the video editor tab"
				},
				"recording_path": {
					"type": "string",
					"description": "Path to the recording directory (from minerva_video_list_recordings)"
				}
			},
			"required": ["name", "recording_path"]
		}
	)

	_register_tool("minerva_video_add_cut",
		"Cut out a time region from the video. The cut region will be excluded from the final export.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"start_ms": {
					"type": "integer",
					"description": "Start time in milliseconds"
				},
				"end_ms": {
					"type": "integer",
					"description": "End time in milliseconds"
				}
			},
			"required": ["editor_name", "start_ms", "end_ms"]
		}
	)

	_register_tool("minerva_video_add_speed_region",
		"Speed up a time region in the video (fast-forward effect).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"start_ms": {
					"type": "integer",
					"description": "Start time in milliseconds"
				},
				"end_ms": {
					"type": "integer",
					"description": "End time in milliseconds"
				},
				"speed": {
					"type": "number",
					"description": "Speed multiplier (e.g. 2.0, 3.0, 5.0). Default: 3.0"
				}
			},
			"required": ["editor_name", "start_ms", "end_ms"]
		}
	)

	_register_tool("minerva_video_remove_edit",
		"Remove a cut or speed edit by segment index, reverting it to normal playback.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"segment_index": {
					"type": "integer",
					"description": "Index of the segment to remove (from minerva_video_get_state)"
				}
			},
			"required": ["editor_name", "segment_index"]
		}
	)

	_register_tool("minerva_video_set_pip_position",
		"Set the Picture-in-Picture webcam overlay position at a specific time. Creates a keyframe for smooth transitions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"time_ms": {
					"type": "integer",
					"description": "Time in milliseconds for the keyframe"
				},
				"x": {
					"type": "number",
					"description": "Normalized X position (0.0=left, 1.0=right)"
				},
				"y": {
					"type": "number",
					"description": "Normalized Y position (0.0=top, 1.0=bottom)"
				}
			},
			"required": ["editor_name", "time_ms", "x", "y"]
		}
	)

	_register_tool("minerva_video_set_crop_position",
		"Set the vertical (9:16) crop region center position at a specific time. Creates a keyframe for the crop window.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"time_ms": {
					"type": "integer",
					"description": "Time in milliseconds for the keyframe"
				},
				"x": {
					"type": "number",
					"description": "Normalized center X position of the 9:16 crop (0.0=left, 0.5=center, 1.0=right)"
				}
			},
			"required": ["editor_name", "time_ms", "x"]
		}
	)

	_register_tool("minerva_video_get_state",
		"Get the current edit state of a video editor, including segments, keyframes, and duration.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				}
			},
			"required": ["editor_name"]
		}
	)

	_register_tool("minerva_video_export",
		"Export the video to MP4 file. Requires ffmpeg to be installed.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"output_path": {
					"type": "string",
					"description": "Full file path for the output MP4"
				},
				"aspect_ratio": {
					"type": "string",
					"enum": ["16:9", "9:16"],
					"description": "Export aspect ratio. '16:9' for landscape (1920x1080), '9:16' for vertical/shorts (1080x1920). Default: '16:9'"
				}
			},
			"required": ["editor_name", "output_path"]
		}
	)

	_register_tool("minerva_video_list_recordings",
		"List all available video recordings with their metadata.",
		{
			"type": "object",
			"properties": {},
		}
	)


## Find a video editor by tab name
func _find_video_editor(name_: String):  # Returns VideoEditorPanel or null
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name = name_.strip_edges()

	# Exact match
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.VIDEO_EDITOR and editor.tab_title == clean_name:
			return editor.video_editor_panel

	# Case-insensitive match
	var lower_name = clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.VIDEO_EDITOR and editor.tab_title.to_lower() == lower_name:
			return editor.video_editor_panel

	return null


## Create a new video editor
func _create_video_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "")
	var recording_path: String = args.get("recording_path", "")

	if name_.is_empty():
		return {"success": false, "error": "name is required"}
	if recording_path.is_empty():
		return {"success": false, "error": "recording_path is required"}

	# Check if editor already open with this name
	var existing = _find_video_editor(name_)
	if existing:
		return {"success": true, "editor_name": name_, "message": "Editor already open"}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"success": false, "error": "Editor pane not available"}

	var editor = editor_pane.add(Editor.Type.VIDEO_EDITOR, recording_path, name_)
	if not editor:
		return {"success": false, "error": "Failed to create video editor"}

	return {
		"success": true,
		"editor_name": name_,
		"message": "Video editor created for recording: %s" % recording_path
	}


## Add a cut segment
func _video_add_cut(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var start_ms: int = args.get("start_ms", 0)
	var end_ms: int = args.get("end_ms", 0)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_add_cut(start_ms, end_ms)


## Add a speed region
func _video_add_speed_region(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var start_ms: int = args.get("start_ms", 0)
	var end_ms: int = args.get("end_ms", 0)
	var speed: float = args.get("speed", 3.0)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_add_speed_region(start_ms, end_ms, speed)


## Remove an edit segment
func _video_remove_edit(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var segment_index: int = args.get("segment_index", -1)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_remove_edit(segment_index)


## Set PiP position keyframe
func _video_set_pip_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var time_ms: int = args.get("time_ms", 0)
	var x: float = args.get("x", 0.85)
	var y: float = args.get("y", 0.8)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_set_pip_position(time_ms, x, y)


## Set crop position keyframe
func _video_set_crop_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var time_ms: int = args.get("time_ms", 0)
	var x: float = args.get("x", 0.5)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_set_crop_position(time_ms, x)


## Get editor state
func _video_get_state(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	var state = editor.get_state_dict()
	state["success"] = true
	return state


## Export video
func _video_export(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var output_path: String = args.get("output_path", "")
	var aspect_ratio_str: String = args.get("aspect_ratio", "16:9")

	if output_path.is_empty():
		return {"success": false, "error": "output_path is required"}

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_export(output_path, aspect_ratio_str)


## List all recordings
func _video_list_recordings(_args: Dictionary) -> Dictionary:
	var VideoRecordingDataScript = load("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
	var recordings = VideoRecordingDataScript.list_recordings()
	return {
		"success": true,
		"recordings": recordings,
		"count": recordings.size()
	}

#endregion
