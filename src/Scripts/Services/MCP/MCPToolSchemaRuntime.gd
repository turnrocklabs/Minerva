class_name MCPToolSchemaRuntime
extends RefCounted
## Native MCP schemas are compiled for one bounded operation, then released.
## This avoids retaining thousands of catalog handles or racing cache eviction.

const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const MAX_ACTIVE := 32

static var _active := 0


static func check_schema(schema: Variant) -> Dictionary:
	var acquired: Dictionary = await _compile(schema)
	if not acquired.get("ok", false):
		return acquired
	var client = acquired.client
	var released: Dictionary = await client.release(acquired.handle)
	_active -= 1
	return {"ok": true} if released.get("ok", false) else released


static func validate(schema: Variant, value: Variant) -> Dictionary:
	var acquired: Dictionary = await _compile(schema)
	if not acquired.get("ok", false):
		return acquired
	var encoded := JsonSerialization.encode(value)
	var result: Dictionary
	if encoded.get("ok", false):
		result = await acquired.client.validate_raw(acquired.handle, encoded.raw)
	else:
		result = encoded
	var released: Dictionary = await acquired.client.release(acquired.handle)
	_active -= 1
	if not result.get("ok", false):
		return result
	if not released.get("ok", false):
		return released
	var valid_value: Variant = result.get("valid")
	if not valid_value is bool:
		return {"ok": false, "error": {"code": "invalid_validator_response",
			"message": "JSON Schema validator omitted its Boolean valid result",
			"validation": result.duplicate(true)}}
	if valid_value == false:
		return {"ok": false, "valid": false, "error": {
			"code": "schema_mismatch", "message": "Value does not match the JSON Schema",
			"validation": result.duplicate(true)}}
	return result


## Return the authoritative schema with an argument refusal when it fits a
## bounded recovery receipt. Never coerce values or weaken validation here.
static func input_failure(schema: Variant, validation: Dictionary, message: String) -> Dictionary:
	var result := {"success": false, "error": message,
		"error_code": str(validation.get("error", {}).get("code", "invalid_arguments")),
		"retry_hint": "Correct the arguments against this tool's native input schema before retrying. A schema mismatch does not mean the tool is unavailable."}
	if result.error_code != "schema_mismatch":
		result.erase("retry_hint")
		result["validation_error"] = str(validation.get("error", {}).get("message", "Input validation failed"))
		return result
	var encoded := JSON.stringify(schema)
	if encoded.length() <= 6000:
		result["input_schema"] = schema
	else:
		result["retry_hint"] += " The schema exceeds this receipt's size limit; rediscover the exact tool with minerva_tool_search to inspect its parameters."
	return result


static func _compile(schema: Variant) -> Dictionary:
	if _active >= MAX_ACTIVE:
		return _failure("queue_full", "MCP schema validation queue is full")
	var encoded := JsonSerialization.encode(schema)
	if not encoded.get("ok", false):
		return encoded
	var client = WireAdapter.validator_client()
	if client == null:
		return _failure("validator_unavailable", "JSON Schema validator is unavailable")
	_active += 1
	var compiled: Dictionary = await client.compile(encoded.raw)
	if not compiled.get("ok", false):
		_active -= 1
	if compiled.get("ok", false):
		compiled["client"] = client
	return compiled


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}
