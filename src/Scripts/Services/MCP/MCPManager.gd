class_name MCPManager
extends Node
## Central manager for MCP (Model Context Protocol) server connections.
## Handles server registration, tool discovery, and tool execution.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const MCPServerConnectionScript := preload("res://Scripts/Services/MCP/MCPServerConnection.gd")
const MCPConfigScript := preload("res://Scripts/Services/MCP/MCPConfig.gd")
const MinervaMCPServerScript := preload("res://Scripts/Services/MCP/MinervaMCPServer.gd")

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

	# Skip MCP init for REST APIs that don't support it (e.g., cobrowser)
	connection.skip_mcp_init = server_config.skip_mcp_init

	# Set MCP endpoint path (some servers use "/" instead of "/mcp")
	connection.mcp_endpoint = server_config.mcp_endpoint

	# Set working directory if configured (for codetools)
	if not server_config.working_directory.is_empty():
		connection.working_directory = server_config.working_directory

	# Connect signals
	connection.connected.connect(_on_server_connected.bind(server_name))
	connection.disconnected.connect(_on_server_disconnected.bind(server_name))
	connection.error_occurred.connect(_on_server_error.bind(server_name))
	connection.tool_result_received.connect(_on_tool_result.bind(server_name))

	var err: Error = await connection.connect_to_server()
	if err != OK:
		push_error("Failed to connect to MCP server %s: %s" % [server_name, error_string(err)])
		server_error.emit(server_name, "Connection failed: %s" % error_string(err))
		return err

	servers[server_name] = connection

	# Refresh tools from this server
	await connection.refresh_tools()
	_register_server_tools(connection)

	# Debug: Log registered tools
	print("[MCP] Registered %d tools from %s:" % [connection.tools.size(), server_name])
	for tool in connection.tools:
		print("[MCP]   - %s" % tool.name)

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
	if minerva_server and minerva_server.is_connected:
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
	return minerva_server != null and minerva_server.is_connected


## Execute a tool by name
func execute_tool(tool_name: String, arguments: Dictionary = {}) -> Dictionary:
	print("[MCP] execute_tool called: %s" % tool_name)

	if not tool_registry.has(tool_name):
		print("[MCP] Tool not found! Available tools: %s" % str(tool_registry.keys()))
		return {"error": "Tool not found: %s" % tool_name, "success": false}

	var tool = tool_registry[tool_name]
	var server_name = tool.server_name

	# Handle internal Minerva server tools
	if server_name == "minerva":
		if not minerva_server or not minerva_server.is_connected:
			return {"error": "Minerva server not connected", "success": false}

		var result = await minerva_server.execute_tool(tool_name, arguments)

		# Normalize result
		if not result.has("success"):
			result["success"] = not result.has("error")

		tool_executed.emit(server_name, tool_name, result)
		return result

	# Handle external server tools
	if not servers.has(server_name):
		return {"error": "Server not connected: %s" % server_name, "success": false}

	var connection = servers[server_name]
	var result = await connection.call_tool(tool_name, arguments)

	# Normalize result
	if not result.has("success"):
		result["success"] = not result.has("error")

	tool_executed.emit(server_name, tool_name, result)
	return result


## Get all available tools from all connected servers
func get_available_tools() -> Array:
	var tools: Array = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		# Only include tools from actually connected servers
		var server_name = tool.server_name
		if server_name == "minerva":
			if is_minerva_connected():
				tools.append(tool)
		elif is_server_connected(server_name):
			tools.append(tool)
	return tools


## Get tools formatted for LLM function calling (OpenAI format)
func get_tools_for_openai() -> Array[Dictionary]:
	var tools: Array[Dictionary] = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		# Only include tools from connected servers
		var server_name = tool.server_name
		var connected = (server_name == "minerva" and is_minerva_connected()) or is_server_connected(server_name)
		if connected:
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
		var server_connected = is_server_connected(server_name) if not is_minerva else false
		var connected = minerva_connected or server_connected
		print("[MCP]   Tool '%s' from '%s': minerva=%s, connected=%s" % [tool_name, server_name, minerva_connected, server_connected])
		if connected:
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
	return servers.has(server_name) and servers[server_name].is_connected


## Get list of connected server names
func get_connected_servers() -> Array[String]:
	var connected: Array[String] = []
	for server_name in servers:
		if servers[server_name].is_connected:
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
	for tool in connection.tools:
		if tool_registry.has(tool.name):
			push_warning("Tool name collision: %s (from %s, already registered from %s)" % [
				tool.name,
				connection.server_name,
				tool_registry[tool.name].server_name
			])
		tool_registry[tool.name] = tool


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


func _on_server_error(error: String, server_name: String) -> void:
	server_error.emit(server_name, error)


func _on_tool_result(tool_name: String, result: Dictionary, server_name: String) -> void:
	tool_executed.emit(server_name, tool_name, result)
