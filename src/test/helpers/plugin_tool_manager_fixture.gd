extends "res://Scripts/Services/Plugins/PluginManager.gd"

var connections: Dictionary = {}


func _init() -> void:
	# Off-tree fixtures never run PluginManager._ready(), but publication reads its DB.
	_db = PluginDB.new()


func get_connection(id: String) -> MCPServerConnection:
	return connections.get(id) as MCPServerConnection


func get_plugin_status(id: String) -> Dictionary:
	return {"running": connections.has(id)}
