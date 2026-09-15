class_name MCPToolResult
extends RefCounted
## Lossless MCP result envelope plus deliberate adapters for application callers.

var original_result: Dictionary = {}
var wire_value = null
var result_type := "complete"
var legacy_missing_result_type := false


static func from_mcp(value: Dictionary, modern_peer: bool, source_wire = null):
	var parsed = load("res://Scripts/Services/MCP/MCPToolResult.gd").new()
	parsed.original_result = value.duplicate(true)
	parsed.wire_value = source_wire
	if value.has("resultType"):
		parsed.result_type = str(value.resultType)
	elif modern_peer:
		parsed.legacy_missing_result_type = true
	if parsed.result_type not in ["complete", "input_required"]:
		parsed.result_type = "unsupported"
	return parsed


func to_mcp_format(repair_modern: bool = false) -> Dictionary:
	var value := original_result.duplicate(true)
	if repair_modern and not value.has("resultType"):
		value["resultType"] = result_type
	return value


func to_application_result() -> Dictionary:
	if result_type == "unsupported":
		return {"success": false, "error": "Unsupported MCP resultType"}
	if result_type == "input_required":
		var unsupported := {"success": false, "error": "MCP tool requires unsupported caller input",
			"error_code": "input_required"}
		if original_result.has("requestState"):
			unsupported["requestState"] = original_result.requestState
		return unsupported
	var result := original_result.duplicate(true)
	result.erase("resultType")
	if result.has("isError"):
		result["success"] = not bool(result.isError)
	elif not result.has("success") and (result.has("content") or result.has("structuredContent")):
		result["success"] = true
	return result
