extends RefCounted
## Consecutive-call and repeated-error accounting shared by HTTP and internal MCP.

## Duplicate call detection
var _last_call_hash: String = ""
var _consecutive_count: int = 0
var _consecutive_error_count: int = 0

## Error-loop detection: tracks last error hash per tool name
## Format: { tool_name: { "error_hash": int, "count": int } }
var _error_tracker: Dictionary = {}

## Check for duplicate calls and inject warning if detected
func check(tool_name: String, arguments: Dictionary, result: Dictionary) -> Dictionary:
	# Pending is a nonterminal protocol result, not an unsuccessful attempt.
	if _is_pending(tool_name, result):
		_last_call_hash = ""
		_consecutive_count = 0
		_consecutive_error_count = 0
		_error_tracker.erase(tool_name)
		return result

	# Translate nested cobrowser errors into top-level errors with prescriptive messages.
	# Cobrowser wraps errors as {"success": true, "result": {"error": "...", "success": false}}.
	# This makes them invisible to error tracking and unhelpful to the LLM.
	if result.get("success", false) == true and result.has("result"):
		var inner = result.get("result")
		if inner is Dictionary and inner.get("success", true) == false and inner.has("error"):
			var inner_error: String = str(inner["error"])
			result["success"] = false
			# Prescriptive error messages for common cobrowser failures
			if "No active tab" in inner_error or "Invalid tab ID" in inner_error:
				result["error"] = "No browser tab found. Call cobrowser_tab_new to create a tab, or cobrowser_tab_list to discover existing tabs. Do NOT guess tab IDs — they are arbitrary numbers like 47, 53, 56."
			elif "Could not establish connection" in inner_error or "Receiving end does not exist" in inner_error:
				result["error"] = "Browser extension not responding on this tab. The tab may have been closed or the extension reloaded. Call cobrowser_tab_list to find valid tabs, or cobrowser_tab_new to create a new one."
			else:
				result["error"] = inner_error

	var call_hash: String = (tool_name + JSON.stringify(arguments)).sha256_text()
	var same_call := call_hash == _last_call_hash
	if same_call:
		_consecutive_count += 1
		if _consecutive_count >= 3:
			result["warning"] = "This tool has been called %d times with identical arguments. You are likely stuck in a loop. Stop and reassess your plan." % (_consecutive_count + 1)
		elif _consecutive_count >= 1:
			result["warning"] = "Identical call repeated. Consider advancing to the next step in your plan."
	else:
		_consecutive_count = 0
	_last_call_hash = call_hash

	# Track consecutive errors on repeated calls (now sees cobrowser errors too)
	var payload := _payload(result)
	var is_error: bool = _is_error(result) or _is_error(payload)
	if is_error:
		_consecutive_error_count = _consecutive_error_count + 1 if same_call else 1
	else:
		_consecutive_error_count = 0

	# Escalate based on consecutive error count
	if _consecutive_error_count >= 5:
		result["error"] = "BLOCKED: This tool has been called %d times with identical arguments and failed every time. This approach does not work. Try a completely different tool or approach, or report that you are blocked." % _consecutive_error_count
		result["blocked"] = true
	elif _consecutive_error_count >= 3:
		result["warning"] = "STOP: You have called this tool %d times with identical arguments and it failed each time. Do NOT retry. Try a different approach immediately." % _consecutive_error_count

	# Error-loop detection: same tool, same error message, different (or same) arguments
	_check_error_loop(tool_name, result, is_error)

	return result


## Detect when the same tool keeps returning the same error (regardless of arguments).
## Injects a "retry_hint" key to nudge the LLM toward a different approach.
func _check_error_loop(tool_name: String, result: Dictionary, is_error: bool) -> void:
	if is_error:
		var error_msg: String = str(_payload(result).get("error", result.get("error", "unsuccessful result")))
		var error_hash: int = error_msg.hash()

		if _error_tracker.has(tool_name):
			var entry: Dictionary = _error_tracker[tool_name]
			if entry["error_hash"] == error_hash:
				entry["count"] += 1
				_error_tracker[tool_name] = entry
				var count: int = entry["count"]
				if count >= 3:
					result["retry_hint"] = "STOP: This tool keeps failing. Review your available tools and choose a different approach entirely."
				elif count >= 2:
					result["retry_hint"] = "This tool has failed 2 times with the same error. Try a different tool or approach."
			else:
				# Different error — reset counter for this tool
				_error_tracker[tool_name] = {"error_hash": error_hash, "count": 1}
		else:
			_error_tracker[tool_name] = {"error_hash": error_hash, "count": 1}
	else:
		# Tool succeeded — clear its error tracking entry
		if _error_tracker.has(tool_name):
			_error_tracker.erase(tool_name)
		# Also clear entries for other tools when a different tool succeeds,
		# since the agent has adapted and is no longer stuck.
		for other_tool in _error_tracker.keys():
			if other_tool != tool_name:
				_error_tracker.erase(other_tool)


## Plugin handlers can wrap the operation result in successful transport envelopes.
static func _payload(result: Dictionary) -> Dictionary:
	var payload := result
	for _depth in range(8):
		if _is_error(payload) or not payload.get("result") is Dictionary:
			break
		payload = payload["result"]
	return payload


static func _is_error(result: Dictionary) -> bool:
	return result.has("error") or result.get("success", true) == false or result.get("ok", true) == false or result.get("isError", false) == true


static func _is_pending(tool_name: String, result: Dictionary) -> bool:
	var payload := _payload(result)
	# Legacy CAD exports predate status + job handles. Match the structured
	# error kind only for that tool, never arbitrary error-message text.
	if tool_name in ["cad.export", "minerva_cad_export", "minerva_cad_cad_export"]:
		var error = payload.get("error")
		if error is Dictionary and error.get("kind") == "running":
			return true
	if _is_error(payload):
		return false
	if payload.get("status", "") not in ["pending", "running"]:
		return false
	for key in ["job_id", "ticket"]:
		var handle = payload.get(key)
		if handle is String and not handle.is_empty():
			return true
	return false
