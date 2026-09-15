class_name MCPToolCallOutcome
extends RefCounted
## One call's lossless protocol result and its deliberate application view.

var envelope = null
var application: Dictionary = {}
var conformance_errors: Array[String] = []


static func failure(message: String, code: String = ""):
	var outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	outcome.application = {"success": false, "error": message}
	if not code.is_empty():
		outcome.application["error_code"] = code
	return outcome


static func from_error(value: Dictionary):
	var outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	outcome.application = value.duplicate(true)
	if not outcome.application.has("success"):
		outcome.application["success"] = false
	return outcome
