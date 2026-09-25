class_name MCPManager
extends Node

const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
## Central manager for MCP (Model Context Protocol) server connections.
## Handles server registration, tool discovery, and tool execution.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const MCPServerConnectionScript := preload("res://Scripts/Services/MCP/MCPServerConnection.gd")
const MCPConfigScript := preload("res://Scripts/Services/MCP/MCPConfig.gd")
const MCPProfileScript := preload("res://Scripts/Services/MCP/MCPProfile.gd")
const ToolSchemaRuntime := preload("res://Scripts/Services/MCP/MCPToolSchemaRuntime.gd")
const MinervaMCPServerScript := preload("res://Scripts/Services/MCP/MinervaMCPServer.gd")
const MinervaMCPHttpServerScript := preload("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd")

signal server_connected(server_name: String)
signal server_disconnected(server_name: String)
signal server_error(server_name: String, error: String)
signal tool_executed(server_name: String, tool_name: String, result: Dictionary)
signal tool_outcome_executed(server_name: String, tool_name: String, outcome)
signal tools_refreshed()

## Connected server instances
var servers: Dictionary = {}  # server_name -> MCPServerConnection
var _connecting_servers: Dictionary = {}
var _connection_diagnostics: Dictionary = {}
var _next_connection_attempt := 0

## Registry of all available tools across all servers
var tool_registry: Dictionary = {}  # tool_name -> MCPToolDefinition
var _tool_connection_owners: Dictionary = {}

## Configuration for MCP servers
var config = null

## Internal Minerva MCP server for controlling Minerva features
var minerva_server: MinervaMCPServerScript = null

## HTTP server for exposing Minerva tools to external agents
var http_server: MinervaMCPHttpServerScript = null


func _ready() -> void:
	SingletonObject.verbose_log("[MCP] MCPManager._ready() called")
	config = MCPConfigScript.new()
	config.load_config()

	# Initialize the internal Minerva server (but don't connect it yet)
	minerva_server = MinervaMCPServerScript.new(self)

	SingletonObject.verbose_log("[MCP] After _ready(), tool_registry has %d tools" % tool_registry.size())


func _exit_tree() -> void:
	# Clean up all connections when the app exits
	SingletonObject.verbose_log("[MCP] Cleaning up connections on exit...")
	disconnect_all()
	SingletonObject.verbose_log("[MCP] Connections cleaned up")


## Initialize and connect to configured servers
func initialize() -> void:
	var auto_connect_servers = config.get_auto_connect_servers()
	for server_config in auto_connect_servers:
		var err: Error = await connect_server(server_config.name)
		if err == OK:
			SingletonObject.verbose_log("MCP: Connected to %s (%s)" % [server_config.name, server_config.type])
		else:
			push_warning("MCP: Failed to connect to %s: %s" % [server_config.name, error_string(err)])


## Connect to a server by name
func connect_server(server_name: String) -> Error:
	var server_config = config.get_server(server_name)
	if not server_config:
		push_error("Unknown MCP server: %s" % server_name)
		return ERR_DOES_NOT_EXIST

	if servers.has(server_name):
		# Already connected
		return OK
	if _connecting_servers.has(server_name):
		return ERR_BUSY

	var transport = MCPConfigScript.transport_type_from_string(server_config.type)
	_next_connection_attempt += 1
	var attempt := _next_connection_attempt
	_connection_diagnostics[server_name] = {"state": "connecting",
		"transport": server_config.type, "failure": "", "attempt": attempt,
		"config_key": _server_config_key(server_config)}
	var connection = MCPServerConnectionScript.new(
		server_name,
		server_config.url,
		transport
	)

	# Configure STDIO transport if applicable
	if transport == MCPServerConnectionScript.TransportType.STDIO:
		connection.configure_stdio(server_config.command, server_config.args)

	# Skip MCP init for REST APIs that don't support it
	connection.skip_mcp_init = server_config.skip_mcp_init

	# Set MCP endpoint path (some servers use "/" instead of "/mcp")
	connection.mcp_endpoint = server_config.mcp_endpoint

	# Set working directory if configured (for codetools)
	if not server_config.working_directory.is_empty():
		connection.working_directory = server_config.working_directory

	# Connect signals
	connection.disconnected.connect(_on_server_disconnected.bind(server_name, connection))
	connection.tools_list_changed.connect(_on_tools_list_changed.bind(server_name, connection))
	connection.catalog_committed.connect(_on_catalog_committed.bind(server_name, connection))
	_connecting_servers[server_name] = connection

	var err: Error = await connection.connect_to_server()
	if _connecting_servers.get(server_name) != connection:
		connection.disconnect_from_server()
		return ERR_BUSY
	if err != OK:
		_connecting_servers.erase(server_name)
		var msg := "Failed to connect to %s: %s" % [server_name, error_string(err)]
		var failure_reason: String = connection.last_failure_reason
		if failure_reason.is_empty():
			failure_reason = "Transport unavailable (%s). Check the server configuration." % error_string(err)
		_record_connection_failure(server_name, server_config.type, failure_reason, attempt,
			_server_config_key(server_config))
		push_error("[MCP] " + msg)
		server_error.emit(server_name, msg)
		SingletonObject.create_toast_notification(msg, ToastNotification.Type.ERROR)
		return err

	# Refresh tools — rollback connection if this fails
	var refresh_err := await connection.refresh_tools()
	if _connecting_servers.get(server_name) != connection:
		connection.disconnect_from_server()
		return ERR_BUSY
	if refresh_err is int and refresh_err != OK:
		_connecting_servers.erase(server_name)
		push_warning("[MCP] Tool refresh failed for %s, rolling back connection" % server_name)
		connection.disconnect_from_server()
		var msg := "%s connected but tool discovery failed — disconnected" % server_name
		var discovery_reason: String = connection.last_failure_reason
		if discovery_reason.is_empty():
			discovery_reason = "Tool discovery failed. Check server compatibility."
		_record_connection_failure(server_name, server_config.type, discovery_reason, attempt,
			_server_config_key(server_config))
		server_error.emit(server_name, msg)
		SingletonObject.create_toast_notification(msg, ToastNotification.Type.ERROR)
		return ERR_CANT_ACQUIRE_RESOURCE

	servers[server_name] = connection
	var connected_state := _connected_diagnostic(server_config.type, connection)
	connected_state["attempt"] = attempt
	connected_state["config_key"] = _server_config_key(server_config)
	_connection_diagnostics[server_name] = connected_state
	_connecting_servers.erase(server_name)
	_replace_server_tools(connection)
	connection.start_tool_catalog_watch()

	# Debug: Log registered tools
	SingletonObject.verbose_log("[MCP] Registered %d tools from %s:" % [connection.tools.size(), server_name])
	for tool in connection.tools:
		SingletonObject.verbose_log("[MCP]   - %s" % tool.name)

	server_connected.emit(server_name)
	return OK


## Disconnect from a server
func disconnect_server(server_name: String) -> void:
	var connection = servers.get(server_name, _connecting_servers.get(server_name))
	if connection == null:
		return
	_connecting_servers.erase(server_name)
	if servers.get(server_name) == connection:
		servers.erase(server_name)
	var previous: Dictionary = _connection_diagnostics.get(server_name, {})
	_connection_diagnostics[server_name] = {"state": "disconnected",
		"transport": previous.get("transport", ""), "failure": "",
		"config_key": previous.get("config_key", "")}
	_unregister_server_tools(server_name, connection)
	connection.disconnect_from_server()
	server_disconnected.emit(server_name)


func get_server_diagnostic(server_name: String, transport: String = "") -> Dictionary:
	var diagnostic: Dictionary = _connection_diagnostics.get(server_name, {})
	var current_config = config.get_server(server_name) if config else null
	if diagnostic.is_empty() or (not transport.is_empty() and diagnostic.get("transport") != transport) \
			or (current_config and diagnostic.get("config_key") != _server_config_key(current_config)):
		return {"state": "disconnected", "transport": transport, "failure": ""}
	return diagnostic.duplicate(true)


func _record_connection_failure(server_name: String, transport: String, reason: String,
		attempt: int = -1, config_key: String = "") -> void:
	if attempt >= 0 and _connection_diagnostics.get(server_name, {}).get("attempt") != attempt:
		return
	_connection_diagnostics[server_name] = {"state": "failed", "transport": transport,
		"failure": reason, "attempt": attempt, "config_key": config_key}


func _server_config_key(server_config) -> String:
	return JSON.stringify({"type": server_config.type, "url": server_config.url,
		"command": server_config.command, "args": server_config.args,
		"endpoint": server_config.mcp_endpoint, "working_directory": server_config.working_directory,
		"skip_mcp_init": server_config.skip_mcp_init}).sha256_text()


func _connected_diagnostic(transport: String, connection) -> Dictionary:
	var era := "custom"
	var version := ""
	if connection.protocol_profile.era == MCPProfileScript.Era.MODERN_2026_07_28:
		era = "modern"
		version = connection.protocol_profile.protocol_version
	elif connection.protocol_profile.era == MCPProfileScript.Era.INITIALIZED_LEGACY:
		era = "legacy"
		version = connection.protocol_profile.protocol_version
	return {"state": "connected", "transport": transport, "era": era,
		"version": version, "failure": ""}


## Disconnect from all servers
func disconnect_all() -> void:
	var names: Array = servers.keys()
	for server_name in _connecting_servers.keys():
		if server_name not in names:
			names.append(server_name)
	for server_name in names:
		disconnect_server(server_name)

	# Also disconnect the Minerva server
	if minerva_server and minerva_server.server_enabled:
		disconnect_minerva_server()


## Connect the internal Minerva server (enables LLM control of Minerva features)
func connect_minerva_server() -> Error:
	if not minerva_server:
		minerva_server = MinervaMCPServerScript.new(self)

	minerva_server.connect_server()
	server_connected.emit("minerva")
	return OK


## Disconnect the internal Minerva server
func disconnect_minerva_server() -> void:
	if minerva_server:
		minerva_server.disconnect_server()
		server_disconnected.emit("minerva")


## Check if the Minerva server is connected
func is_minerva_connected() -> bool:
	return minerva_server != null and minerva_server.server_enabled


## Keep an explicitly advertised recovery path callable in automatic-tool
## mode. The result is suitable for returning to the model when budget,
## connectivity, or per-chat settings make part of that path unavailable.
func activate_tools_for_workflow(tool_names: Array[String], history = null) -> Dictionary:
	var schemas: Array[Dictionary] = []
	var unavailable: Array[Dictionary] = []
	var directly_available: Array[String] = []
	var effective_tool_sets := _effective_tool_sets_for_history(history)
	var static_tool_mode: bool = history != null and "StaticToolMode" in history \
		and bool(history.StaticToolMode)
	for tool_name: String in tool_names:
		var unavailable_reason := _tool_unavailable_reason(
			tool_name, history, effective_tool_sets)
		if not unavailable_reason.is_empty():
			unavailable.append({"name": tool_name, "reason": unavailable_reason})
			continue
		if static_tool_mode or minerva_server == null \
				or not minerva_server.auto_tool_management:
			directly_available.append(tool_name)
			continue
		var hits: Array[Dictionary] = minerva_server.tool_search_index.search(tool_name, "", 1)
		if hits.is_empty() or str(hits[0].get("name", "")) != tool_name \
				or (hits[0].get("schema", {}) as Dictionary).is_empty():
			unavailable.append({"name": tool_name, "reason": "tool schema is unavailable"})
			continue
		schemas.append(hits[0].schema)

	var admission := {"activated": directly_available, "rejected": []}
	if not static_tool_mode and minerva_server != null \
			and minerva_server.auto_tool_management:
		admission = minerva_server.tool_budget_manager.activate_group(schemas)
	for rejected: Dictionary in admission.get("rejected", []):
		unavailable.append(rejected)
	return {"activated": admission.get("activated", []), "unavailable": unavailable,
		"available": unavailable.is_empty()}


## Start the HTTP server to expose Minerva tools to external agents
func start_http_server(port: int = 9315) -> Error:
	if http_server == null:
		http_server = MinervaMCPHttpServerScript.new()
		add_child(http_server)

	return http_server.start_server(port)


## Stop the HTTP server
func stop_http_server() -> void:
	if http_server:
		http_server.stop_server()


## Check if the HTTP server is running
func is_http_server_running() -> bool:
	return http_server != null and http_server.is_running()


## Get the port the HTTP server is running on
func get_http_server_port() -> int:
	return http_server.get_port() if http_server else 0


## Validate a server config before adding. Returns empty string if valid, error message otherwise.
func validate_server_config(server_config) -> String:
	if server_config.name.is_empty():
		return "Server name is required."
	if server_config.name.begins_with("minerva"):
		return "Server names starting with 'minerva' are reserved."
	if MCPKnownServers.is_known(server_config.name):
		return "'%s' conflicts with a known server name." % server_config.name
	if server_config.type == "stdio":
		if server_config.command.is_empty():
			return "STDIO servers require a command."
	else:
		if server_config.url.is_empty():
			return "Server URL is required."
		if server_config.type == "http":
			if not server_config.url.begins_with("http://") and not server_config.url.begins_with("https://"):
				return "HTTP server URL must start with http:// or https://"
		elif server_config.type == "websocket":
			if not server_config.url.begins_with("ws://") and not server_config.url.begins_with("wss://"):
				return "WebSocket server URL must start with ws:// or wss://"
	return ""


## Add a server at runtime — validates, adds to config, optionally connects, saves if persistent
func add_server_at_runtime(server_config, connect_now: bool = true) -> Error:
	var validation_error := validate_server_config(server_config)
	if not validation_error.is_empty():
		push_error("[MCP] " + validation_error)
		SingletonObject.create_toast_notification(validation_error, ToastNotification.Type.ERROR)
		return ERR_INVALID_PARAMETER

	# Warn about duplicate name (existing config will be overwritten)
	if config.get_server(server_config.name):
		push_warning("[MCP] Overwriting existing server config: %s" % server_config.name)
		disconnect_server(server_config.name)
		_connection_diagnostics.erase(server_config.name)

	config.set_server(server_config)

	if server_config.persistent:
		config.save_config()

	if connect_now:
		var err: Error = await connect_server(server_config.name)
		return err

	return OK


## Remove a server at runtime — disconnects, removes from config, saves
func remove_server_at_runtime(server_name: String) -> void:
	var server_config = config.get_server(server_name)
	if not server_config:
		return

	# Don't allow removing known/builtin servers
	if server_config.origin in ["known", "builtin"]:
		push_warning("[MCP] Cannot remove %s server: %s" % [server_config.origin, server_name])
		return

	disconnect_server(server_name)
	_connection_diagnostics.erase(server_name)
	config.remove_server(server_name)
	config.save_config()


## Get tools filtered for a specific chat history.
## Applies 4-layer filter: profile tool_sets → per-chat profile override → DisabledTools → connectivity.
func get_tools_for_chat(history, format: String = "anthropic") -> Array[Dictionary]:
	var effective_tool_sets := _effective_tool_sets_for_history(history)

	# Build full filtered tool list (all 4 layers)
	var all_filtered: Array[Dictionary] = []
	for tool_name in tool_registry:
		if not _tool_unavailable_reason(tool_name, history,
				effective_tool_sets).is_empty():
			continue
		var tool = tool_registry[tool_name]

		var tool_dict: Dictionary
		if format == "anthropic":
			tool_dict = tool.to_anthropic_format()
		else:
			tool_dict = tool.to_openai_format()

		all_filtered.append(tool_dict)

	# Static tool mode: worker has a pre-locked tool set — skip auto_tool_management entirely
	if "StaticToolMode" in history and history.StaticToolMode:
		return all_filtered

	# Auto tool management: return only tool_search with dynamic description
	if minerva_server and minerva_server.auto_tool_management:
		minerva_server.tool_budget_manager.advance_turn()

		# Collect categories from filtered tools for the dynamic description
		var categories: Dictionary = {}
		for tool_dict in all_filtered:
			var tool_name: String = tool_dict.get("name", "")
			if tool_registry.has(tool_name):
				var ts: String = tool_registry[tool_name].tool_set
				if not ts.is_empty():
					categories[ts] = categories.get(ts, 0) + 1

		var cat_list: String = ", ".join(categories.keys()) if not categories.is_empty() else "various"

		# Build tool_search with dynamic description
		var search_desc := "This server has %d tools available (after filtering). Search to discover and activate. Categories: %s. Example: tool_search(query='edit file'). Activated tools can be called directly." % [all_filtered.size(), cat_list]
		var search_schema: Dictionary
		if format == "anthropic":
			search_schema = {
				"name": "minerva_tool_search",
				"description": search_desc,
				"input_schema": {
					"type": "object",
					"properties": {
						"query": {"type": "string", "description": "Keyword search or exact tool name"},
						"category": {"type": "string", "description": "Filter by category: %s" % cat_list},
						"limit": {"type": "integer", "description": "Max results (default 5)"},
					},
					"required": ["query"]
				}
			}
		else:
			search_schema = {
				"type": "function",
				"function": {
					"name": "minerva_tool_search",
					"description": search_desc,
					"parameters": {
						"type": "object",
						"properties": {
							"query": {"type": "string", "description": "Keyword search or exact tool name"},
							"category": {"type": "string", "description": "Filter by category: %s" % cat_list},
							"limit": {"type": "integer", "description": "Max results (default 5)"},
						},
						"required": ["query"]
					}
				}
			}

		# Return tool_search + any already-activated tools from budget manager
		var result: Array[Dictionary] = [search_schema]
		for active_schema in minerva_server.tool_budget_manager.get_active_schemas():
			var active_name: String = active_schema.get("name", "")
			if active_name == "minerva_tool_search":
				continue  # already added
			# Verify this tool is in the filtered set
			var in_filtered := false
			for f in all_filtered:
				if f.get("name", "") == active_name:
					in_filtered = true
					break
			if in_filtered:
				result.append(active_schema)
		return result

	return all_filtered


func _effective_tool_sets_for_history(history) -> Array[String]:
	var effective_tool_sets: Array[String] = []
	if history == null:
		return effective_tool_sets
	var skill_manager = SingletonObject.get_skill_manager()
	if skill_manager:
		var chat_skills: Array[String] = []
		var agent_skills: Array[String] = []
		if "ActiveSkills" in history and not history.ActiveSkills.is_empty():
			chat_skills = history.ActiveSkills
		if "AgentDefinitionId" in history and not history.AgentDefinitionId.is_empty():
			var agent_def = _find_agent_def(history.AgentDefinitionId)
			if agent_def and not agent_def.skills.is_empty():
				agent_skills = agent_def.skills
		effective_tool_sets = skill_manager.get_effective_tool_sets(chat_skills, agent_skills)
	return effective_tool_sets


func _tool_unavailable_reason(tool_name: String, history,
		effective_tool_sets: Array[String]) -> String:
	if not tool_registry.has(tool_name):
		return "tool is not registered"
	var tool = tool_registry[tool_name]
	var connected := is_minerva_connected() if tool.server_name == "minerva" \
		else is_server_connected(tool.server_name)
	if not connected:
		return "tool server is disconnected"
	if not _passes_tool_set_filter(tool, effective_tool_sets):
		return "tool is excluded by this chat's active tool sets"
	if history != null and "DisabledTools" in history and tool_name in history.DisabledTools:
		return "tool is disabled for this chat"
	return ""


## Check if a tool passes the tool_set filter.
## External tools and meta tools always pass.
func _passes_tool_set_filter(tool, effective_tool_sets: Array[String]) -> bool:
	# External (non-minerva) tools always pass
	if tool.server_name != "minerva":
		return true
	# Meta tools always pass
	if tool.tool_set == "meta" or tool.tool_set.is_empty():
		return true
	# If no filter active (empty = all), pass
	if effective_tool_sets.is_empty():
		return _is_tool_in_enabled_set(tool)
	# Check against effective profile tool_sets
	return tool.tool_set in effective_tool_sets


## Find an AgentDefinition by ID
func _find_agent_def(agent_id: String):
	if not SingletonObject.agent_registry:
		return null
	for agent_def in SingletonObject.agent_registry.agents:
		if agent_def.id == agent_id:
			return agent_def
	return null


## Execute a tool by name
func execute_tool(tool_name: String, arguments: Dictionary = {}, caller_chat_id: String = "",
		context: ExecutionContext = null) -> Dictionary:
	if context == null:
		context = ExecutionContext.create("internal", caller_chat_id)
	return await context.run(_execute_tool_with_context.bind(tool_name, arguments, context))


func _execute_tool_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	var caller_chat_id: String = context.caller_chat_id
	SingletonObject.verbose_log("[MCP] execute_tool called: %s" % tool_name)

	if not tool_registry.has(tool_name):
		SingletonObject.verbose_log("[MCP] Tool not found! Available tools: %s" % str(tool_registry.keys()))
		return {"error": "Tool not found: %s" % tool_name, "success": false}

	var tool = tool_registry[tool_name]
	var server_name = tool.server_name

	# Handle skill executable tools
	if tool_name.begins_with("skill_"):
		# Policy check for skill tools (same enforcement as all other tools)
		var skill_injections: Array = []
		if minerva_server and minerva_server.policy_engine:
			var policy_result: Dictionary = await minerva_server.policy_engine.admit(tool_name, arguments, caller_chat_id)
			if context.is_stopped():
				return context.stopped_result()
			if not policy_result["allowed"]:
				minerva_server._activate_policy_tools(policy_result)
				SingletonObject.emit_mcp_tool_blocked(tool_name, arguments, policy_result, caller_chat_id)
				return policy_result
			var pending_observations: Array = policy_result.get("observations", [])
			if not pending_observations.is_empty():
				minerva_server._write_observation_telemetry(pending_observations)
			skill_injections = policy_result.get("injections", [])

		var skill_id := tool_name.substr(6)  # Strip "skill_" prefix
		var skill_manager = SingletonObject.get_skill_manager()
		if skill_manager:
			var args_str: String = arguments.get("args", "")
			var skill_result = skill_manager.execute_skill_tool(skill_id, args_str)
			if not skill_result.has("success"):
				skill_result["success"] = not skill_result.has("error")
			if not skill_injections.is_empty() and minerva_server:
				var resolved := minerva_server._resolve_policy_injections(skill_injections)
				if not resolved.is_empty():
					skill_result["_injected_knowledge"] = resolved
			tool_executed.emit(server_name, tool_name, skill_result)
			return skill_result
		return {"error": "Skill manager not available", "success": false}

	# Handle internal Minerva server tools
	if server_name == "minerva":
		if not minerva_server or not minerva_server.server_enabled:
			return {"error": "Minerva server not connected", "success": false}

		var minerva_result = await minerva_server.execute_tool(tool_name, arguments, caller_chat_id, context)
		if context.is_stopped():
			return context.stopped_result()

		# Normalize result
		if not minerva_result.has("success"):
			minerva_result["success"] = not minerva_result.has("error")

		tool_executed.emit(server_name, tool_name, minerva_result)
		return minerva_result

	# Auto-inject cobrowser tab_id/agent_id for managed workers
	if tool_name.begins_with("cobrowser_") and not caller_chat_id.is_empty():
		var registry = SingletonObject.worker_registry
		if registry:
			var worker = registry.get_worker_by_chat(caller_chat_id)
			if worker:
				# Always inject agent_id if the worker has one (needed for tab_claim/tab_new)
				if not arguments.has("agent_id") or arguments.get("agent_id", "").is_empty():
					if not worker.cobrowser_agent_id.is_empty():
						arguments["agent_id"] = worker.cobrowser_agent_id
				# Only inject tab_id when the worker has been assigned one
				if worker.cobrowser_tab_id >= 0:
					if not arguments.has("tab_id") or arguments.get("tab_id") == null:
						arguments["tab_id"] = worker.cobrowser_tab_id

	# Normalize explicit cobrowser tab IDs before crossing the MCP boundary.
	# LLMs often echo tab IDs as strings ("69") or JSON floats (69.0), while
	# the browser bridge expects an integer tab identifier.
	if tool_name.begins_with("cobrowser_") and arguments.has("tab_id") and arguments.get("tab_id") != null:
		arguments["tab_id"] = MCPToolUtils.coerce_int(arguments.get("tab_id"), -1)

	# Handle external server tools
	if not servers.has(server_name):
		return {"error": "Server not connected: %s" % server_name, "success": false}

	# Policy evaluation for external tools — same enforcement as minerva tools
	var ext_injections: Array = []
	if minerva_server and minerva_server.policy_engine:
		var policy_result: Dictionary = await minerva_server.policy_engine.admit(tool_name, arguments, caller_chat_id)
		if context.is_stopped():
			return context.stopped_result()
		if not policy_result["allowed"]:
			# Pre-activate tools the agent needs to comply with the policy
			minerva_server._activate_policy_tools(policy_result)
			SingletonObject.emit_mcp_tool_blocked(tool_name, arguments, policy_result, caller_chat_id)
			return policy_result
		# Drain observation telemetry for external tools (internal tools do this in _execute_tool_impl)
		var pending_observations: Array = policy_result.get("observations", [])
		if not pending_observations.is_empty():
			minerva_server._write_observation_telemetry(pending_observations)
		ext_injections = policy_result.get("injections", [])
		if not servers.has(server_name):
			return {"error": "Server not connected: %s" % server_name, "success": false}

	var connection = servers[server_name]
	if _tool_connection_owners.get(tool_name) != connection:
		return {"error": "Tool catalog owner no longer matches the live server connection",
			"success": false}

	# Coerce argument types to match the tool's declared schema.
	# LLMs often send objects as JSON strings, integers as strings, etc.
	if tool != null:
		var native_input: Variant = tool.native_input_schema()
		if native_input is Dictionary:
			arguments = MCPToolUtils.coerce_args_to_schema(arguments, native_input)
		var input_check: Dictionary = await ToolSchemaRuntime.validate(
			tool.native_input_schema(), arguments)
		if servers.get(server_name) != connection:
			return {"error": "Server connection changed during input validation", "success": false}
		if context.is_stopped():
			return context.stopped_result()
		if not input_check.get("ok", false):
			return {"error": "Tool arguments do not match the native MCP schema",
				"error_code": str(input_check.get("error", {}).get("code", "invalid_arguments")),
				"success": false}

	if context.is_stopped():
		return context.stopped_result()
	var outcome = await connection.call_tool_outcome_with_context(tool_name, arguments, context)
	if context.is_stopped():
		return context.stopped_result()
	if servers.get(server_name) != connection:
		return {"error": "Server connection changed during tool execution", "success": false}
	var result: Dictionary = outcome.application
	if outcome.envelope != null and outcome.envelope.result_type == "complete" \
			and outcome.application.get("success", not outcome.application.has("error")) \
			and tool.original_definition.has("outputSchema"):
		if not outcome.envelope.original_result.has("structuredContent"):
			outcome.application = {"error":
				"Tool result omitted structuredContent required by outputSchema",
				"error_code": "invalid_result", "success": false}
		else:
			var output_check: Dictionary = await ToolSchemaRuntime.validate(
				tool.native_output_schema(),
				outcome.envelope.original_result.structuredContent)
			if servers.get(server_name) != connection:
				return {"error": "Server connection changed during output validation", "success": false}
			if context.is_stopped():
				return context.stopped_result()
			if not output_check.get("ok", false):
				outcome.application = {"error":
					"Tool structured result does not match its MCP outputSchema",
					"error_code": str(output_check.get("error", {}).get("code", "invalid_result")),
					"success": false}
	result = outcome.application

	# Normalize result
	if not result.has("success"):
		result["success"] = not result.has("error")

	# If tool execution failed with a connection error, clean up the dead connection
	if not result.get("success", false) and not connection.server_connected \
			and servers.get(server_name) == connection:
		push_warning("[MCP] Server %s disconnected during tool execution — cleaning up" % server_name)
		_unregister_server_tools(server_name, connection)
		servers.erase(server_name)
		server_disconnected.emit(server_name)

	# Resolve and append policy injections to external tool results
	if not ext_injections.is_empty() and minerva_server:
		var resolved := minerva_server._resolve_policy_injections(ext_injections)
		if not resolved.is_empty():
			result["_injected_knowledge"] = resolved

	tool_executed.emit(server_name, tool_name, result)
	tool_outcome_executed.emit(server_name, tool_name, outcome)
	return result


## Check if a tool passes the current tool set filter.
## Meta tools always pass. External (non-minerva) tools always pass.
## For minerva tools: if _enabled_tool_sets is empty, all pass;
## otherwise only tools whose tool_set is in the enabled list pass.
func _is_tool_in_enabled_set(tool) -> bool:
	if tool.server_name != "minerva":
		return true
	if tool.tool_set == "meta" or tool.tool_set.is_empty():
		return true
	if not minerva_server or minerva_server._enabled_tool_sets.is_empty():
		return true
	return tool.tool_set in minerva_server._enabled_tool_sets


## Get all available tools from all connected servers
func get_available_tools() -> Array:
	var tools: Array = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		var server_name = tool.server_name
		if server_name == "minerva":
			if is_minerva_connected() and _is_tool_in_enabled_set(tool):
				tools.append(tool)
		elif is_server_connected(server_name):
			tools.append(tool)
	return tools


## Get tools formatted for LLM function calling (OpenAI format)
func get_tools_for_openai() -> Array[Dictionary]:
	var tools: Array[Dictionary] = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		var server_name = tool.server_name
		var connected = (server_name == "minerva" and is_minerva_connected()) or is_server_connected(server_name)
		if connected and _is_tool_in_enabled_set(tool):
			tools.append(tool.to_openai_format())
	return tools


## Get tools formatted for Claude/Anthropic
func get_tools_for_anthropic() -> Array[Dictionary]:
	var tools: Array[Dictionary] = []
	SingletonObject.verbose_log("[MCP] get_tools_for_anthropic() checking %d tools in registry..." % tool_registry.size())
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		var server_name = tool.server_name
		var is_minerva = server_name == "minerva"
		var minerva_connected = is_minerva_connected() if is_minerva else false
		var external_connected = is_server_connected(server_name) if not is_minerva else false
		var connected = minerva_connected or external_connected
		if connected and _is_tool_in_enabled_set(tool):
			tools.append(tool.to_anthropic_format())
	SingletonObject.verbose_log("[MCP] get_tools_for_anthropic() returning %d tools (filtered from %d in registry)" % [tools.size(), tool_registry.size()])
	return tools


## Get a specific tool definition
func get_tool(tool_name: String):
	return tool_registry.get(tool_name)


## Check if a tool exists
func has_tool(tool_name: String) -> bool:
	return tool_registry.has(tool_name)


## Get tools from a specific server
func get_server_tools(server_name: String) -> Array:
	if not servers.has(server_name):
		return []

	var connection = servers[server_name]
	return connection.tools


## Check if a server is connected
func is_server_connected(server_name: String) -> bool:
	return servers.has(server_name) and servers[server_name].server_connected


## Get list of connected server names
func get_connected_servers() -> Array[String]:
	var connected: Array[String] = []
	for server_name in servers:
		if servers[server_name].server_connected:
			connected.append(server_name)
	return connected


## Refresh tools from all connected servers
func refresh_all_tools() -> void:
	for server_name in servers.keys():
		var connection = servers.get(server_name)
		if connection == null:
			continue
		var refreshed: Error = await connection.refresh_tools()
		if refreshed == OK and servers.get(server_name) == connection:
			_replace_server_tools(connection)
	tools_refreshed.emit()


func _replace_server_tools(connection) -> void:
	if servers.get(connection.server_name) != connection:
		return
	# This live owner is the only connection allowed to replace its server's
	# prior catalog; stale callbacks use the exact-owner unregister path.
	_unregister_server_tools(connection.server_name)
	_register_server_tools(connection)


## Register tools from a server connection
func _register_server_tools(connection) -> void:
	var blocked_count := 0
	var collision_count := 0
	for tool in connection.tools:
		# Block external servers from registering minerva_-prefixed tools
		if connection.server_name != "minerva" and tool.name.begins_with("minerva_"):
			push_warning("[MCP] Blocked external tool with reserved 'minerva_' prefix: %s (from %s)" % [
				tool.name, connection.server_name])
			blocked_count += 1
			continue
		if tool_registry.has(tool.name):
			var existing_server: String = tool_registry[tool.name].server_name
			# Native (minerva) tools always win over external servers
			if existing_server == "minerva" and connection.server_name != "minerva":
				push_warning("[MCP] Skipping external tool '%s' (from %s) — native tool takes priority" % [
					tool.name, connection.server_name])
				collision_count += 1
				continue
			push_warning("Tool name collision: %s (from %s, already owned by %s)" % [
				tool.name, connection.server_name, existing_server])
			collision_count += 1
			continue
		# Use server name as tool_set for external tools so they pass category filters
		if tool.tool_set.is_empty() and connection.server_name != "minerva":
			tool.tool_set = connection.server_name

		# Deprioritize native_* tools by putting them in a separate tool_set
		# Standard cobrowser tools remain in the default "cobrowser" set
		if tool.tool_set == "cobrowser" and "native_" in tool.name:
			tool.tool_set = "cobrowser-native"

		tool_registry[tool.name] = tool
		_tool_connection_owners[tool.name] = connection

		# Always index connected external tools for search-based discovery
		if minerva_server and minerva_server.tool_search_index:
			var schema: Dictionary = tool.to_anthropic_format() if tool.has_method("to_anthropic_format") else {
				"name": tool.name, "description": tool.description, "input_schema": tool.input_schema
			}
			minerva_server.tool_search_index.register_tool(tool.name, tool.description, schema, tool.tool_set)

	# Surface warnings to user via toast
	if blocked_count > 0:
		SingletonObject.create_toast_notification(
			"%s: %d tool(s) blocked (reserved minerva_ prefix)" % [connection.server_name, blocked_count],
			ToastNotification.Type.WARNING
		)
	if collision_count > 0:
		SingletonObject.create_toast_notification(
			"%s: %d tool name collision(s) — existing owners kept" % [connection.server_name, collision_count],
			ToastNotification.Type.WARNING
		)


## Unregister tools from a server
func _unregister_server_tools(server_name: String, expected_connection = null) -> void:
	var to_remove: Array[String] = []
	for tool_name in tool_registry:
		if tool_registry[tool_name].server_name == server_name \
				and (expected_connection == null \
				or _tool_connection_owners.get(tool_name) == expected_connection):
			to_remove.append(tool_name)

	for tool_name in to_remove:
		tool_registry.erase(tool_name)
		_tool_connection_owners.erase(tool_name)


## Signal handlers
func _on_server_disconnected(server_name: String, connection) -> void:
	if _connecting_servers.get(server_name) == connection:
		_connecting_servers.erase(server_name)
		var pending: Dictionary = _connection_diagnostics.get(server_name, {})
		_record_connection_failure(server_name, str(pending.get("transport", "")),
			"Connection closed during startup", int(pending.get("attempt", -1)),
			str(pending.get("config_key", "")))
		server_error.emit(server_name, "Connection closed during startup")
	if servers.get(server_name) != connection:
		return
	servers.erase(server_name)
	_unregister_server_tools(server_name, connection)
	var previous: Dictionary = _connection_diagnostics.get(server_name, {})
	_connection_diagnostics[server_name] = {"state": "failed",
		"transport": previous.get("transport", ""),
		"failure": "Connection closed unexpectedly",
		"config_key": previous.get("config_key", "")}
	server_disconnected.emit(server_name)


func _on_tools_list_changed(server_name: String, connection) -> void:
	if servers.get(server_name) != connection:
		return
	# refresh_tools emits catalog_committed for every atomic success; the exact
	# owner handler below performs the single publication for both legacy
	# notifications and modern subscriptions.
	await connection.refresh_tools()


func _on_catalog_committed(server_name: String, connection) -> void:
	if servers.get(server_name) != connection:
		return
	_replace_server_tools(connection)
	tools_refreshed.emit()
