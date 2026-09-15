extends "res://Scripts/Services/Plugins/PluginManager.gd"

var connections: Dictionary = {}


func get_connection(id: String) -> MCPServerConnection:
	return connections.get(id) as MCPServerConnection


func get_plugin_status(id: String) -> Dictionary:
	return {"running": connections.has(id)}
