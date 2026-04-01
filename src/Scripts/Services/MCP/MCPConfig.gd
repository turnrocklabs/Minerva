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
	var mcp_endpoint: String = "/mcp"  # MCP JSON-RPC endpoint path (some servers use "/" instead)
	var origin: String = "known"  # "builtin" | "known" | "user"
	var persistent: bool = true  # session-only servers excluded from save_config()

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
			"working_directory": working_directory,
			"mcp_endpoint": mcp_endpoint,
			"origin": origin,
			"persistent": persistent,
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
		config.mcp_endpoint = data.get("mcp_endpoint", "/mcp")
		config.origin = data.get("origin", "known")
		config.persistent = data.get("persistent", true)
		return config


## List of configured MCP servers
var servers: Array[ServerConfig] = []

## Installation paths for MCP servers
var installation_paths: Dictionary = {}

## Python environment to use for starting servers: "auto" or absolute path to python executable
var python_environment: String = "auto"

## Per-server port overrides (server_name -> int)
var server_ports: Dictionary = {}

## Enabled tool groups for internal MCP consumers (empty = all enabled)
var enabled_tool_groups: Array[String] = []

## Default ports for known servers (delegates to MCPKnownServers)
static var DEFAULT_PORTS: Dictionary:
	get:
		var ports := {}
		for sname in MCPKnownServers.get_names():
			var port := MCPKnownServers.get_default_port(sname)
			if port > 0:
				ports[sname] = port
		return ports

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


## Add the built-in default server configurations from MCPKnownServers registry
func _add_default_servers() -> void:
	for server_name in MCPKnownServers.get_names():
		var known := MCPKnownServers.get_server(server_name)
		if not known:
			continue

		var port: int = known.default_port
		# Nudge has special port discovery
		if server_name == "nudge":
			port = discover_nudge_port()

		var config := ServerConfig.new(server_name, known.default_type,
			"http://localhost:%d" % port)
		config.auto_connect = true  # Try to connect on startup; falls back to disconnected if unavailable
		config.mcp_endpoint = known.default_mcp_endpoint
		config.origin = "known"

		# CodeTools defaults to current working directory
		if server_name == "codetools":
			var dir := DirAccess.open(".")
			if dir:
				config.working_directory = dir.get_current_dir()

		servers.append(config)


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


## Set installation path for an MCP server
func set_installation_path(server_name: String, path: String) -> void:
	installation_paths[server_name] = path


## Get installation path for an MCP server
func get_installation_path(server_name: String) -> String:
	return installation_paths.get(server_name, "")


## Check if an MCP server is installed
func is_server_installed(server_name: String) -> bool:
	var path := get_installation_path(server_name)
	if path.is_empty():
		return false
	return DirAccess.dir_exists_absolute(path)


## Resolve the python executable for a given server.
## Priority: config python_environment > per-server .venv > system python
func get_python_for_server(server_name: String) -> String:
	# If user chose a specific python, use it
	if python_environment != "auto" and not python_environment.is_empty():
		if FileAccess.file_exists(python_environment):
			return python_environment

	# Try per-server .venv
	var install_path := get_installation_path(server_name)
	if not install_path.is_empty():
		var venv_python: String
		if OS.get_name() == "Windows":
			venv_python = install_path.path_join(".venv/Scripts/python.exe")
		else:
			venv_python = install_path.path_join(".venv/bin/python")
		if FileAccess.file_exists(venv_python):
			return venv_python

	# Fall back to system python
	return ""


## Get the configured port for a server, or its default
func get_server_port(server_name: String) -> int:
	if server_ports.has(server_name):
		return int(server_ports[server_name])
	return DEFAULT_PORTS.get(server_name, 0)


## Set port override for a server
func set_server_port(server_name: String, port: int) -> void:
	server_ports[server_name] = port


## Save configuration to file
func save_config() -> Error:
	var data := {
		"version": 3,
		"servers": [],
		"installation_paths": installation_paths,
		"python_environment": python_environment,
		"server_ports": server_ports,
		"enabled_tool_groups": Array(enabled_tool_groups),
	}

	for server in servers:
		if not server.persistent:
			continue  # Skip session-only servers
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

	# Load installation paths
	var paths_data: Dictionary = data.get("installation_paths", {})
	installation_paths = paths_data

	# Load v2 fields (default gracefully for v1 configs)
	python_environment = data.get("python_environment", "auto")
	var ports_data = data.get("server_ports", {})
	server_ports = ports_data if ports_data is Dictionary else {}
	var groups_data = data.get("enabled_tool_groups", [])
	enabled_tool_groups = []
	if groups_data is Array:
		for g in groups_data:
			enabled_tool_groups.append(str(g))

	# Clear existing and load from file
	servers.clear()
	var servers_data: Array = data.get("servers", [])
	for server_data in servers_data:
		servers.append(ServerConfig.from_dict(server_data))

	# Remove stale "known" servers that are no longer in the registry
	var to_remove: Array[String] = []
	for server in servers:
		if server.origin == "known" and not MCPKnownServers.is_known(server.name):
			to_remove.append(server.name)
	var had_stale := not to_remove.is_empty()
	for stale_name in to_remove:
		remove_server(stale_name)
		print("[MCPConfig] Removed stale known server: %s" % stale_name)

	# Ensure all known servers exist (merges new known servers after Minerva updates)
	for known_name in MCPKnownServers.get_names():
		if not get_server(known_name):
			var known := MCPKnownServers.get_server(known_name)
			if not known:
				continue
			var port: int = known.default_port
			if known_name == "nudge":
				port = discover_nudge_port()
			var new_config := ServerConfig.new(known_name, known.default_type,
				"http://localhost:%d" % port)
			new_config.auto_connect = true  # Try to connect on startup
			new_config.mcp_endpoint = known.default_mcp_endpoint
			new_config.origin = "known"
			if known_name == "codetools":
				var dir := DirAccess.open(".")
				if dir:
					new_config.working_directory = dir.get_current_dir()
			servers.append(new_config)

	# Migration: Apply required property fixes for existing configs
	var config_version: int = data.get("version", 1)
	_migrate_server_configs(config_version, had_stale)

	return OK


## Migrate existing server configs to apply required property changes
func _migrate_server_configs(config_version: int, force_save: bool = false) -> void:
	var needs_save := force_save

	# Cobrowser consolidated service runs on port 8677 (MCP + WebSocket in one)
	var cobrowser := get_server("cobrowser")
	if cobrowser:
		# Migrate old 8678 port to consolidated 8677
		if cobrowser.url == "http://localhost:8678":
			cobrowser.url = "http://localhost:8677"
			needs_save = true
			print("[MCPConfig] Migrated cobrowser: port 8678 -> 8677 (consolidated service)")
		if cobrowser.skip_mcp_init:
			cobrowser.skip_mcp_init = false
			cobrowser.mcp_endpoint = "/mcp"
			needs_save = true
			print("[MCPConfig] Migrated cobrowser: enabled MCP init")

	# v1 → v2: ensure new fields have defaults
	if config_version < 2:
		if python_environment.is_empty():
			python_environment = "auto"
		needs_save = true
		print("[MCPConfig] Migrated config v1 -> v2")

	# v2 → v3: add origin and persistent fields
	if config_version < 3:
		for server in servers:
			if server.origin.is_empty() or server.origin == "known":
				# Classify based on known server registry
				if MCPKnownServers.is_known(server.name):
					server.origin = "known"
				else:
					server.origin = "user"
			server.persistent = true
		needs_save = true
		print("[MCPConfig] Migrated config v2 -> v3")

	if needs_save:
		save_config()


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
