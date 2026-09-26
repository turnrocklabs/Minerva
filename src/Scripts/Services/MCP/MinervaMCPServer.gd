class_name MinervaMCPServer
extends RefCounted
## Internal MCP server — thin dispatch core.
## Domain logic lives in MCP/Modules/MCP*Tools.gd files.
## This file handles: module lifecycle, tool registration, dispatch routing,
## duplicate call detection, tool search, and plugin routing.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const _MCPAnnotationReplyToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationReplyTools.gd")

## Non-owning parent link; MCPManager owns this server.
var _mcp_manager_ref: WeakRef = null
var mcp_manager:
	get:
		return _mcp_manager_ref.get_ref() if _mcp_manager_ref != null else null
	set(value):
		_mcp_manager_ref = weakref(value) if value != null else null

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

const _LoopTracker = preload("res://Scripts/Services/MCP/MCPLoopTracker.gd")
var _loop_tracker := _LoopTracker.new()

const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")

## Domain modules
var _modules: Array = []
var _agent_module: MCPAgentTools  # cached for signal wiring

const TOOL_MEMORY_HYDRATION_TOOLS := {
	"minerva_tool_memory_search": true,
	"minerva_list_agent_notes": true,
	"minerva_get_agent_note": true,
	"minerva_read_agent_note": true,
}


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
		var budget: int = SingletonObject.config_file.get_value("Tools", "tool_token_budget", ToolBudgetManager.DEFAULT_BUDGET)
		tool_budget_manager.set_budget(budget)
		var idle_turns: int = SingletonObject.config_file.get_value("Tools", "tool_max_idle_turns", ToolBudgetManager.DEFAULT_MAX_IDLE_TURNS)
		tool_budget_manager.set_max_idle_turns(idle_turns)

	if mcp_manager:
		_init_modules()
		_register_tool_search()
		print("[MinervaMCPServer] Registered %d tools (%d indexed for search)" % [get_tool_count(), tool_search_index.get_tool_count()])

		# Auto-activate tool_search in the budget manager
		var search_schema: Dictionary = {"name": "minerva_tool_search", "description": "This server has 170+ tools plus connected external MCP servers and installed plugins. Search to discover and activate them. Common categories: files, bash, terminal, chat, notes, spreadsheet, webview, graphics, video, agents, docket, costs. Docket tools: work tracking (create/query/transition items), knowledge (skills, hints, quality scoring), projects. Search 'docket skill' for skill discovery, 'docket' for all work tracking tools.", "input_schema": {
			"type": "object", "properties": {
				"query": {"type": "string", "description": "Keyword search or exact tool name"},
				"category": {"type": "string", "description": "Filter by category (optional)"},
				"limit": {"type": "integer", "description": "Max results (default 5)"},
			}, "required": ["query"]
		}}
		tool_budget_manager.activate_tool("minerva_tool_search", search_schema)


#region Module Lifecycle

func _init_modules() -> void:
	var annotation_tools := MCPAnnotationTools.new(self)
	_modules = [
		MCPChatTools.new(self),
		MCPNotesTools.new(self),
		MCPNoteEntryTools.new(self),
		MCPEditorTools.new(self),
		MCPSpreadsheetTools.new(self),
		MCPKanbanTools.new(self),
		MCPVideoTools.new(self),
		MCPAgentTools.new(self),
		MCPAutocoderTools.new(self),
		MCPModelTools.new(self),
		MCPGenerationTools.new(self),
		MCPSkillTools.new(self),
		MCPContainerTools.new(self),
		# MCPCodeTools removed (DCR 019e7b6609 P2.3): the file-primitive tools
		# (minerva_file_glob/grep, minerva_bash, minerva_cwd) now live in the
		# optional `codetools` marketplace plugin as minerva_codetools_*.
		MCPTerminalTools.new(self),
		MCPWebviewTools.new(self),
		MCPDocketTools.new(self),
		MCPHttpTools.new(self),
		annotation_tools,
		_MCPAnnotationReplyToolsScript.new(self, annotation_tools),
		MCPCadTools.new(self),
		# PCB panel surface — MCPPcbPanelTools.gd deleted (DCR 019f6c3d0e3d, C3
		# round docket 019f6c4604ba): every minerva_pcb_* tool is now
		# executor:"panel" in the pcb plugin's own manifest.json, dispatched
		# through PluginToolRegistry -> pcb/ui/panel_tools.gd. Minerva core is
		# no longer aware of PCB workflows at all.
		# T6 tail R6 (2026-05-12): MCPPresentationTools.gd deleted — every
		# minerva_presentation_* tool now lives in ~/github/plugins/presentation.
		MCPGeneralTools.new(self),
		MCPDocTools.new(self),
		MCPDiskTools.new(self),
		MCPDocumentTools.new(self),
		MCPOSTools.new(self),
		MCPPreferenceTools.new(self),
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
	if mcp_manager.http_server != null:
		mcp_manager.http_server.invalidate_tools_catalog("Minerva tool registered")


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
		tool_search_index.unregister_tool(tool_name)
	if mcp_manager.http_server != null:
		mcp_manager.http_server.invalidate_tools_catalog("Minerva tools unregistered")

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
func execute_tool(tool_name: String, arguments: Dictionary, caller_chat_id: String = "",
		context: ExecutionContext = null) -> Dictionary:
	if not server_enabled:
		return {"error": "Minerva server not connected", "success": false}
	if context == null:
		context = ExecutionContext.create("internal", caller_chat_id)
	var result: Dictionary = await context.run(_execute_tool_impl.bind(tool_name, arguments, context))
	if context.is_stopped():
		return result
	_maybe_capture_chat_knowledge(tool_name, result, context.caller_chat_id)
	return _check_duplicate_call(tool_name, arguments, result)


## HTTP deliberately does not require the internal connection to be enabled.
func execute_tool_for_http(tool_name: String, arguments: Dictionary, agent_id: String = "",
		context: ExecutionContext = null) -> Dictionary:
	var outcome = await execute_tool_for_http_outcome(tool_name, arguments, agent_id, context)
	return outcome.application


func execute_tool_for_http_outcome(tool_name: String, arguments: Dictionary, agent_id: String = "",
		context: ExecutionContext = null):
	if context == null:
		context = ExecutionContext.create("http", "", agent_id)
	var holder := {}
	var result: Dictionary = await context.run(
		_execute_tool_impl.bind(tool_name, arguments, context, holder, false))
	var outcome = holder.get("outcome")
	if outcome == null:
		outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	if context.is_stopped():
		# A completed plugin call can race a synchronous cancellation callback.
		# Keep its envelope for diagnostics, but never expose it as this request's
		# authoritative wire result after the request lifetime has ended.
		outcome.wire_authoritative = false
	else:
		var before_wrapper := result.duplicate(true)
		var wrapped := _check_duplicate_call(tool_name, arguments, result)
		if wrapped != before_wrapper:
			outcome.wire_authoritative = false
		result = wrapped
	outcome.application = result
	return outcome


## Nested native calls retain their explicit parent lifetime and identity.
## `write_binding`, when given, belongs to this one call only: a plugin tool
## hands it to its plugin's backend tool guard (DocketHost._guard holds a
## skill write to its target with it). Nothing it calls inherits it.
func call_tool(tool_name: String, arguments: Dictionary, context: ExecutionContext = null,
		write_binding: Dictionary = {}) -> Dictionary:
	if context == null:
		context = ExecutionContext.create("module")
	return await context.run(_execute_tool_impl.bind(tool_name, arguments, context, {}, true, write_binding))


## Internal tool execution — routes to modules, plugins, or tool search
func _execute_tool_impl(tool_name: String, arguments: Dictionary, context: ExecutionContext = null,
		outcome_holder: Dictionary = {}, coerce_arguments := true, write_binding: Dictionary = {}) -> Dictionary:
	if context == null:
		context = ExecutionContext.create("module")
	if context.is_stopped():
		return context.stopped_result()
	print("[MinervaMCPServer] Executing: %s" % tool_name)

	# Policy override tool — handled before policy check so it can't be blocked
	if tool_name == "minerva_policy_override":
		return await _handle_policy_override(arguments)

	# Policy reload tool — handled before policy check
	if tool_name == "minerva_policy_reload":
		policy_engine.reload()
		var unread := await policy_engine.refresh()
		if not unread.is_empty():
			return {"success": false, "error": "Policy unavailable: %s" % unread,
				"error_code": "policy_unavailable"}
		return {"success": true, "rules_loaded": policy_engine.rule_count()}

	# PRE-TOOL POLICY CHECK — before tool_budget_manager and advisory hooks
	var policy_result: Dictionary = {}
	var injected_knowledge: Array = []
	if policy_engine:
		policy_result = await policy_engine.admit(tool_name, arguments, context.caller_chat_id)
		if context.is_stopped():
			return context.stopped_result()
		if not policy_result["allowed"]:
			# Pre-activate tools the agent needs to comply with the policy
			_activate_policy_tools(policy_result, context.caller_chat_id)
			SingletonObject.emit_mcp_tool_blocked(tool_name, arguments, policy_result, context.agent_id)
			return policy_result
		# Observation telemetry is best effort and never waits: written for an
		# admitted call whether or not it is then made.
		_write_observation_telemetry(policy_result.get("observations", []))
		# The knowledge the call's rules inject is read before the call is made:
		# a call whose knowledge cannot be read is not made.
		var knowledge := await _resolve_policy_injections(policy_result.get("injections", []))
		if context.is_stopped():
			return context.stopped_result()
		if knowledge.has("error"):
			SingletonObject.emit_mcp_tool_blocked(tool_name, arguments, knowledge, context.agent_id)
			return knowledge
		injected_knowledge = knowledge.knowledge

	# Track tool usage for LRU (blocked calls don't count)
	tool_budget_manager.mark_used(tool_name)

	# Emit pre-execution signal for hook triggers (PreToolUse)
	if arguments is Dictionary and SingletonObject.trigger_manager and not SingletonObject.trigger_manager.triggers.is_empty():
		SingletonObject.emit_mcp_tool_about_to_execute(tool_name, arguments)

	# Coerce argument types to match declared schema (LLMs send arrays/objects as JSON strings)
	if coerce_arguments and arguments is Dictionary:
		var schema_for_coerce: Dictionary = {}
		if tool_budget_manager.is_active(tool_name):
			var tool_info := tool_budget_manager.try_call(tool_name)
			schema_for_coerce = tool_info.get("schema", {})
		elif tool_search_index:
			var search_hits: Array[Dictionary] = tool_search_index.search(tool_name, "", 1)
			if not search_hits.is_empty() and search_hits[0].get("name", "") == tool_name:
				schema_for_coerce = search_hits[0].get("schema", {})
		if not schema_for_coerce.is_empty():
			arguments = MCPToolUtils.coerce_args_to_schema(arguments, schema_for_coerce)

	if context.is_stopped():
		return context.stopped_result()

	# Dispatch to the appropriate handler and collect the result
	var dispatch_result: Dictionary = {}
	var dispatched := false

	# Tool search (always available, handled here to avoid module overhead)
	if tool_name == "minerva_tool_search":
		dispatch_result = _tool_search(arguments)
		dispatched = true

	# Tool memory search — retrieval from the calling chat's ToolMemoryManager recovery index
	if not dispatched and tool_name == "minerva_tool_memory_search":
		if not _tool_memory_optimization_enabled():
			return {"error": "Tool memory optimization is disabled", "success": false}
		var history = MCPToolUtils.find_chat_by_id(context.caller_chat_id)
		if history and history is ChatHistory and history.tool_memory_manager:
			dispatch_result = history.tool_memory_manager.handle_recall(arguments)
		else:
			dispatch_result = {"error": "No active chat with tool memory manager"}
		dispatched = true

	# Route to domain modules
	if not dispatched:
		for module in _modules:
			if module.can_handle(tool_name):
				if module.has_method("handle_with_context"):
					dispatch_result = await module.handle_with_context(tool_name, arguments, context)
				else:
					dispatch_result = await module.handle(tool_name, arguments)
				dispatched = true
				break

	# Plugin-contributed tools (minerva_<plugin_id>_*) — check first since
	# is_plugin_tool() is an exact-match lookup and avoids prefix collisions.
	if not dispatched and SingletonObject.plugin_tool_registry != null and SingletonObject.plugin_tool_registry.is_plugin_tool(tool_name):
		var plugin_outcome
		if write_binding.is_empty():
			plugin_outcome = await SingletonObject.plugin_tool_registry.handle_tool_call_outcome(
				tool_name, arguments, context)
		else:
			plugin_outcome = await SingletonObject.plugin_tool_registry.handle_tool_call_outcome(
				tool_name, arguments, context, write_binding)
		outcome_holder["outcome"] = plugin_outcome
		dispatch_result = plugin_outcome.application
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

	if context.is_stopped():
		return context.stopped_result()

	# POST-DISPATCH: a call that succeeded activates the scopes its rules
	# staged and carries the knowledge they injected.
	if policy_engine and policy_call_succeeded(dispatch_result):
		policy_engine.commit_scopes(policy_result)
		if not injected_knowledge.is_empty():
			dispatch_result["_injected_knowledge"] = injected_knowledge
			if outcome_holder.has("outcome"):
				outcome_holder.outcome.wire_authoritative = false

	return dispatch_result


## Whether a governed call's `result` is a success, for the scopes its policy
## rules staged (PolicyEngine.commit_scopes).
static func policy_call_succeeded(result: Dictionary) -> bool:
	return result.get("success", not result.has("error")) != false


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


func _check_duplicate_call(tool_name: String, arguments: Dictionary, result: Dictionary) -> Dictionary:
	return _loop_tracker.check(tool_name, arguments, result)

#endregion


#region Tool Search

func _register_tool_search() -> void:
	_register_tool("minerva_tool_search",
		"This server has 170+ tools available, plus tools from installed plugins and connected external MCP servers. Only minerva_tool_search is loaded by default to save tokens. Search by keyword to discover and activate tools. Activated tools can be called directly in subsequent turns. Common categories: files (read/write/edit/glob/grep), bash, terminal (read/write/wait/list), chat (send/list/create), notes, spreadsheet (create/format/chart), webview (create/update HTML panels), graphics, video, agents, automation, models, costs. Plugin-contributed categories and connected external servers (e.g., docket, nudge, cobrowser) are searchable by name. Example: tool_search(query='edit file') or tool_search(query='docket') or tool_search(query='webview panel').",
		{"type": "object", "properties": {
			"query": {"type": "string", "description": "Keyword search (e.g., 'edit file', 'docket create', 'cost summary') or exact tool name (e.g., 'minerva_doc_edit')"},
			"category": {"type": "string", "description": "Filter by a built-in or plugin-contributed category. External server names (e.g., docket, nudge) also work as categories."},
			"limit": {"type": "integer", "description": "Max results (default 5)"},
		}, "required": ["query"]}, "meta")

	_register_tool("minerva_tool_memory_search",
		"Search or retrieve archived tool results from earlier in this conversation. Two modes: (1) Search: pass 'query' to filter by tool name or description, returns compact index entries. (2) Retrieve: pass 'note_id' to get full archived result content. Use when the floating summary lacks detail you need.",
		{"type": "object", "properties": {
			"query": {"type": "string", "description": "Filter archived results by tool name or keyword"},
			"note_id": {"type": "string", "description": "Retrieve full content of a specific archived result by its note ID"},
			"limit": {"type": "integer", "description": "Max results to return in search mode (default: 10)"},
		}, "required": []}, "meta")


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
		if not _tool_memory_optimization_enabled() and TOOL_MEMORY_HYDRATION_TOOLS.has(name):
			continue
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
	var requested_schemas: Array[Dictionary] = []

	for i in range(filtered.size()):
		var result: Dictionary = filtered[i]
		var name: String = result.get("name", "")

		if i < limit:
			var schema: Dictionary = result.get("schema", {})
			if not name.is_empty() and not schema.is_empty():
				requested_schemas.append(schema)
		else:
			also_available.append(name)
	var admission := tool_budget_manager.activate_group(requested_schemas)
	activated.assign(admission.get("activated", []))
	var unavailable: Array[String] = []
	for rejected: Dictionary in admission.get("rejected", []):
		unavailable.append(str(rejected.get("name", "")))

	var message: String
	if not unavailable.is_empty():
		message = "%d tools activated. %d could not fit the active tool budget." % [
			activated.size(), unavailable.size()]
	elif filtered.size() <= limit:
		message = "%d tools activated and ready to call." % activated.size()
	else:
		message = "%d tools activated. %d more available — search by exact name to activate." % [activated.size(), also_available.size()]

	var result_dict: Dictionary = {
		"success": true,
		"activated": activated,
		"message": message,
	}
	if not unavailable.is_empty():
		result_dict["unavailable"] = unavailable
		result_dict["activation_failures"] = admission.get("rejected", [])
	if not (admission.get("evicted", []) as Array).is_empty():
		result_dict["evicted"] = admission.get("evicted", [])
	# Only include overflow list if small enough to be useful; omit when too large
	if not also_available.is_empty() and also_available.size() <= 20:
		result_dict["also_available"] = also_available
	elif not also_available.is_empty():
		result_dict["remaining_count"] = also_available.size()
	return result_dict


func _tool_memory_optimization_enabled() -> bool:
	if SingletonObject == null or SingletonObject.config_file == null:
		return false
	return bool(SingletonObject.config_file.get_value("ToolMemoryManager", "enabled", false))

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
## Best effort: a failure never breaks tool dispatch (through the Docket
## plugin it is logged).
## Goes through DocketManager.call_tool() directly (not MCP dispatch) to avoid
## recursion back into the policy engine.
func _write_observation_telemetry(observations: Array) -> void:
	var dm = SingletonObject.docket_manager if SingletonObject else null
	var host = SingletonObject.get("docket_host") if SingletonObject else null
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
		# Best-effort write — never disrupts the tool call path.
		if dm != null:
			dm.call_tool("docket_comment", {
				"action": "add",
				"item_id": rule_id,
				"author": "policy-engine",
				"text": comment_text,
			})
		elif host != null:
			_write_observation_through(host, rule_id, comment_text)


# Writes one observation through the Docket plugin's host, not awaited by
# the call it observes; a write that fails is logged with its rule and cause.
func _write_observation_through(host, rule_id: String, text: String) -> void:
	var failed: String = await host.write_policy_observation(rule_id, text)
	if not failed.is_empty():
		push_warning("[MinervaMCPServer] the observation for policy %s could not be written: %s" % [rule_id, failed])


## Activates the tools a policy block response names, so the agent can
## comply: minerva_docket_get when the rule names knowledge, and registered
## tools named in its alternatives, as a workflow of the calling chat
## (MCPManager.activate_tools_for_workflow). The result says what the agent
## still cannot call: knowledge_unavailable for minerva_docket_get when the
## rule names knowledge, and unavailable_tools ({name, reason}) otherwise.
func _activate_policy_tools(policy_result: Dictionary, caller_chat_id: String) -> void:
	var knowledge_ref: String = str(policy_result.get("knowledge_ref", ""))
	var names: Array[String] = []
	if not knowledge_ref.is_empty():
		names.append("minerva_docket_get")
	var re := RegEx.new()
	re.compile(r"\b([a-z][a-z0-9]*_[a-z0-9_]+)\b")
	for alt in policy_result.get("allowed_next_actions", []):
		for m in re.search_all(str(alt)):
			var tool_name: String = m.get_string(1)
			if mcp_manager.tool_registry.has(tool_name) and not tool_name in names:
				names.append(tool_name)
	if names.is_empty():
		return

	var activation: Dictionary = mcp_manager.activate_tools_for_workflow(
		names, MCPToolUtils.find_chat_by_id(caller_chat_id))
	var unavailable: Array = []
	for entry: Dictionary in activation.unavailable:
		if entry.name == "minerva_docket_get" and not knowledge_ref.is_empty():
			policy_result["knowledge_unavailable"] = "minerva_docket_get cannot be called now (%s), so the knowledge this rule names (%s) cannot be read" % [
				entry.reason, knowledge_ref]
			push_warning("[MinervaMCPServer] %s" % policy_result.knowledge_unavailable)
		else:
			unavailable.append(entry)
	if not unavailable.is_empty():
		policy_result["unavailable_tools"] = unavailable


## The knowledge a call's inject rules name (the injections array from
## PolicyEngine.admit(); knowledge_ref may list several item ids, comma
## separated), read before the call is made: {knowledge: [compact entries]},
## or, when an item cannot be read, a refusal naming the rule, the item and
## why (error_code "policy_knowledge_unavailable"). Read from the embedded
## Docket when it exists, else through the Docket plugin's host.
func _resolve_policy_injections(injections: Array) -> Dictionary:
	var wanted: Array = []  # [rule_id, item id], in order
	for injection in injections:
		for ref_id in str(injection.get("knowledge_ref", "")).split(",", false):
			if not ref_id.strip_edges().is_empty():
				wanted.append([str(injection.get("rule_id", "")), ref_id.strip_edges()])
	if wanted.is_empty():
		return {"knowledge": []}
	var items: Array = []
	var dm = SingletonObject.docket_manager if SingletonObject else null
	var host = SingletonObject.get("docket_host") if SingletonObject else null
	if dm != null:
		for pair in wanted:
			var item_result: Dictionary = dm.call_tool("docket_get", {"id": pair[1]})
			if item_result.has("error"):
				return _knowledge_refusal(pair[0], pair[1], str(item_result.error))
			items.append(item_result)
	elif host != null:
		var refs := PackedStringArray()
		for pair in wanted:
			refs.append(pair[1])
		var read: Dictionary = await host.policy_knowledge(refs)
		if read.has("error"):
			var index := int(read.get("index", -1))
			if index < 0:
				return _knowledge_refusal("", _pair_ids(wanted), str(read.error))
			return _knowledge_refusal(wanted[index][0], wanted[index][1], str(read.error))
		items = read.items
	else:
		return _knowledge_refusal("", _pair_ids(wanted), "no Docket owns Minerva's projects")

	var resolved: Array = []
	for index in wanted.size():
		var item_result: Dictionary = items[index]
		var item_type: String = str(item_result.get("type", ""))
		var entry := {
			"id": wanted[index][1],
			"type": item_type,
			"title": str(item_result.get("title", "")),
			"from_rule": wanted[index][0],
		}
		match item_type:
			"hint":
				entry["value"] = str(item_result.get("value", ""))
			"insight":
				entry["assumed"] = str(item_result.get("assumed", ""))
				entry["corrected"] = str(item_result.get("corrected", ""))
			"kb":
				entry["summary"] = str(item_result.get("summary", ""))
				if entry["summary"].is_empty():
					entry["article"] = str(item_result.get("article", "")).left(500)
			_:
				entry["description"] = str(item_result.get("description", "")).left(500)
		resolved.append(entry)
	return {"knowledge": resolved}


static func _pair_ids(wanted: Array) -> String:
	var ids := PackedStringArray()
	for pair in wanted:
		ids.append(pair[1])
	return ", ".join(ids)


# The refusal of a call whose policy knowledge could not be read.
static func _knowledge_refusal(rule_id: String, refs: String, why: String) -> Dictionary:
	return {
		"allowed": false,
		"effect": "unavailable",
		"blocked_by_rule": rule_id,
		"reason": why,
		"allowed_next_actions": [],
		"success": false,
		"error": "Policy knowledge %s%s could not be read, so the call was not made: %s"
			% [refs, (" (rule %s)" % rule_id) if not rule_id.is_empty() else "", why],
		"error_code": "policy_knowledge_unavailable",
	}

#endregion
