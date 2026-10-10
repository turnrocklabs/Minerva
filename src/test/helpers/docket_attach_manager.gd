extends "res://Scripts/Services/Plugins/PluginManager.gd"
## Transport selection spy; the real-process oracle uses the production connection.
var stdio_starts := 0
var omit_tool := ""
var tool_calls: Array = []
var fake_projects: Array = []
var refuse_master := false
var http_alive := true
var disconnects := 0
var delay_health := false
signal health_release
var discovered: Array[String] = []

class Connection extends MCPServerConnection:
	var manager
	func connect_to_server() -> Error:
		if transport == TransportType.STDIO:
			manager.stdio_starts += 1
			return ERR_CANT_CONNECT
		server_connected = true
		return OK
	func disconnect_from_server() -> void:
		manager.disconnects += 1
		super.disconnect_from_server()
	func check_http_liveness(_timeout_sec: float = 2.0) -> bool:
		if manager.delay_health: await manager.health_release
		return manager.http_alive
	func call_tool(name: String, arguments: Dictionary, _timeout_sec: float = 120.0) -> Dictionary:
		manager.tool_calls.append({"name": name, "arguments": arguments.duplicate(true)})
		match name:
			"docket_project_list": return {"projects": manager.fake_projects.duplicate(true)}
			"docket_project_add":
				if manager.refuse_master: return {"error": "Fixture master unavailable"}
				var project := {"name": "Master", "path": arguments.path, "open_generation": "one"}
				manager.fake_projects.append(project)
				return project
			"docket_query": return {"items": []}
			"docket_gui_open": return {"ok": true, "pid": 42}
		return {}
	func call_tool_outcome_with_context(name: String, arguments: Dictionary, _context: MCPExecutionContext) -> MCPToolCallOutcome:
		var outcome := MCPToolCallOutcome.new()
		outcome.application = await call_tool(name, arguments)
		return outcome
	func refresh_tools() -> Error:
		tools = await list_tools()
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
