class_name MCPManager
extends Node
## Central manager for MCP (Model Context Protocol) server connections.
## Handles server registration, tool discovery, and tool execution.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const MCPServerConnectionScript := preload("res://Scripts/Services/MCP/MCPServerConnection.gd")
const MCPConfigScript := preload("res://Scripts/Services/MCP/MCPConfig.gd")

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


func _ready() -> void:
	print("[MCP] MCPManager._ready() called")
	config = MCPConfigScript.new()
	config.load_config()
	# Register Co-Browser tools (they use a custom API, not standard MCP)
	_register_cobrowser_tools()
	print("[MCP] After _ready(), tool_registry has %d tools" % tool_registry.size())


func _exit_tree() -> void:
	# Clean up all connections when the app exits
	print("[MCP] Cleaning up connections on exit...")
	disconnect_all()


## Initialize and connect to configured servers
func initialize() -> void:
	var auto_connect_servers = config.get_auto_connect_servers()
	for server_config in auto_connect_servers:
		var err = await connect_server(server_config.name)
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

	# Connect signals
	connection.connected.connect(_on_server_connected.bind(server_name))
	connection.disconnected.connect(_on_server_disconnected.bind(server_name))
	connection.error_occurred.connect(_on_server_error.bind(server_name))
	connection.tool_result_received.connect(_on_tool_result.bind(server_name))

	var err = await connection.connect_to_server()
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


## Execute a tool by name
func execute_tool(tool_name: String, arguments: Dictionary = {}) -> Dictionary:
	print("[MCP] execute_tool called: %s" % tool_name)

	# Check if this is a Co-Browser tool (special handling)
	if tool_name.begins_with("cobrowser_"):
		return await _execute_cobrowser_tool(tool_name, arguments)

	if not tool_registry.has(tool_name):
		print("[MCP] Tool not found! Available tools: %s" % str(tool_registry.keys()))
		return {"error": "Tool not found: %s" % tool_name, "success": false}

	var tool = tool_registry[tool_name]
	var server_name = tool.server_name

	if not servers.has(server_name):
		return {"error": "Server not connected: %s" % server_name, "success": false}

	var connection = servers[server_name]
	var result = await connection.call_tool(tool_name, arguments)

	# Normalize result
	if not result.has("success"):
		result["success"] = not result.has("error")

	tool_executed.emit(server_name, tool_name, result)
	return result


## Execute Co-Browser tool via CoBrowserMCPClient
func _execute_cobrowser_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	var client = SingletonObject.get_cobrowser_client()

	print("[MCP] Executing Co-Browser tool: %s" % tool_name)

	var result: Dictionary = {}

	match tool_name:
		"cobrowser_navigate":
			result = await client.navigate(arguments.get("url", ""))

		"cobrowser_click":
			result = await client.click(
				arguments.get("selector", ""),
				arguments.get("xpath", ""),
				arguments.get("x", -1),
				arguments.get("y", -1),
				arguments.get("index", 0)
			)

		"cobrowser_type":
			result = await client.type_text(
				arguments.get("selector", ""),
				arguments.get("text", ""),
				arguments.get("clear", false)
			)

		"cobrowser_read":
			result = await client.read(arguments.get("selector", ""))

		"cobrowser_query_all":
			result = await client.query_all(
				arguments.get("selector", ""),
				arguments.get("limit", 20)
			)

		"cobrowser_scroll":
			result = await client.scroll(
				arguments.get("direction", "down"),
				arguments.get("amount", 0),
				arguments.get("selector", "")
			)

		"cobrowser_get_state":
			result = await client.get_state()

		"cobrowser_screenshot":
			result = await client.screenshot()

		"cobrowser_get_page_info":
			result = await client.get_page_info()

		_:
			result = {"error": "Unknown Co-Browser tool: %s" % tool_name, "success": false}

	# Normalize result
	if not result.has("success"):
		result["success"] = not result.has("error")

	tool_executed.emit("cobrowser", tool_name, result)
	return result


## Register Co-Browser tools manually (since Co-Browser uses custom REST API, not MCP)
func _register_cobrowser_tools() -> void:
	var cobrowser_tools := [
		{
			"name": "cobrowser_navigate",
			"description": "Navigate the browser to a URL. Use this to open websites.",
			"input_schema": {
				"type": "object",
				"properties": {
					"url": {"type": "string", "description": "The URL to navigate to"}
				},
				"required": ["url"]
			}
		},
		{
			"name": "cobrowser_click",
			"description": "Click on an element in the browser. Specify either a CSS selector, XPath, or coordinates.",
			"input_schema": {
				"type": "object",
				"properties": {
					"selector": {"type": "string", "description": "CSS selector of element to click"},
					"xpath": {"type": "string", "description": "XPath of element to click"},
					"x": {"type": "integer", "description": "X coordinate to click"},
					"y": {"type": "integer", "description": "Y coordinate to click"},
					"index": {"type": "integer", "description": "Index if multiple elements match (0-based)"}
				}
			}
		},
		{
			"name": "cobrowser_type",
			"description": "Type text into a form field or input element.",
			"input_schema": {
				"type": "object",
				"properties": {
					"selector": {"type": "string", "description": "CSS selector of input element"},
					"text": {"type": "string", "description": "Text to type"},
					"clear": {"type": "boolean", "description": "Whether to clear existing text first"}
				},
				"required": ["selector", "text"]
			}
		},
		{
			"name": "cobrowser_read",
			"description": "Read text content from an element on the page.",
			"input_schema": {
				"type": "object",
				"properties": {
					"selector": {"type": "string", "description": "CSS selector of element to read"}
				},
				"required": ["selector"]
			}
		},
		{
			"name": "cobrowser_query_all",
			"description": "Query multiple elements matching a selector. Returns a list of elements with their properties.",
			"input_schema": {
				"type": "object",
				"properties": {
					"selector": {"type": "string", "description": "CSS selector to query"},
					"limit": {"type": "integer", "description": "Maximum number of results (default 20)"}
				},
				"required": ["selector"]
			}
		},
		{
			"name": "cobrowser_scroll",
			"description": "Scroll the page or an element.",
			"input_schema": {
				"type": "object",
				"properties": {
					"direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction"},
					"amount": {"type": "integer", "description": "Scroll amount in pixels (optional)"},
					"selector": {"type": "string", "description": "CSS selector of scrollable element (optional, defaults to page)"}
				},
				"required": ["direction"]
			}
		},
		{
			"name": "cobrowser_get_state",
			"description": "Get the current page state including URL, title, DOM structure, and metadata.",
			"input_schema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "cobrowser_get_page_info",
			"description": "Get basic page info: title, URL, and ready state.",
			"input_schema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "cobrowser_screenshot",
			"description": "Take a screenshot of the current page.",
			"input_schema": {
				"type": "object",
				"properties": {}
			}
		}
	]

	for tool_data in cobrowser_tools:
		var tool = MCPToolDefinitionScript.from_dict(tool_data, "cobrowser")
		tool_registry[tool.name] = tool

	print("[MCP] Registered %d Co-Browser tools" % cobrowser_tools.size())


## Get all available tools from all connected servers
func get_available_tools() -> Array:
	var tools: Array = []
	for tool_name in tool_registry:
		tools.append(tool_registry[tool_name])
	return tools


## Get tools formatted for LLM function calling (OpenAI format)
func get_tools_for_openai() -> Array[Dictionary]:
	var tools: Array[Dictionary] = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		tools.append(tool.to_openai_format())
	return tools


## Get tools formatted for Claude/Anthropic
func get_tools_for_anthropic() -> Array[Dictionary]:
	print("[MCP] get_tools_for_anthropic() called, tool_registry has %d tools" % tool_registry.size())
	var tools: Array[Dictionary] = []
	for tool_name in tool_registry:
		var tool = tool_registry[tool_name]
		tools.append(tool.to_anthropic_format())
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
