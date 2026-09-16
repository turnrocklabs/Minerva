class_name MCPToolCallOutcome
extends RefCounted
## One call's lossless protocol result and its deliberate application view.

var envelope = null
var application: Dictionary = {}
var conformance_errors: Array[String] = []
## True only when MCPToolResultAdapter added the application-level `success`
## field. Consumers can distinguish that compatibility field from a backend's
## explicit scene envelope without reparsing validated wire text.
var application_success_synthesized := false
## Host-native results validated against a declared outputSchema. This is
## separate from peer envelopes: native panel execution never fabricates an
## upstream MCP result or wire authority.
var validated_structured_content: Variant = null
## False when host validation, policy, capability processing, or wrappers changed
## the application result after the peer envelope was received.
var wire_authoritative := true


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
