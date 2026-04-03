class_name MCPManager
extends Node
## Central manager for MCP (Model Context Protocol) server connections.
## Handles server registration, tool discovery, and tool execution.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const MCPServerConnectionScript := preload("res://Scripts/Services/MCP/MCPServerConnection.gd")
const MCPConfigScript := preload("res://Scripts/Services/MCP/MCPConfig.gd")
const MinervaMCPServerScript := preload("res://Scripts/Services/MCP/MinervaMCPServer.gd")
const MinervaMCPHttpServerScript := preload("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd")

signal server_connected(server_name: String)
signal server_disconnected(server_name: String)
signal server_error(server_name: String, error: String)
signal tool_executed(server_name: String, tool_name: String, result: Dictionary)
signal tools_refreshed()

## Connected server instances
var servers: Dictionary = {}  # server_name -> MCPServerConnection

## Registry of all available tools across all servers
var tool_registry: Dictionary = {}  # tool_name -> MCPToolDefinition

## Configuration for MCP servers
var config = null

## Internal Minerva MCP server for controlling Minerva features
var minerva_server: MinervaMCPServerScript = null

## HTTP server for exposing Minerva tools to external agents
var http_server: MinervaMCPHttpServerScript = null


func _ready() -> void:
	print("[MCP] MCPManager._ready() called")
	config = MCPConfigScript.new()
	config.load_config()

	# Initialize the internal Minerva server (but don't connect it yet)
	minerva_server = MinervaMCPServerScript.new(self)

	print("[MCP] After _ready(), tool_registry has %d tools" % tool_registry.size())


func _exit_tree() -> void:
	# Clean up all connections when the app exits
	print("[MCP] Cleaning up connections on exit...")
	disconnect_all()


## Initialize and connect to configured servers
func initialize() -> void:
	var auto_connect_servers = config.get_auto_connect_servers()
	for server_config in auto_connect_servers:
		var err: Error = await connect_server(server_config.name)
		if err == OK:
			print("MCP: Connected to %s (%s)" % [server_config.name, server_config.type])
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

	var transport = MCPConfigScript.transport_type_from_string(server_config.type)
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
	connection.connected.connect(_on_server_connected.bind(server_name))
	connection.disconnected.connect(_on_server_disconnected.bind(server_name))
	connection.tool_result_received.connect(_on_tool_result.bind(server_name))

	var err: Error = await connection.connect_to_server()
	if err != OK:
		var msg := "Failed to connect to %s: %s" % [server_name, error_string(err)]
		push_error("[MCP] " + msg)
		server_error.emit(server_name, msg)
		SingletonObject.create_toast_notification(msg, ToastNotification.Type.ERROR)
		return err

	servers[server_name] = connection

	# Refresh tools — rollback connection if this fails
	var refresh_err := await connection.refresh_tools()
	if refresh_err is int and refresh_err != OK:
		push_warning("[MCP] Tool refresh failed for %s, rolling back connection" % server_name)
		connection.disconnect_from_server()
		servers.erase(server_name)
		var msg := "%s connected but tool discovery failed — disconnected" % server_name
		server_error.emit(server_name, msg)
		SingletonObject.create_toast_notification(msg, ToastNotification.Type.ERROR)
		return ERR_CANT_ACQUIRE_RESOURCE

	_register_server_tools(connection)

	# Debug: Log registered tools
	print("[MCP] Registered %d tools from %s:" % [connection.tools.size(), server_name])
	for tool in connection.tools:
		print("[MCP]   - %s" % tool.name)

	server_connected.emit(server_name)
	return OK


## Disconnect from a server
func disconnect_server(server_name: String) -> void:
	if not servers.has(server_name):
		return

	var connection = servers[server_name]
	connection.disconnect_from_server()
	_unregister_server_tools(server_name)
	servers.erase(server_name)


## Disconnect from all servers
func disconnect_all() -> void:
	for server_name in servers.keys():
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
	config.remove_server(server_name)
	config.save_config()


## Get tools filtered for a specific chat history.
## Applies 4-layer filter: profile tool_sets → per-chat profile override → DisabledTools → connectivity.
func get_tools_for_chat(history, format: String = "anthropic") -> Array[Dictionary]:
	# Determine effective profile tool_sets
	var effective_tool_sets: Array[String] = []
	var skill_manager = SingletonObject.get_skill_manager()
	if skill_manager:
		var chat_skills: Array[String] = []
		var agent_skills: Array[String] = []
		if "ActiveSkills" in history and not history.ActiveSkills.is_empty():
			chat_skills = history.ActiveSkills
		if not history.AgentDefinitionId.is_empty():
			var agent_def = _find_agent_def(history.AgentDefinitionId)
			if agent_def and not agent_def.skills.is_empty():
				agent_skills = agent_def.skills
		effective_tool_sets = skill_manager.get_effective_tool_sets(chat_skills, agent_skills)

	# Build full filtered tool list (all 4 layers)
	var all_filtered: Array[Dictionary] = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		var server_name = tool.server_name

		# Layer 4: Server connectivity
		var connected: bool
		if server_name == "minerva":
			connected = is_minerva_connected()
		else:
			connected = is_server_connected(server_name)
		if not connected:
			continue

		# Layer 1/2: Profile tool_set filter
		if not _passes_tool_set_filter(tool, effective_tool_sets):
			continue

		var tool_dict: Dictionary
		if format == "anthropic":
			tool_dict = tool.to_anthropic_format()
		else:
			tool_dict = tool.to_openai_format()

		# Layer 3: Per-chat DisabledTools blocklist
		if tool_dict.get("name", "") in history.DisabledTools:
			continue

		all_filtered.append(tool_dict)

	# Auto tool management: return only tool_search with dynamic description
	if minerva_server and minerva_server.auto_tool_management:
		minerva_server.tool_budget_manager.advance_turn()

		# Collect categories from filtered tools for the dynamic description
		var categories: Dictionary = {}
		for tool_dict in all_filtered:
			var name: String = tool_dict.get("name", "")
			if tool_registry.has(name):
				var ts: String = tool_registry[name].tool_set
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
func execute_tool(tool_name: String, arguments: Dictionary = {}, caller_chat_id: String = "") -> Dictionary:
	print("[MCP] execute_tool called: %s" % tool_name)

	if not tool_registry.has(tool_name):
		print("[MCP] Tool not found! Available tools: %s" % str(tool_registry.keys()))
		return {"error": "Tool not found: %s" % tool_name, "success": false}

	var tool = tool_registry[tool_name]
	var server_name = tool.server_name

	# Handle skill executable tools
	if tool_name.begins_with("skill_"):
		var skill_id := tool_name.substr(6)  # Strip "skill_" prefix
		var skill_manager = SingletonObject.get_skill_manager()
		if skill_manager:
			var args_str: String = arguments.get("args", "")
			var skill_result = skill_manager.execute_skill_tool(skill_id, args_str)
			if not skill_result.has("success"):
				skill_result["success"] = not skill_result.has("error")
			tool_executed.emit(server_name, tool_name, skill_result)
			return skill_result
		return {"error": "Skill manager not available", "success": false}

	# Handle internal Minerva server tools
	if server_name == "minerva":
		if not minerva_server or not minerva_server.server_enabled:
			return {"error": "Minerva server not connected", "success": false}

		var minerva_result = await minerva_server.execute_tool(tool_name, arguments, caller_chat_id)

		# Normalize result
		if not minerva_result.has("success"):
			minerva_result["success"] = not minerva_result.has("error")

		tool_executed.emit(server_name, tool_name, minerva_result)
		return minerva_result

	# Handle external server tools
	if not servers.has(server_name):
		return {"error": "Server not connected: %s" % server_name, "success": false}

	var connection = servers[server_name]
	var result = await connection.call_tool(tool_name, arguments)

	# Normalize result
	if not result.has("success"):
		result["success"] = not result.has("error")

	# If tool execution failed with a connection error, clean up the dead connection
	if not result.get("success", false) and not connection.server_connected:
		push_warning("[MCP] Server %s disconnected during tool execution — cleaning up" % server_name)
		_unregister_server_tools(server_name)
		servers.erase(server_name)
		server_disconnected.emit(server_name)

	tool_executed.emit(server_name, tool_name, result)
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
	print("[MCP] get_tools_for_anthropic() checking %d tools in registry..." % tool_registry.size())
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		var server_name = tool.server_name
		var is_minerva = server_name == "minerva"
		var minerva_connected = is_minerva_connected() if is_minerva else false
		var external_connected = is_server_connected(server_name) if not is_minerva else false
		var connected = minerva_connected or external_connected
		if connected and _is_tool_in_enabled_set(tool):
			tools.append(tool.to_anthropic_format())
	print("[MCP] get_tools_for_anthropic() returning %d tools (filtered from %d in registry)" % [tools.size(), tool_registry.size()])
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
	tool_registry.clear()
	for server_name in servers:
		var connection = servers[server_name]
		await connection.refresh_tools()
		_register_server_tools(connection)
	tools_refreshed.emit()


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
			push_warning("Tool name collision: %s (from %s, replacing %s)" % [
				tool.name, connection.server_name, existing_server])
			collision_count += 1
		# Use server name as tool_set for external tools so they pass category filters
		if tool.tool_set.is_empty() and connection.server_name != "minerva":
			tool.tool_set = connection.server_name

		# Deprioritize native_* tools by putting them in a separate tool_set
		# Standard cobrowser tools remain in the default "cobrowser" set
		if tool.tool_set == "cobrowser" and "native_" in tool.name:
			tool.tool_set = "cobrowser-native"

		tool_registry[tool.name] = tool

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
			"%s: %d tool name collision(s) — later server wins" % [connection.server_name, collision_count],
			ToastNotification.Type.WARNING
		)


## Unregister tools from a server
func _unregister_server_tools(server_name: String) -> void:
	var to_remove: Array[String] = []
	for tool_name in tool_registry:
		if tool_registry[tool_name].server_name == server_name:
			to_remove.append(tool_name)

	for tool_name in to_remove:
		tool_registry.erase(tool_name)


## Signal handlers
func _on_server_connected(server_name: String) -> void:
	server_connected.emit(server_name)


func _on_server_disconnected(server_name: String) -> void:
	_unregister_server_tools(server_name)
	server_disconnected.emit(server_name)


func _on_tool_result(tool_name: String, result: Dictionary, server_name: String) -> void:
	tool_executed.emit(server_name, tool_name, result)
