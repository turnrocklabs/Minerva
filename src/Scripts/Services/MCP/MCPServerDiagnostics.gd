class_name MCPServerDiagnostics
extends RefCounted
## Small presentation adapter for MCP connection state. It deliberately omits
## endpoints, commands, arguments, payloads, and credentials.

var _stderr_log_window_ms: int = 0
var _stderr_log_count: int = 0
var _stderr_suppressed: int = 0


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


## Plain values and caller-owned monotonic time keep disclosure/rate policy in
## one owner; the connection owns reads and presentation of these lines.
func stderr_log_lines(line: String, now_ms: int, enabled: bool, plugin_id: String) -> PackedStringArray:
	var lines := PackedStringArray()
	if not enabled:
		return lines
	if now_ms - _stderr_log_window_ms >= 1000:
		_stderr_log_window_ms = now_ms
		_stderr_log_count = 0
		if _stderr_suppressed > 0:
			lines.append("[plugin:%s] %d lines suppressed" % [plugin_id, _stderr_suppressed])
			_stderr_suppressed = 0
			_stderr_log_count = 1
	if _stderr_log_count < 10:
		_stderr_log_count += 1
		lines.append("[plugin:%s] %s" % [plugin_id, line.substr(0, 1024).strip_escapes()])
	else:
		_stderr_suppressed += 1
	return lines


static func stdio_finalize(resolved: Dictionary) -> Dictionary:
	if not resolved.has("error"):
		return resolved
	var err = resolved["error"]
	if err is Dictionary:
		return {"error": str(err.get("message", "Unknown error")),
			"rpc_error": err.duplicate(true)}
	return {"error": str(err), "local_error": resolved.get("local_error", false)}


static func peer_error_category(error_value: Variant) -> String:
	if error_value is Dictionary:
		var code: Variant = error_value.get("code")
		if code is int:
			return "peer error code %d" % code
		if code is float and is_finite(code) and code == floor(code) \
				and abs(code) <= 9007199254740991.0:
			return "peer error code %d" % int(code)
	return "peer error"
