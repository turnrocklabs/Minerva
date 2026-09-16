class_name MCPUnsupportedOperationGuard
extends RefCounted
## Per agent turn, remember a document's explicit non-retryable operation
## refusal. The first result reaches the model so it can choose the advertised
## alternative; a later equivalent request is stopped before tool execution.

var _unsupported: Dictionary = {}


func record_result(tool_name: String, live_identity: Dictionary,
		result: Dictionary, round_index: int) -> void:
	if str(result.get("error_code", "")) != "operation_unsupported" \
			or bool(result.get("retryable", true)):
		return
	var result_identity: Variant = result.get("document_identity", {})
	var identity: Dictionary = result_identity if result_identity is Dictionary else {}
	var document_id := str(live_identity.get("document_id",
		identity.get("document_id", ""))).strip_edges()
	if document_id.is_empty():
		return
	var key := "%s|%s" % [tool_name, document_id]
	_unsupported[key] = {
		"round": round_index,
		"next_tool": str(result.get("next_tool", "")),
		"identity": identity.duplicate(true),
	}


func blocked_result(tool_name: String, live_identity: Dictionary,
		round_index: int) -> Dictionary:
	var document_id := str(live_identity.get("document_id", "")).strip_edges()
	if document_id.is_empty():
		return {}
	var key := "%s|%s" % [tool_name, document_id]
	if not _unsupported.has(key):
		return {}
	var refusal: Dictionary = _unsupported[key]
	# Calls emitted together have not yet exposed the refusal to the model.
	if round_index <= int(refusal.get("round", round_index)):
		return {}
	var next_tool := str(refusal.get("next_tool", ""))
	var message := ("Stopped a repeated %s call because this document already reported "
		+ "that operation as non-retryable") % tool_name
	if not next_tool.is_empty():
		message += "; use %s" % next_tool
	return {
		"success": false,
		"error": message,
		"error_message": message,
		"error_code": "repeated_unsupported_operation",
		"retryable": false,
		"next_tool": next_tool,
		"document_identity": (refusal.get("identity", {}) as Dictionary).duplicate(true),
		"blocked": true,
		"terminate_tool_loop": true,
	}
