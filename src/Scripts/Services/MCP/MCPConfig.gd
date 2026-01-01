class_name MCPConfig
extends Resource
## Configuration for MCP servers.
## Stores server definitions and can be saved/loaded from user settings.

const MCPServerConnectionScript := preload("res://Scripts/Services/MCP/MCPServerConnection.gd")

## Configuration for a single MCP server
class ServerConfig:
	var name: String = ""
	var type: String = "http"  # "http", "websocket", "stdio"
	var url: String = ""  # For HTTP/WebSocket
	var command: String = ""  # For STDIO: executable command
	var args: PackedStringArray = []  # For STDIO: command arguments
	var enabled: bool = true
	var auto_connect: bool = true
	var skip_mcp_init: bool = false  # For REST APIs that don't use MCP protocol
	var working_directory: String = ""  # Working directory for file operations

	func _init(n: String = "", t: String = "http", u: String = "") -> void:
		name = n
		type = t
		url = u

	## Create a STDIO-based server config
	static func create_stdio(n: String, cmd: String, cmd_args: PackedStringArray = []) -> ServerConfig:
		var config := ServerConfig.new(n, "stdio", "")
		config.command = cmd
		config.args = cmd_args
		return config

	func to_dict() -> Dictionary:
		var d := {
			"name": name,
			"type": type,
			"url": url,
			"enabled": enabled,
			"auto_connect": auto_connect,
			"skip_mcp_init": skip_mcp_init,
			"working_directory": working_directory
		}
		if type == "stdio":
			d["command"] = command
			d["args"] = Array(args)
		return d

	static func from_dict(data: Dictionary) -> ServerConfig:
		var config := ServerConfig.new()
		config.name = data.get("name", "")
		config.type = data.get("type", "http")
		config.url = data.get("url", "")
		config.command = data.get("command", "")
		var args_data = data.get("args", [])
		if args_data is Array:
			for arg in args_data:
				config.args.append(str(arg))
		config.enabled = data.get("enabled", true)
		config.auto_connect = data.get("auto_connect", true)
		config.skip_mcp_init = data.get("skip_mcp_init", false)
		config.working_directory = data.get("working_directory", "")
		return config


## List of configured MCP servers
var servers: Array[ServerConfig] = []

## Path to save/load configuration
const CONFIG_PATH := "user://mcp_config.json"


func _init() -> void:
	# Add default servers
	_add_default_servers()


## Path to Nudge PID file (contains port info)
const NUDGE_PID_FILE := "/tmp/nudge/server.pid"


## Discover Nudge server port from PID file
## Returns the port if found, or default 8765
static func discover_nudge_port() -> int:
	const DEFAULT_PORT := 8765

	if not FileAccess.file_exists(NUDGE_PID_FILE):
		return DEFAULT_PORT

	var file := FileAccess.open(NUDGE_PID_FILE, FileAccess.READ)
	if not file:
		return DEFAULT_PORT

	var content := file.get_as_text().strip_edges()
	file.close()

	var json := JSON.new()
	if json.parse(content) != OK:
		return DEFAULT_PORT

	var data: Dictionary = json.data if json.data is Dictionary else {}
	return data.get("port", DEFAULT_PORT)


## Check if Nudge server is running (by checking PID file)
static func is_nudge_running() -> bool:
	if not FileAccess.file_exists(NUDGE_PID_FILE):
		return false

	var file := FileAccess.open(NUDGE_PID_FILE, FileAccess.READ)
	if not file:
		return false

	var content := file.get_as_text().strip_edges()
	file.close()

	var json := JSON.new()
	if json.parse(content) != OK:
		return false

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var pid: int = data.get("pid", 0)

	if pid <= 0:
		return false

	# Check if process is running (Unix only for now)
	# We'll verify via HTTP health check in MCPManager instead
	return true


## Add the built-in default server configurations
func _add_default_servers() -> void:
	# Nudge MCP server (session-scoped hint cache) - uses HTTP transport
	# Discovers port from PID file or defaults to 8765
	var nudge_port := discover_nudge_port()
	var nudge := ServerConfig.new("nudge", "http", "http://localhost:%d" % nudge_port)
	nudge.auto_connect = true
	servers.append(nudge)

	# Co-Browser MCP server (browser automation) - uses MCP JSON-RPC on port 8678
	# Note: MCP endpoint is at /mcp, health check at root - MCPServerConnection handles this
	var cobrowser := ServerConfig.new("cobrowser", "http", "http://localhost:8678")
	cobrowser.auto_connect = false  # User must explicitly enable
	servers.append(cobrowser)

	# CodeTools MCP server (code manipulation tools) - uses MCP JSON-RPC on port 8700
	var codetools := ServerConfig.new("codetools", "http", "http://localhost:8700")
	codetools.auto_connect = false  # User must explicitly enable
	# Default to current working directory (where Minerva was launched from)
	var dir := DirAccess.open(".")
	if dir:
		codetools.working_directory = dir.get_current_dir()
	servers.append(codetools)


## Get a server configuration by name
func get_server(name: String) -> ServerConfig:
	for server in servers:
		if server.name == name:
			return server
	return null


## Add or update a server configuration
func set_server(config: ServerConfig) -> void:
	var existing := get_server(config.name)
	if existing:
		existing.type = config.type
		existing.url = config.url
		existing.enabled = config.enabled
		existing.auto_connect = config.auto_connect
	else:
		servers.append(config)


## Remove a server configuration
func remove_server(name: String) -> bool:
	for i in range(servers.size()):
		if servers[i].name == name:
			servers.remove_at(i)
			return true
	return false


## Get all enabled servers
func get_enabled_servers() -> Array[ServerConfig]:
	var enabled: Array[ServerConfig] = []
	for server in servers:
		if server.enabled:
			enabled.append(server)
	return enabled


## Get all servers that should auto-connect
func get_auto_connect_servers() -> Array[ServerConfig]:
	var auto_connect: Array[ServerConfig] = []
	for server in servers:
		if server.enabled and server.auto_connect:
			auto_connect.append(server)
	return auto_connect


## Get all server names
func get_server_names() -> Array[String]:
	var names: Array[String] = []
	for server in servers:
		names.append(server.name)
	return names


## Save configuration to file
func save_config() -> Error:
	var data := {
		"version": 1,
		"servers": []
	}

	for server in servers:
		data["servers"].append(server.to_dict())

	var json := JSON.stringify(data, "\t")
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()

	file.store_string(json)
	file.close()
	return OK


## Load configuration from file
func load_config() -> Error:
	if not FileAccess.file_exists(CONFIG_PATH):
		# No config file yet, use defaults
		return OK

	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var json_str := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(json_str)
	if err != OK:
		push_error("Failed to parse MCP config: %s" % json.get_error_message())
		return err

	var data: Dictionary = json.data if json.data is Dictionary else {}

	# Clear existing and load from file
	servers.clear()
	var servers_data: Array = data.get("servers", [])
	for server_data in servers_data:
		servers.append(ServerConfig.from_dict(server_data))

	# Ensure default servers exist
	if not get_server("nudge"):
		var nudge_port := discover_nudge_port()
		var nudge := ServerConfig.new("nudge", "http", "http://localhost:%d" % nudge_port)
		servers.append(nudge)

	if not get_server("cobrowser"):
		var cobrowser := ServerConfig.new("cobrowser", "http", "http://localhost:8678")
		cobrowser.auto_connect = false
		servers.append(cobrowser)

	if not get_server("codetools"):
		var codetools := ServerConfig.new("codetools", "http", "http://localhost:8700")
		codetools.auto_connect = false
		servers.append(codetools)

	return OK


## Convert transport type string to enum
static func transport_type_from_string(type_str: String) -> int:
	match type_str.to_lower():
		"http":
			return 0  # MCPServerConnection.TransportType.HTTP
		"websocket", "ws":
			return 1  # MCPServerConnection.TransportType.WEBSOCKET
		"stdio":
			return 2  # MCPServerConnection.TransportType.STDIO
		_:
			return 0  # Default to HTTP
