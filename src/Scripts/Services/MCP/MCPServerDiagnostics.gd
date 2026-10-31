class_name MCPServerDiagnostics
extends RefCounted
## MCP diagnostic formatting/disclosure policy. Command/argument/payload fields
## are omitted; explicitly opted-in peer stderr can still contain private text.

var _stderr_log_window_ms: int = 0
var _stderr_log_count: int = 0
var _stderr_suppressed: int = 0
var _loss_generation: int = -1
var _loss_log_ms: int = -1000
var _loss_logged: Array[int] = []

const IO_FIELDS: Array[String] = ["generation", "cause", "channel", "observed", "limit",
	"os_error", "exit_kind", "exit_code", "exit_signal", "stop_requested", "terminated_by_host",
	"stderr_dropped_lines", "stderr_dropped_bytes", "stderr_truncated_lines", "stderr_truncated_bytes",
	"stderr_eof", "evidence_state", "diagnostics_unavailable", "finalization_error", "process_retained"]
const LOSS_FIELDS: Array[String] = ["stderr_dropped_lines", "stderr_dropped_bytes",
	"stderr_truncated_lines", "stderr_truncated_bytes"]


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
		lines.append("[plugin:%s] %s" % [plugin_id, stderr_text(line)])
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
	# Local outcomes already carry deliberate host-owned codes and disclosure-
	# filtered details. Keep them intact across the transport return adapter.
	var local: Dictionary = resolved.duplicate(true)
	local["error"] = str(err)
	local["local_error"] = resolved.get("local_error", false)
	return local


static func peer_error_category(error_value: Variant) -> String:
	if error_value is Dictionary:
		var code: Variant = error_value.get("code")
		if code is int:
			return "peer error code %d" % code
		if code is float and is_finite(code) and code == floor(code) \
				and abs(code) <= 9007199254740991.0:
			return "peer error code %d" % int(code)
	return "peer error"


static func stderr_text(line: String, byte_limit: int = -1) -> String:
	var text := line.substr(0, 1024).strip_escapes()
	if byte_limit < 0:
		return text
	var low := 0
	var high := text.length()
	while low < high:
		var middle := (low + high + 1) >> 1
		if text.left(middle).to_utf8_buffer().size() <= byte_limit:
			low = middle
		else:
			high = middle - 1
	return text.left(low)


## Loss counts are safe without stderr disclosure. One summary per second,
## only when totals changed, keeps floods from becoming a second log flood.
func stderr_loss_summary(current: Dictionary, generation: int, now_ms: int, owner: String) -> String:
	if generation != _loss_generation:
		_loss_generation = generation
		_loss_log_ms = -1000
		_loss_logged.clear()
	var counts: Array[int] = []
	for field: String in LOSS_FIELDS:
		counts.append(int(current.get(field, 0)))
	if counts == [0, 0, 0, 0] or counts == _loss_logged or now_ms - _loss_log_ms < 1000:
		return ""
	_loss_logged = counts
	_loss_log_ms = now_ms
	return "[MCP %s] stderr dropped %d lines/%d bytes; truncated %d lines/%d bytes" % [
		owner, counts[0], counts[1], counts[2], counts[3]]


static func process_changed(server_name: String) -> Dictionary:
	return {"error": "MCP server '%s' changed process generation" % server_name,
		"local_error": true, "error_code": "subprocess_generation_changed",
		"details": {"evidence_state": "stale_generation", "tail_omitted": "stale_generation"}}


## Copy an allowlist of native facts. Only the manifest's disclosure owner may
## request the independently bounded tail; control stripping is not redaction.
static func stdio_failure(current: Dictionary, server_name: String, plugin_id: String,
		include_stderr: bool, legacy_exit_code: int, event: String) -> Dictionary:
	var details: Dictionary = {"server_name": server_name, "plugin_id": plugin_id}
	for field: String in IO_FIELDS:
		if current.has(field):
			details[field] = current[field]
	if legacy_exit_code >= 0:
		details["legacy_exit_code"] = legacy_exit_code
	details["observed_event"] = event
	if not include_stderr:
		details["tail_omitted"] = "stderr_logging_disabled"
	elif current.get("evidence_state") not in ["complete", "cutoff"]:
		details["tail_omitted"] = "finalization_incomplete"
	elif current.get("stderr_tail") is PackedStringArray or current.get("stderr_tail") is Array:
		var tail: Array[String] = []
		var remaining := 8 * 1024
		for value: Variant in current.stderr_tail:
			if tail.size() >= 32 or remaining <= 0:
				break
			var text := stderr_text(str(value), mini(1024, remaining))
			remaining -= text.to_utf8_buffer().size()
			tail.append(text)
		details["stderr_tail"] = tail
	else:
		details["tail_omitted"] = "native_tail_unavailable"
	var cause := str(current.get("cause", ""))
	var code := "subprocess_" + cause if not cause.is_empty() else "subprocess_" + event
	var reason: String
	match cause:
		"stdout_queue_lines", "stdout_queue_bytes":
			reason = "stdout queue exceeded its %s bound (%s > %s)" % [
				"line" if cause.ends_with("lines") else "byte", current.get("observed"), current.get("limit")]
		"stdout_line_bytes":
			reason = "stdout frame exceeded its byte bound (%s > %s)" % [current.get("observed"), current.get("limit")]
		"stdin_queue_lines", "stdin_queue_bytes":
			reason = "stdin queue refused a write (%s > %s)" % [current.get("observed"), current.get("limit")]
		"stdin_broken_pipe": reason = "stdin pipe closed during a write"
		"stdin_write_error": reason = "stdin write failed (OS error %s)" % current.get("os_error")
		"stdout_read_error": reason = "stdout read failed (OS error %s)" % current.get("os_error")
		"stdout_eof": reason = "closed stdout"
		"process_exit":
			if current.get("exit_kind") == "signal":
				reason = "terminated by signal %s" % current.get("exit_signal")
				code = "subprocess_signaled"
			elif current.get("exit_kind") == "exit":
				reason = "exited with code %s" % current.get("exit_code")
				code = "subprocess_exited"
			else:
				reason = "exited with status unavailable"
		_:
			reason = "transport failed (%s); native cause unavailable" % event
	if current.get("evidence_state") == "unavailable":
		reason += "; rebuild the native extension for finalized diagnostics"
	elif current.get("evidence_state") == "finalization_failed":
		reason += "; finalization failed; subprocess ownership retained"
		code = "subprocess_finalization_failed"
	return {"error": "MCP server '%s': %s" % [server_name, reason], "local_error": true,
		"error_code": code, "details": details}
