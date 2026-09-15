extends "res://Scripts/Services/MCP/MCPServerConnection.gd"
## Runtime loading keeps the autoload-dependent base out of syntax-only
## entrypoint parsing.


func _call_tool_websocket(_name: String, arguments: Dictionary,
		_context: MCPExecutionContext = null) -> Dictionary:
	return {"success": true, "custom": arguments.get("marker")}
