class_name MCPToolResultAdapter
extends RefCounted
## Converts a validated MCP result into the legacy application payload. JSON
## embedded in a text part is a second wire boundary and is validated before use.

const Outcome = preload("res://Scripts/Services/MCP/MCPToolCallOutcome.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const ApplicationError = preload("res://Scripts/Services/MCP/MCPApplicationError.gd")


static func adapt(envelope) -> MCPToolCallOutcome:
	var outcome := Outcome.new()
	outcome.envelope = envelope
	if envelope == null:
		return _finish(outcome, {"success": false, "error": "MCP result envelope is missing",
			"error_code": "missing_result"})
	if envelope.legacy_missing_result_type:
		outcome.conformance_errors.append("Modern MCP result omitted resultType")
	var base: Dictionary = envelope.to_application_result()
	if envelope.result_type != "complete":
		return _finish(outcome, base)
	var content_value: Variant = base.get("content")
	if content_value is String:
		outcome.application_success_synthesized = true
		return _finish(outcome, {"text": content_value,
			"success": not bool(base.get("isError", false))})
	if not content_value is Array or content_value.is_empty() or not content_value[0] is Dictionary:
		return _finish(outcome, base)
	var first: Dictionary = content_value[0]
	if first.get("type") != "text":
		return _finish(outcome, base)
	var text: String = str(first.get("text", ""))
	var parser := JSON.new()
	if parser.parse(text) != OK:
		outcome.application_success_synthesized = true
		return _finish(outcome, {"text": text,
			"success": not bool(base.get("isError", false))})
	var inner_wire = Wire.create(text, parser.data)
	var numeric: Dictionary = await WireAdapter.validate_for_application(inner_wire)
	if not numeric.get("ok", false):
		var detail: Dictionary = numeric.get("error", {})
		var rejected := {"success": false,
			"error": "Unsafe numeric representation in MCP text result",
			"error_code": str(detail.get("code", "numeric_validation_failed"))}
		if detail.get("details") is Dictionary:
			rejected["error_details"] = (detail["details"] as Dictionary).duplicate(true)
		return _finish(outcome, rejected)
	if inner_wire.parsed is Dictionary:
		outcome.application = inner_wire.parsed.duplicate(true)
	else:
		outcome.application = {"result": inner_wire.parsed}
	if base.get("isError", false):
		outcome.application["success"] = false
	elif not outcome.application.has("success"):
		outcome.application_success_synthesized = true
		outcome.application["success"] = not outcome.application.has("error")
	return _finish(outcome, outcome.application)


## Error producers historically chose either `error` or `error_message`.
## Application consumers receive both text aliases while structured error data
## and bounded diagnostics remain intact.
static func normalize_application_error(value: Dictionary) -> Dictionary:
	return ApplicationError.normalize(value)


static func _finish(outcome: MCPToolCallOutcome, value: Dictionary) -> MCPToolCallOutcome:
	outcome.application = normalize_application_error(value)
	return outcome
