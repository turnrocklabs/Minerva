class_name MCPServerDiagnostics
extends RefCounted
## Small presentation adapter for MCP connection state. It deliberately omits
## endpoints, commands, arguments, payloads, and credentials.


static func transport_label(value: String) -> String:
	match value.to_lower():
		"stdio": return "STDIO"
		"websocket": return "WebSocket"
		"http": return "HTTP"
	return "Custom"


static func status_text(state: Dictionary) -> String:
	var transport := transport_label(str(state.get("transport", "")))
	match str(state.get("state", "disconnected")):
		"connecting":
			return "Connecting · %s" % transport
		"connected":
			var era := str(state.get("era", "custom"))
			if era == "modern":
				return "Connected · %s · MCP %s" % [transport, state.get("version", "2026-07-28")]
			if era == "legacy":
				return "Connected · %s · Legacy MCP %s" % [transport, state.get("version", "unknown")]
			return "Connected · %s · Custom protocol" % transport
	var failure := str(state.get("failure", ""))
	return "Connection failed · %s · %s" % [transport, failure] \
		if not failure.is_empty() else "Disconnected · %s" % transport


static func timeout_text(seconds: float) -> String:
	if seconds < 1.0:
		return "%dms" % maxi(1, roundi(seconds * 1000.0))
	var text := str(seconds)
	return text.trim_suffix(".0") + "s"
