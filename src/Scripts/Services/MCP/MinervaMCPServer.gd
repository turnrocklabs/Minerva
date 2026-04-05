class_name MinervaMCPServer
extends RefCounted
## Internal MCP server — thin dispatch core.
## Domain logic lives in MCP/Modules/MCP*Tools.gd files.
## This file handles: module lifecycle, tool registration, dispatch routing,
## duplicate call detection, tool search, and plugin routing.

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

## Tool sets filtering: empty = all sets enabled (backward compatible)
var _enabled_tool_sets: Array = []

## Automatic tool management
var tool_search_index: ToolSearchIndex = ToolSearchIndex.new()
var tool_budget_manager: ToolBudgetManager = ToolBudgetManager.new()
var auto_tool_management: bool = false  # toggled via preferences

## Duplicate call detection
var _last_call_hash: String = ""
var _consecutive_count: int = 0
var _consecutive_error_count: int = 0

## Caller identity (threaded through tool dispatch chain)
var _current_caller_chat_id: String = ""
var _current_agent_id: String = ""

## Domain modules
var _modules: Array = []
var _agent_module: MCPAgentTools  # cached for signal wiring


func _init(manager = null) -> void:
	mcp_manager = manager
	# Load persisted tool set filter from config
	var config := MCPConfig.new()
	config.load_config()
	if not config.enabled_tool_groups.is_empty():
		_enabled_tool_sets = []
		for g in config.enabled_tool_groups:
			_enabled_tool_sets.append(g)

	# Load auto tool management setting
	if SingletonObject and SingletonObject.config_file:
		auto_tool_management = SingletonObject.config_file.get_value("Tools", "auto_tool_management", false)
		var budget: int = SingletonObject.config_file.get_value("Tools", "tool_token_budget", 3000)
		tool_budget_manager.set_budget(budget)

	if mcp_manager:
		_init_modules()
		_register_tool_search()
		print("[MinervaMCPServer] Registered %d tools (%d indexed for search)" % [get_tool_count(), tool_search_index.get_tool_count()])

		# Auto-activate tool_search in the budget manager
		var search_schema: Dictionary = {"name": "minerva_tool_search", "description": "This server has 170+ tools plus connected external MCP servers. Search to discover and activate. Categories: files, bash, terminal, chat, notes, spreadsheet, webview, PCB, graphics, video, agents, docket, costs. Docket tools: work tracking (create/query/transition items), knowledge (skills, hints, quality scoring), projects. Search 'docket skill' for skill discovery, 'docket' for all work tracking tools.", "input_schema": {
			"type": "object", "properties": {
				"query": {"type": "string", "description": "Keyword search or exact tool name"},
				"category": {"type": "string", "description": "Filter by category (optional)"},
				"limit": {"type": "integer", "description": "Max results (default 5)"},
			}, "required": ["query"]
		}}
		tool_budget_manager.activate_tool("minerva_tool_search", search_schema)


#region Module Lifecycle

func _init_modules() -> void:
	_modules = [
		MCPChatTools.new(self),
		MCPNotesTools.new(self),
		MCPEditorTools.new(self),
		MCPSpreadsheetTools.new(self),
		MCPKanbanTools.new(self),
		MCPPCBTools.new(self),
		MCPVideoTools.new(self),
		MCPAgentTools.new(self),
		MCPAutocoderTools.new(self),
		MCPModelTools.new(self),
		MCPSkillTools.new(self),
		MCPContainerTools.new(self),
		MCPCodeTools.new(self),
		MCPTerminalTools.new(self),
		MCPWebviewTools.new(self),
		MCPDocketTools.new(self),
	]

	# Cache agent module for signal wiring
	for module in _modules:
		if module is MCPAgentTools:
			_agent_module = module

	# Register all module tools
	for module in _modules:
		module.register_tools()

#endregion


#region Tool Registration

func _register_tool(name: String, description: String, input_schema: Dictionary, p_tool_set: String = "") -> void:
	var tool = MCPToolDefinitionScript.new()
	tool.name = name
	tool.description = description
	tool.input_schema = input_schema
	tool.server_name = SERVER_NAME
	tool.tool_set = p_tool_set
	mcp_manager.tool_registry[name] = tool

	# Also index for search-based discovery
	var full_schema: Dictionary = {
		"name": name,
		"description": description,
		"input_schema": input_schema,
	}
	tool_search_index.register_tool(name, description, full_schema, p_tool_set)


## Register all minerva_* tools in the MCPManager's tool_registry
func register_tools() -> void:
	# Tools are registered in _init via modules — this is called by connect_server
	pass


## Get the count of registered minerva tools
func get_tool_count() -> int:
	var count := 0
	for tool_name in mcp_manager.tool_registry:
		if mcp_manager.tool_registry[tool_name].server_name == SERVER_NAME:
			count += 1
	return count


func consume_session_iterative_attempt(reset_threshold_ms: int) -> int:
	var current_time := Time.get_ticks_msec()
	if current_time - _session_attempts_reset_time > reset_threshold_ms:
		_session_iterative_attempts = 0
	_session_iterative_attempts += 1
	_session_attempts_reset_time = current_time
	return _session_iterative_attempts


func reset_session_iterative_attempts() -> void:
	_session_iterative_attempts = 0
	_session_attempts_reset_time = Time.get_ticks_msec()


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

#endregion


#region Server Connect/Disconnect

## Connect (enable) the minerva server
func connect_server() -> void:
	if server_enabled:
		return

	register_tools()
	server_enabled = true

	# Connect completion routing for sub-agent workers
	if _agent_module:
		_agent_module.connect_signals()

	print("[MinervaMCPServer] Connected")


## Disconnect (disable) the minerva server
func disconnect_server() -> void:
	if not server_enabled:
		return

	if _agent_module:
		_agent_module.disconnect_signals()

	server_enabled = false
	print("[MinervaMCPServer] Disconnected")

#endregion


#region Tool Execution

## Execute a minerva_* tool (requires internal connection to be enabled)
func execute_tool(tool_name: String, arguments: Dictionary, caller_chat_id: String = "") -> Dictionary:
	if not server_enabled:
		return {"error": "Minerva server not connected", "success": false}
	_current_caller_chat_id = caller_chat_id
	var result: Dictionary = await _execute_tool_impl(tool_name, arguments)
	_current_caller_chat_id = ""
	return _check_duplicate_call(tool_name, arguments, result)


## Execute a minerva_* tool for HTTP/external access (does not require internal connection)
func execute_tool_for_http(tool_name: String, arguments: Dictionary, agent_id: String = "") -> Dictionary:
	_current_agent_id = agent_id
	var result: Dictionary = await _execute_tool_impl(tool_name, arguments)
	return _check_duplicate_call(tool_name, arguments, result)


## Cross-module tool dispatch. Modules call this when they need to invoke
## another module's tool (e.g., MCPAgentTools calling minerva_create_chat).
func call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	return await _execute_tool_impl(tool_name, arguments)


## Internal tool execution — routes to modules, plugins, or tool search
func _execute_tool_impl(tool_name: String, arguments: Dictionary) -> Dictionary:
	print("[MinervaMCPServer] Executing: %s" % tool_name)
	# Track tool usage for LRU
	tool_budget_manager.mark_used(tool_name)

	# Emit pre-execution signal for hook triggers (PreToolUse)
	if arguments is Dictionary and SingletonObject.trigger_manager and not SingletonObject.trigger_manager.triggers.is_empty():
		SingletonObject.emit_mcp_tool_about_to_execute(tool_name, arguments)

	# Tool search (always available, handled here to avoid module overhead)
	if tool_name == "minerva_tool_search":
		return _tool_search(arguments)

	# Route to domain modules
	for module in _modules:
		if module.can_handle(tool_name):
			return await module.handle(tool_name, arguments)

	# Plugin-contributed tools (minerva_<plugin_id>_*) — check first since
	# is_plugin_tool() is an exact-match lookup and avoids prefix collisions.
	if SingletonObject.plugin_tool_registry != null and SingletonObject.plugin_tool_registry.is_plugin_tool(tool_name):
		return await SingletonObject.plugin_tool_registry.handle_tool_call(tool_name, arguments)

	# Plugin management tools (minerva_plugin_list, etc.)
	if tool_name.begins_with("minerva_plugin_") and SingletonObject.plugin_mcp_tools != null:
		return await SingletonObject.plugin_mcp_tools.handle_tool_call(tool_name, arguments)

	# If auto tool management is on and tool exists but isn't active, hint to search
	if auto_tool_management and mcp_manager.tool_registry.has(tool_name):
		return {"error": "Tool '%s' is not loaded. Call minerva_tool_search('%s') to activate it." % [tool_name, tool_name], "success": false}

	return {"error": "Unknown minerva tool: %s" % tool_name, "success": false}


## Check for duplicate calls and inject warning if detected
func _check_duplicate_call(tool_name: String, arguments: Dictionary, result: Dictionary) -> Dictionary:
	var call_hash: String = (tool_name + JSON.stringify(arguments)).sha256_text()
	if call_hash == _last_call_hash:
		_consecutive_count += 1
		if _consecutive_count >= 3:
			result["warning"] = "This tool has been called %d times with identical arguments. You are likely stuck in a loop. Stop and reassess your plan." % (_consecutive_count + 1)
		elif _consecutive_count >= 1:
			result["warning"] = "Identical call repeated. Consider advancing to the next step in your plan."
	else:
		_consecutive_count = 0
	_last_call_hash = call_hash

	# Track consecutive errors on repeated calls
	var is_error: bool = result.has("error") or result.get("success", true) == false
	if call_hash == _last_call_hash and is_error:
		_consecutive_error_count += 1
	else:
		_consecutive_error_count = 0

	# Escalate based on consecutive error count
	if _consecutive_error_count >= 5:
		result["error"] = "BLOCKED: This tool has been called %d times with identical arguments and failed every time. This approach does not work. Try a completely different tool or approach, or report that you are blocked." % _consecutive_error_count
		result["blocked"] = true
	elif _consecutive_error_count >= 3:
		result["warning"] = "STOP: You have called this tool %d times with identical arguments and it failed each time. Do NOT retry. Try a different approach immediately." % _consecutive_error_count

	return result

#endregion


#region Tool Search

func _register_tool_search() -> void:
	_register_tool("minerva_tool_search",
		"This server has 170+ tools available, plus tools from connected external MCP servers. Only minerva_tool_search is loaded by default to save tokens. Search by keyword to discover and activate tools. Activated tools can be called directly in subsequent turns. Common categories: files (read/write/edit/glob/grep), bash, terminal (read/write/wait/list), chat (send/list/create), notes, spreadsheet (create/format/chart), webview (create/update HTML panels), PCB design, graphics, video, agents, automation, models, costs. Connected external servers (e.g., docket, nudge, cobrowser) are also searchable by name. Example: tool_search(query='edit file') or tool_search(query='docket') or tool_search(query='webview panel').",
		{"type": "object", "properties": {
			"query": {"type": "string", "description": "Keyword search (e.g., 'edit file', 'docket create', 'cost summary') or exact tool name (e.g., 'minerva_file_edit')"},
			"category": {"type": "string", "description": "Filter by category: codetools, terminal, chat, notes, editor, spreadsheet, webview, pcb, video, agents, triggers, autocoder, costs, meta. External server names (e.g., docket, nudge) also work as categories."},
			"limit": {"type": "integer", "description": "Max results (default 5)"},
		}, "required": ["query"]}, "meta")


func _tool_search(arguments: Dictionary) -> Dictionary:
	var query: String = arguments.get("query", "")
	var category: String = arguments.get("category", "")
	var limit: int = int(arguments.get("limit", 5))

	# Search broadly — fetch all matches so we can show the full catalog
	var raw_results: Array[Dictionary] = tool_search_index.search(query, category, 200)

	# Filter results through connectivity and tool_set checks
	var filtered: Array[Dictionary] = []
	for result in raw_results:
		var name: String = result.get("name", "")
		if not mcp_manager or not mcp_manager.tool_registry.has(name):
			continue
		var tool = mcp_manager.tool_registry[name]
		# Check connectivity (minerva tools are always local, only check external servers)
		if tool.server_name != "minerva" and not mcp_manager.is_server_connected(tool.server_name):
			continue
		# Check tool_set filter — only applies to minerva-native tools.
		if tool.server_name == "minerva" and not _enabled_tool_sets.is_empty():
			if tool.tool_set != "meta" and tool.tool_set not in _enabled_tool_sets:
				continue
		filtered.append(result)

	if filtered.is_empty():
		return {"success": true, "tools": [], "count": 0, "total_matches": 0, "message": "No tools found matching '%s'" % query}

	# Split: top N get full schemas (activated), remainder get name+description only
	var activated: Array[String] = []
	var tool_summaries: Array[Dictionary] = []

	for i in range(filtered.size()):
		var result: Dictionary = filtered[i]
		var name: String = result.get("name", "")
		var description: String = result.get("description", "")

		if i < limit:
			# Top results: full schema, activated in budget manager
			var schema: Dictionary = result.get("schema", {})
			if not name.is_empty() and not schema.is_empty():
				tool_budget_manager.activate_tool(name, schema)
				activated.append(name)
			tool_summaries.append({
				"name": name,
				"description": description,
				"input_schema": schema.get("input_schema", {}),
			})
		else:
			# Remaining: lightweight name+description only
			tool_summaries.append({
				"name": name,
				"description": description,
			})

	var message: String
	if filtered.size() <= limit:
		message = "Found %d tools. They are now activated and can be called directly." % filtered.size()
	else:
		message = "Found %d tools. Top %d are activated and ready to call. The remaining %d are listed by name — search by exact name to activate any of them." % [filtered.size(), limit, filtered.size() - limit]

	return {
		"success": true,
		"tools": tool_summaries,
		"count": tool_summaries.size(),
		"activated": activated,
		"total_matches": filtered.size(),
		"message": message,
	}

#endregion
