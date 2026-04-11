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

## Policy engine — evaluates tool calls against Docket-sourced rules
var policy_engine: PolicyEngine

## Duplicate call detection
var _last_call_hash: String = ""
var _consecutive_count: int = 0
var _consecutive_error_count: int = 0

## Error-loop detection: tracks last error hash per tool name
## Format: { tool_name: { "error_hash": int, "count": int } }
var _error_tracker: Dictionary = {}

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

	# Initialize policy engine (loads rules from Docket)
	policy_engine = PolicyEngine.new()
	policy_engine.reload()

	# Register policy meta-tools
	_register_policy_tools()

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
	var previous_caller_chat_id := _current_caller_chat_id
	var previous_agent_id := _current_agent_id
	_current_caller_chat_id = caller_chat_id
	_current_agent_id = ""
	var result: Dictionary = await _execute_tool_impl(tool_name, arguments)
	_current_caller_chat_id = previous_caller_chat_id
	_current_agent_id = previous_agent_id
	_maybe_capture_chat_knowledge(tool_name, result, caller_chat_id)
	return _check_duplicate_call(tool_name, arguments, result)


## Execute a minerva_* tool for HTTP/external access (does not require internal connection)
func execute_tool_for_http(tool_name: String, arguments: Dictionary, agent_id: String = "") -> Dictionary:
	var previous_caller_chat_id := _current_caller_chat_id
	var previous_agent_id := _current_agent_id
	_current_caller_chat_id = ""
	_current_agent_id = agent_id
	var result: Dictionary = await _execute_tool_impl(tool_name, arguments)
	_current_caller_chat_id = previous_caller_chat_id
	_current_agent_id = previous_agent_id
	return _check_duplicate_call(tool_name, arguments, result)


## Cross-module tool dispatch. Modules call this when they need to invoke
## another module's tool (e.g., MCPAgentTools calling minerva_create_chat).
func call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	return await _execute_tool_impl(tool_name, arguments)


## Internal tool execution — routes to modules, plugins, or tool search
func _execute_tool_impl(tool_name: String, arguments: Dictionary) -> Dictionary:
	print("[MinervaMCPServer] Executing: %s" % tool_name)

	# Policy override tool — handled before policy check so it can't be blocked
	if tool_name == "minerva_policy_override":
		return await _handle_policy_override(arguments)

	# Policy reload tool — handled before policy check
	if tool_name == "minerva_policy_reload":
		policy_engine.reload()
		return {"success": true, "rules_loaded": policy_engine.rule_count()}

	# PRE-TOOL POLICY CHECK — before tool_budget_manager and advisory hooks
	var pending_observations: Array = []
	if policy_engine:
		var policy_result := policy_engine.evaluate(tool_name, arguments, _current_caller_chat_id)
		if not policy_result["allowed"]:
			# Pre-activate tools the agent needs to comply with the policy
			_activate_policy_tools(policy_result)
			SingletonObject.emit_mcp_tool_blocked(tool_name, arguments, policy_result, _current_agent_id)
			return policy_result
		pending_observations = policy_result.get("observations", [])

	# Track tool usage for LRU (blocked calls don't count)
	tool_budget_manager.mark_used(tool_name)

	# Emit pre-execution signal for hook triggers (PreToolUse)
	if arguments is Dictionary and SingletonObject.trigger_manager and not SingletonObject.trigger_manager.triggers.is_empty():
		SingletonObject.emit_mcp_tool_about_to_execute(tool_name, arguments)

	# Dispatch to the appropriate handler and collect the result
	var dispatch_result: Dictionary = {}
	var dispatched := false

	# Tool search (always available, handled here to avoid module overhead)
	if tool_name == "minerva_tool_search":
		dispatch_result = _tool_search(arguments)
		dispatched = true

	# Route to domain modules
	if not dispatched:
		for module in _modules:
			if module.can_handle(tool_name):
				dispatch_result = await module.handle(tool_name, arguments)
				dispatched = true
				break

	# Plugin-contributed tools (minerva_<plugin_id>_*) — check first since
	# is_plugin_tool() is an exact-match lookup and avoids prefix collisions.
	if not dispatched and SingletonObject.plugin_tool_registry != null and SingletonObject.plugin_tool_registry.is_plugin_tool(tool_name):
		dispatch_result = await SingletonObject.plugin_tool_registry.handle_tool_call(tool_name, arguments)
		dispatched = true

	# Plugin management tools (minerva_plugin_list, etc.)
	if not dispatched and tool_name.begins_with("minerva_plugin_") and SingletonObject.plugin_mcp_tools != null:
		dispatch_result = await SingletonObject.plugin_mcp_tools.handle_tool_call(tool_name, arguments)
		dispatched = true

	if not dispatched:
		# If auto tool management is on and tool exists but isn't active, hint to search
		if auto_tool_management and mcp_manager.tool_registry.has(tool_name):
			dispatch_result = {"error": "Tool '%s' is not loaded. Call minerva_tool_search('%s') to activate it." % [tool_name, tool_name], "success": false}
		else:
			dispatch_result = {"error": "Unknown minerva tool: %s" % tool_name, "success": false}

	# POST-DISPATCH: drain observation telemetry (best-effort, non-blocking)
	if not pending_observations.is_empty():
		_write_observation_telemetry(pending_observations)

	return dispatch_result


func _record_history_knowledge_telemetry(history, update: Dictionary) -> void:
	if history == null:
		return
	var telemetry: Dictionary = history.AgentContextTelemetry.duplicate(true)
	for key in update.keys():
		telemetry[key] = update[key]
	history.AgentContextTelemetry = telemetry


func _maybe_capture_chat_knowledge(tool_name: String, result: Dictionary, caller_chat_id: String) -> void:
	if caller_chat_id.is_empty():
		return
	if result.is_empty() or result.get("success", true) == false:
		return

	var history = MCPToolUtils.find_chat_by_id(caller_chat_id)
	if history == null:
		return

	var knowledge_entries := _extract_knowledge_entries(tool_name, result)
	if knowledge_entries.is_empty():
		_record_history_knowledge_telemetry(history, {
			"last_knowledge_capture_tool": tool_name,
			"last_knowledge_capture_status": "pure_read_internal",
		})
		return

	var acquired: Array[Dictionary] = history.AcquiredKnowledge.duplicate(true)
	var changed_count := 0
	for knowledge_entry in knowledge_entries:
		var entry_id := str(knowledge_entry.get("id", ""))
		var entry_type := str(knowledge_entry.get("type", "knowledge"))
		var replaced := false
		for i in range(acquired.size()):
			if str(acquired[i].get("id", "")) == entry_id and str(acquired[i].get("type", "")) == entry_type and not entry_id.is_empty():
				acquired[i] = knowledge_entry
				replaced = true
				changed_count += 1
				break
		if not replaced:
			acquired.append(knowledge_entry)
			changed_count += 1
	history.AcquiredKnowledge = acquired
	_record_history_knowledge_telemetry(history, {
		"last_knowledge_capture_tool": tool_name,
		"last_knowledge_capture_status": "captured",
		"last_knowledge_capture_count": knowledge_entries.size(),
		"last_knowledge_capture_changed": changed_count,
		"knowledge_items": acquired.size(),
	})


func _build_knowledge_entry(item_type: String, item_id: String, title: String, description: String, content: String) -> Dictionary:
	if item_id.is_empty() and title.is_empty() and content.is_empty():
		return {}
	return {
		"id": item_id,
		"type": item_type,
		"title": title,
		"description": description,
		"content": content,
	}


func _extract_content_field(result: Dictionary, fields: Array[String]) -> String:
	for field in fields:
		var value = result.get(field, "")
		if value is String and not value.is_empty():
			return str(value)
	return ""


func _extract_knowledge_entries(tool_name: String, result: Dictionary) -> Array[Dictionary]:
	match tool_name:
		"minerva_get_skill":
			var minerva_skill_entry := _build_knowledge_entry(
				"skill",
				str(result.get("id", "")),
				str(result.get("name", "")),
				str(result.get("description", "")),
				_extract_content_field(result, ["instructions", "steps", "outcome"])
			)
			var minerva_skill_entries: Array[Dictionary] = []
			if not minerva_skill_entry.is_empty():
				minerva_skill_entries.append(minerva_skill_entry)
			return minerva_skill_entries
		"minerva_docket_hint_get":
			var hint_entry := _build_knowledge_entry(
				"hint",
				str(result.get("id", "")),
				str(result.get("title", "")),
				str(result.get("summary", "")),
				_extract_content_field(result, ["value", "article"])
			)
			var hint_entries: Array[Dictionary] = []
			if not hint_entry.is_empty():
				hint_entries.append(hint_entry)
			return hint_entries
		"minerva_docket_hint_query", "minerva_docket_context":
			var entries: Array[Dictionary] = []
			var items = result.get("items", [])
			if items is Array:
				for item in items:
					if not (item is Dictionary):
						continue
					var dict_item: Dictionary = item
					var item_type := str(dict_item.get("type", ""))
					if tool_name == "minerva_docket_hint_query" and item_type.is_empty():
						item_type = "hint"
					if item_type not in ["kb", "hint", "insight", "skill"]:
						continue
					var entry := _build_knowledge_entry(
						item_type,
						str(dict_item.get("id", "")),
						str(dict_item.get("title", "")),
						str(dict_item.get("summary", dict_item.get("description", ""))),
						_extract_content_field(dict_item, ["value", "steps", "article", "answer", "corrected"])
					)
					if not entry.is_empty():
						entries.append(entry)
						if entries.size() >= 12:
							break
			return entries
		"minerva_docket_skill_get":
			var docket_skill_entry := _build_knowledge_entry(
				"skill",
				str(result.get("id", "")),
				str(result.get("title", "")),
				str(result.get("description", "")),
				_extract_content_field(result, ["steps", "outcome", "preconditions"])
			)
			var docket_skill_entries: Array[Dictionary] = []
			if not docket_skill_entry.is_empty():
				docket_skill_entries.append(docket_skill_entry)
			return docket_skill_entries
		"minerva_docket_get":
			var item_type := str(result.get("type", ""))
			if item_type in ["kb", "hint", "insight", "skill"]:
				var docket_entry := _build_knowledge_entry(
					item_type,
					str(result.get("id", "")),
					str(result.get("title", "")),
					str(result.get("summary", "")),
					_extract_content_field(result, ["value", "steps", "article", "answer", "corrected"])
				)
				var docket_entries: Array[Dictionary] = []
				if not docket_entry.is_empty():
					docket_entries.append(docket_entry)
				return docket_entries
	var empty_entries: Array[Dictionary] = []
	return empty_entries


## Check for duplicate calls and inject warning if detected
func _check_duplicate_call(tool_name: String, arguments: Dictionary, result: Dictionary) -> Dictionary:
	# Translate nested cobrowser errors into top-level errors with prescriptive messages.
	# Cobrowser wraps errors as {"success": true, "result": {"error": "...", "success": false}}.
	# This makes them invisible to error tracking and unhelpful to the LLM.
	if result.get("success", false) == true and result.has("result"):
		var inner = result.get("result")
		if inner is Dictionary and inner.get("success", true) == false and inner.has("error"):
			var inner_error: String = str(inner["error"])
			result["success"] = false
			# Prescriptive error messages for common cobrowser failures
			if "No active tab" in inner_error or "Invalid tab ID" in inner_error:
				result["error"] = "No browser tab found. Call cobrowser_tab_new to create a tab, or cobrowser_tab_list to discover existing tabs. Do NOT guess tab IDs — they are arbitrary numbers like 47, 53, 56."
			elif "Could not establish connection" in inner_error or "Receiving end does not exist" in inner_error:
				result["error"] = "Browser extension not responding on this tab. The tab may have been closed or the extension reloaded. Call cobrowser_tab_list to find valid tabs, or cobrowser_tab_new to create a new one."
			else:
				result["error"] = inner_error

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

	# Track consecutive errors on repeated calls (now sees cobrowser errors too)
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

	# Error-loop detection: same tool, same error message, different (or same) arguments
	_check_error_loop(tool_name, result, is_error)

	return result


## Detect when the same tool keeps returning the same error (regardless of arguments).
## Injects a "retry_hint" key to nudge the LLM toward a different approach.
func _check_error_loop(tool_name: String, result: Dictionary, is_error: bool) -> void:
	if is_error:
		var error_msg: String = str(result.get("error", result.get("success", "")))
		var error_hash: int = error_msg.hash()

		if _error_tracker.has(tool_name):
			var entry: Dictionary = _error_tracker[tool_name]
			if entry["error_hash"] == error_hash:
				entry["count"] += 1
				_error_tracker[tool_name] = entry
				var count: int = entry["count"]
				if count >= 3:
					result["retry_hint"] = "STOP: This tool keeps failing. Review your available tools and choose a different approach entirely."
				elif count >= 2:
					result["retry_hint"] = "This tool has failed 2 times with the same error. Try a different tool or approach."
			else:
				# Different error — reset counter for this tool
				_error_tracker[tool_name] = {"error_hash": error_hash, "count": 1}
		else:
			_error_tracker[tool_name] = {"error_hash": error_hash, "count": 1}
	else:
		# Tool succeeded — clear its error tracking entry
		if _error_tracker.has(tool_name):
			_error_tracker.erase(tool_name)
		# Also clear entries for other tools when a different tool succeeds,
		# since the agent has adapted and is no longer stuck.
		for other_tool in _error_tracker.keys():
			if other_tool != tool_name:
				_error_tracker.erase(other_tool)

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

	# Top N are activated (full schema sent to API tools array).
	# Chat result is minimal — schemas are already in the tools array where models read them.
	var activated: Array[String] = []
	var also_available: Array[String] = []

	for i in range(filtered.size()):
		var result: Dictionary = filtered[i]
		var name: String = result.get("name", "")

		if i < limit:
			var schema: Dictionary = result.get("schema", {})
			if not name.is_empty() and not schema.is_empty():
				tool_budget_manager.activate_tool(name, schema)
				activated.append(name)
		else:
			also_available.append(name)

	var message: String
	if filtered.size() <= limit:
		message = "%d tools activated and ready to call." % activated.size()
	else:
		message = "%d tools activated. %d more available — search by exact name to activate." % [activated.size(), also_available.size()]

	var result_dict: Dictionary = {
		"success": true,
		"activated": activated,
		"message": message,
	}
	# Only include overflow list if small enough to be useful; omit when too large
	if not also_available.is_empty() and also_available.size() <= 20:
		result_dict["also_available"] = also_available
	elif not also_available.is_empty():
		result_dict["remaining_count"] = also_available.size()
	return result_dict

#endregion


#region Policy Tools

func _register_policy_tools() -> void:
	_register_tool(
		"minerva_policy_reload",
		"Reload policy rules from Docket. Call after editing policy items.",
		{"type": "object", "properties": {}, "required": []},
		"meta"
	)

	_register_tool(
		"minerva_policy_override",
		"Override a blocking policy rule for this session. Requires rule_id.",
		{"type": "object", "properties": {
			"rule_id": {"type": "string", "description": "ID of the policy rule to override"},
			"reason": {"type": "string", "description": "Why the override is needed"}
		}, "required": ["rule_id"]},
		"meta"
	)


func _handle_policy_override(arguments: Dictionary) -> Dictionary:
	var rule_id: String = arguments.get("rule_id", "")
	var reason: String = arguments.get("reason", "")
	if rule_id.is_empty():
		return {"error": "rule_id is required", "success": false}

	# Human-gated: require UI confirmation for policy overrides.
	var approved := await _request_policy_override_approval(rule_id, reason)
	if not approved:
		return {"error": "Policy override denied — human approval required", "success": false}

	policy_engine.add_session_override(rule_id)
	return {"success": true, "message": "Rule %s overridden for this session" % rule_id}


func _request_policy_override_approval(rule_id: String, reason: String) -> bool:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Policy Override — Human Approval Required"
	var msg := "An agent is requesting to override a blocking policy rule for this session.\n\nRule: %s" % rule_id
	if not reason.is_empty():
		msg += "\nReason: %s" % reason
	msg += "\n\nApprove only if you intended this."
	dialog.dialog_text = msg
	dialog.ok_button_text = "Approve Override"
	dialog.cancel_button_text = "Deny"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
	dialog.size = Vector2i(500, 200)

	var tree := Engine.get_main_loop()
	if tree == null or not tree is SceneTree:
		return false
	(tree as SceneTree).root.add_child(dialog)
	dialog.popup_centered()

	var result := [false]
	var done := [false]
	dialog.confirmed.connect(func():
		result[0] = true
		done[0] = true
	)
	dialog.canceled.connect(func():
		result[0] = false
		done[0] = true
	)
	while not done[0]:
		await (tree as SceneTree).process_frame

	dialog.queue_free()
	return result[0]


## Write observation telemetry to Docket as comments on rule items.
## Best-effort: failures are silently ignored so they never break tool dispatch.
## Goes through DocketManager.call_tool() directly (not MCP dispatch) to avoid
## recursion back into the policy engine.
func _write_observation_telemetry(observations: Array) -> void:
	var dm = SingletonObject.docket_manager if SingletonObject else null
	if dm == null:
		return
	for obs in observations:
		var rule_id: String = str(obs.get("rule_id", ""))
		if rule_id.is_empty():
			continue
		var comment_text := "[Observation] Tool: %s | Would-have: %s | Time: %s\nFacts: %s" % [
			str(obs.get("tool_name", "?")),
			str(obs.get("would_have_effect", "?")),
			Time.get_datetime_string_from_system(),
			str(obs.get("facts", {})),
		]
		# Best-effort write — ignore errors to never disrupt the tool call path
		dm.call_tool("docket_comment", {
			"action": "add",
			"item_id": rule_id,
			"author": "policy-engine",
			"text": comment_text,
		})


## Pre-activate tools referenced in a policy block response so the agent can comply.
## Parses tool names from knowledge_ref (activates minerva_docket_get) and alternatives.
func _activate_policy_tools(policy_result: Dictionary) -> void:
	# Always activate minerva_docket_get so the agent can read the KB
	var knowledge_ref: String = str(policy_result.get("knowledge_ref", ""))
	if not knowledge_ref.is_empty():
		var schema := {"name": "minerva_docket_get", "description": "Get a docket item by ID.", "input_schema": {
			"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]
		}}
		tool_budget_manager.activate_tool("minerva_docket_get", schema)

	# Parse tool names from alternatives (match any word_word pattern, then check registry)
	var re := RegEx.new()
	re.compile(r"\b([a-z][a-z0-9]*_[a-z0-9_]+)\b")
	for alt in policy_result.get("allowed_next_actions", []):
		var matches := re.search_all(str(alt))
		for m in matches:
			var tool_name: String = m.get_string(1)
			if mcp_manager.tool_registry.has(tool_name):
				var tool_def = mcp_manager.tool_registry[tool_name]
				var schema := {"name": tool_name, "description": tool_def.description, "input_schema": tool_def.input_schema}
				tool_budget_manager.activate_tool(tool_name, schema)

#endregion
