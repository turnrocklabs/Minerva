class_name MCPKnownServers
extends RefCounted
## Static registry of known MCP servers that ship with Minerva.
## Replaces hardcoded REPOS in MCPServerInstaller and DEFAULT_PORTS in MCPConfig.

## Information about a known MCP server
class KnownServer:
	var display_name: String
	var description: String
	var default_type: String  # "http", "websocket", "stdio"
	var default_port: int
	var repo_url: String
	var installable: bool  # Whether this server can be installed via MCPServerInstaller
	var default_mcp_endpoint: String  # "/mcp" or "/"
	var folder_name: String  # Directory name when cloned
	var validation_file: String  # File to check for valid installation
	var startup_module: String  # Python -m module for starting
	var startup_args: Array  # Extra args for startup command

	func _init(p_display: String = "", p_desc: String = "", p_type: String = "http",
			p_port: int = 0, p_repo: String = "", p_installable: bool = false,
			p_endpoint: String = "/mcp", p_folder: String = "",
			p_validation: String = "", p_module: String = "",
			p_startup_args: Array = []) -> void:
		display_name = p_display
		description = p_desc
		default_type = p_type
		default_port = p_port
		repo_url = p_repo
		installable = p_installable
		default_mcp_endpoint = p_endpoint
		folder_name = p_folder if not p_folder.is_empty() else ""
		validation_file = p_validation
		startup_module = p_module
		startup_args = p_startup_args


## Registry of all known servers (keyed by server name).
##
## MIGRATION LAND-MINE (read before moving a core server to a plugin):
## codetools was REMOVED from this registry once it became an installable
## marketplace plugin. A core "known server" registers its tools independent of
## any plugin, which (a) violates "no plugin installed => no such tools" and
## (b) SHADOWS the plugin's `minerva_<id>_*` namespace with stale/older tools, so
## the plugin's seeded skills can never resolve their tool_deps and stay hidden.
## nudge and cobrowser are intentionally still core for now, but are slated to
## become plugins too. When they migrate, deleting the entry here is NECESSARY
## but NOT SUFFICIENT: ServerConfigs are PERSISTED into user://mcp_config.json and
## reloaded on launch, so you must ALSO strip the server from existing user
## configs (and drop any per-server special-casing, e.g. in MCPConfig) — else the
## stale core server lingers and shadows the new plugin. (codetools incident,
## 2026-06-08.)
static var SERVERS: Dictionary = {
	"nudge": KnownServer.new(
		"Nudge",
		"Session-scoped hint cache for storing micro-facts",
		"http", 8765,
		"https://github.com/ipeerbhai/nudge.git",
		true, "/mcp", "nudge", "", "nudge",
		["serve"]
	),
	"cobrowser": KnownServer.new(
		"Cobrowser",
		"Browser automation through Firefox extension",
		"http", 8677,
		"https://github.com/ipeerbhai/HumanWeb.git",
		true, "/mcp", "HumanWeb",
		"src/Library/cobrowser_service.py", "uvicorn",
		["src.Library.cobrowser_service:app", "--host", "0.0.0.0"]
	),
}


## Get a known server by name, or null if not known
static func get_server(name: String) -> KnownServer:
	return SERVERS.get(name)


## Check if a server name is a known server
static func is_known(name: String) -> bool:
	return SERVERS.has(name)


## Get all known server names
static func get_names() -> Array[String]:
	var names: Array[String] = []
	for key in SERVERS:
		names.append(key)
	return names


## Get display name for a known server, or the raw name if not known
static func get_display_name(name: String) -> String:
	var server = get_server(name)
	return server.display_name if server else name.capitalize()


## Get default port for a known server, or 0 if not known
static func get_default_port(name: String) -> int:
	var server = get_server(name)
	return server.default_port if server else 0


## Get the repository URL for installation
static func get_repo_url(name: String) -> String:
	var server = get_server(name)
	return server.repo_url if server else ""


## Get the folder name for cloning
static func get_folder_name(name: String) -> String:
	var server = get_server(name)
	if server and not server.folder_name.is_empty():
		return server.folder_name
	return name


## Get the validation file path for checking valid installation
static func get_validation_file(name: String) -> String:
	var server = get_server(name)
	return server.validation_file if server else ""


## Check if a known server is installable
static func is_installable(name: String) -> bool:
	var server = get_server(name)
	return server.installable if server else false
