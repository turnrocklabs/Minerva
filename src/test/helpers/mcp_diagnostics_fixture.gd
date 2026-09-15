extends Node

signal server_connected(server_name: String)
signal server_disconnected(server_name: String)
signal server_error(server_name: String, error: String)

var config
var diagnostics: Dictionary = {}


func get_server_diagnostic(server_name: String, _transport: String = "") -> Dictionary:
	return diagnostics.get(server_name, {"state": "disconnected", "transport": "stdio"})


func is_server_connected(server_name: String) -> bool:
	return diagnostics.get(server_name, {}).get("state") == "connected"
