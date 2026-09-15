extends "res://Scripts/Services/MCP/MCPServerConnection.gd"

signal refresh_entered
signal release_refresh
var hold_refresh := false
var refresh_entered_flag := false

func refresh_tools() -> Error:
	if hold_refresh:
		refresh_entered_flag = true
		refresh_entered.emit()
		await release_refresh
	return OK
