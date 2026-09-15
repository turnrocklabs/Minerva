class_name MCPProtocol
extends RefCounted
## Shape checks shared by MCP transports. Domain payloads remain untouched.

const JSON_RPC_VERSION := "2.0"
const MODERN_VERSION := "2026-07-28"
const MAX_SAFE_INTEGER := 9007199254740991


static func valid_request_id(value: Variant) -> bool:
	if value is String:
		return true
	if value is int:
		return value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER
	if value is float:
		return is_finite(value) and value == floor(value) \
			and value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER
	return false


static func request_id_key(value: Variant) -> String:
	if not valid_request_id(value):
		return ""
	return ("s:" + value) if value is String else ("i:" + str(int(value)))


static func validate_request(message: Dictionary) -> String:
	if message.get("jsonrpc") != JSON_RPC_VERSION:
		return "jsonrpc must be 2.0"
	if not message.get("method") is String or String(message.method).is_empty():
		return "method must be a non-empty string"
	if message.has("id") and not valid_request_id(message.id):
		return "id must be a string or safe integer"
	if message.has("params") and not message.params is Dictionary:
		return "params must be an object"
	return ""


static func validate_response(message: Dictionary, expected_id: Variant) -> String:
	if message.get("jsonrpc") != JSON_RPC_VERSION:
		return "jsonrpc must be 2.0"
	if not message.has("id") or not valid_request_id(message.id) or not valid_request_id(expected_id):
		return "response id is invalid"
	if request_id_key(message.id) != request_id_key(expected_id):
		return "response id does not match its request"
	if message.has("result") == message.has("error"):
		return "response must contain exactly one of result or error"
	if message.has("error"):
		var error_value: Variant = message.error
		if not error_value is Dictionary or not _valid_error_code(error_value.get("code")) \
				or not error_value.get("message") is String:
			return "error must contain integer code and string message"
	elif not message.result is Dictionary:
		return "result must be an object"
	return ""


static func modern_meta(version: String, capabilities: Dictionary) -> Dictionary:
	return {"io.modelcontextprotocol/protocolVersion": version,
		"io.modelcontextprotocol/clientCapabilities": capabilities.duplicate(true)}


static func _valid_error_code(value: Variant) -> bool:
	return (value is int and value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER) \
		or (value is float and is_finite(value) and value == floor(value)
		and value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER)
