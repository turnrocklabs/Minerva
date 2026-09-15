class_name MCPToolResultAdapter
extends RefCounted
## Converts a validated MCP result into the legacy application payload. JSON
## embedded in a text part is a second wire boundary and is validated before use.

const Outcome = preload("res://Scripts/Services/MCP/MCPToolCallOutcome.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")


static func adapt(envelope) -> MCPToolCallOutcome:
	var outcome := Outcome.new()
	outcome.envelope = envelope
	if envelope == null:
		outcome.application = {"success": false, "error": "MCP result envelope is missing",
			"error_code": "missing_result"}
		return outcome
	if envelope.legacy_missing_result_type:
		outcome.conformance_errors.append("Modern MCP result omitted resultType")
	var base: Dictionary = envelope.to_application_result()
	if envelope.result_type != "complete":
		outcome.application = base
		return outcome
	var content_value: Variant = base.get("content")
	if content_value is String:
		outcome.application = {"text": content_value, "success": not bool(base.get("isError", false))}
		return outcome
	if not content_value is Array or content_value.is_empty() or not content_value[0] is Dictionary:
		outcome.application = base
		return outcome
	var first: Dictionary = content_value[0]
	if first.get("type") != "text":
		outcome.application = base
		return outcome
	var text: String = str(first.get("text", ""))
	var parser := JSON.new()
	if parser.parse(text) != OK:
		outcome.application = {"text": text, "success": not bool(base.get("isError", false))}
		return outcome
	var numeric: Dictionary = await WireAdapter.validate_for_application(Wire.create(text, parser.data))
	if not numeric.get("ok", false):
		var detail: Dictionary = numeric.get("error", {})
		outcome.application = {"success": false,
			"error": "Unsafe numeric representation in MCP text result",
			"error_code": str(detail.get("code", "numeric_validation_failed"))}
		return outcome
	if parser.data is Dictionary:
		outcome.application = parser.data.duplicate(true)
	else:
		outcome.application = {"result": parser.data}
	if base.get("isError", false):
		outcome.application["success"] = false
	elif not outcome.application.has("success"):
		outcome.application["success"] = not outcome.application.has("error")
	return outcome
