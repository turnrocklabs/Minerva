class_name MCPToolModule
extends RefCounted
## Abstract base class for MCP tool domain modules.
## Each module registers tools for one domain and handles execution.

## Back-reference to MinervaMCPServer for shared state and tool registration.
var server


func _init(mcp_server = null) -> void:
	server = mcp_server


## Override: register this module's tools via server._register_tool().
## Called once during MinervaMCPServer._init().
func register_tools() -> void:
	pass


## Override: return true if this module handles the given tool name.
func can_handle(tool_name: String) -> bool:
	return tool_name in get_tool_names()


## Override: return the list of tool names this module handles.
## Used by can_handle() for dispatch. Subclasses should return a static array.
func get_tool_names() -> Array[String]:
	return []


## Override: execute a tool by name. Returns a result Dictionary.
## Use MCPToolUtils helpers for response formatting.
## NOTE: Implementations may use `await` internally, making handle() a coroutine.
## Callers MUST always `await handle()` to support async tool handlers.
func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	return MCPToolUtils.error("Tool '%s' not implemented in %s" % [tool_name, get_script().get_path().get_file()])
