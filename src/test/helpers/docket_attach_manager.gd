extends "res://Scripts/Services/Plugins/PluginManager.gd"
## Transport selection spy; the real-process oracle uses the production connection.
var stdio_starts := 0
var omit_tool := ""
var discovered: Array[String] = []

class Connection extends MCPServerConnection:
	var manager
	func connect_to_server() -> Error:
		if transport == TransportType.STDIO:
			manager.stdio_starts += 1
			return ERR_CANT_CONNECT
		server_connected = true
		return OK
	func list_tools() -> Array:
		var result: Array = []
		for name in RequiredPlugins.PLUGINS.docket.host_tools:
			if name == manager.omit_tool:
				continue
			result.append(MCPToolDefinition.from_dict({"name": name.trim_prefix("minerva_"), "inputSchema": {"type": "object"}}))
		return result

func _create_connection(id: String, url: String, transport: int) -> MCPServerConnection:
	var conn := Connection.new(id, url, transport)
	conn.manager = self
	return conn

func _discover_backend_tools(_id: String, conn: MCPServerConnection) -> void:
	for tool in await conn.list_tools():
		discovered.append(tool.name)
