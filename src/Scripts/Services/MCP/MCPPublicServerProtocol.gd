class_name MCPPublicServerProtocol
extends RefCounted
## Dual-era request classification and modern result metadata for the local host.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

const VERSION_ERROR := -32022
const CAPABILITY_ERROR := -32021
const HEADER_ERROR := -32020


static func classify(request: Dictionary, protocol_header: String = "") -> Dictionary:
	var shape_error := Protocol.validate_request(request)
	if not shape_error.is_empty():
		return _failure(-32600, shape_error)
	var method: String = request.method
	var params: Dictionary = request.get("params", {})
	var possible_meta: Variant = params.get("_meta")
	var declares_modern: bool = method == "server/discover" or protocol_header == Protocol.MODERN_VERSION \
		or (possible_meta is Dictionary \
		and possible_meta.has("io.modelcontextprotocol/protocolVersion"))
	if method == "initialize" or not declares_modern:
		return {"ok": true, "modern": false, "method": method}
	if protocol_header.is_empty():
		return _failure(HEADER_ERROR, "MCP-Protocol-Version header is required")
	var meta: Variant = params.get("_meta")
	if not meta is Dictionary:
		return _failure(-32602, "Modern requests require params._meta")
	var version: Variant = meta.get("io.modelcontextprotocol/protocolVersion")
	if not version is String:
		return _failure(-32602, "Modern protocolVersion must be a string")
	if protocol_header != version:
		return _failure(HEADER_ERROR,
			"MCP-Protocol-Version header must match request metadata")
	if version != Protocol.MODERN_VERSION:
		return _failure(VERSION_ERROR, "Unsupported MCP protocol version", {
			"supported": [Protocol.MODERN_VERSION], "requested": version})
	var capabilities: Variant = meta.get("io.modelcontextprotocol/clientCapabilities")
	if not capabilities is Dictionary:
		return _failure(-32602, "Modern clientCapabilities must be an object")
	return {"ok": true, "modern": true, "method": method,
		"capabilities": capabilities}


static func discovery_result() -> Dictionary:
	return {
		"resultType": "complete",
		"ttlMs": 0,
		"cacheScope": "private",
		"supportedVersions": [Protocol.MODERN_VERSION],
		"capabilities": {
			"tools": {"listChanged": false},
		},
		"_meta": {"io.modelcontextprotocol/serverInfo": {
			"name": "Minerva", "version": "1.0.0"}},
	}


static func complete_result(result: Dictionary) -> Dictionary:
	var stamped := result.duplicate(true)
	stamped["resultType"] = "complete"
	return stamped


static func subscription_messages(request_id: Variant) -> Array[Dictionary]:
	var subscription_meta := {"io.modelcontextprotocol/subscriptionId": request_id}
	return [{
		"jsonrpc": Protocol.JSON_RPC_VERSION,
		"method": "notifications/subscriptions/acknowledged",
		"params": {"_meta": subscription_meta.duplicate(true), "notifications": {}},
	}, {
		"jsonrpc": Protocol.JSON_RPC_VERSION,
		"id": request_id,
		"result": {"resultType": "complete", "_meta": subscription_meta},
	}]


static func validate_subscription_params(params: Dictionary) -> String:
	var notifications: Variant = params.get("notifications")
	if not notifications is Dictionary:
		return "subscriptions/listen notifications must be an object"
	for key: Variant in notifications:
		if not key is String:
			return "subscription filter keys must be strings"
		if key in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"] \
				and not notifications[key] is bool:
			return "%s must be Boolean" % key
		if key == "resourceSubscriptions":
			if not notifications[key] is Array:
				return "resourceSubscriptions must be an array"
			for uri: Variant in notifications[key]:
				if not uri is String:
					return "resourceSubscriptions entries must be strings"
	return ""


static func _failure(code: int, message: String, data: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "message": message}
	if not data.is_empty():
		error["data"] = data
	return {"ok": false, "error": error}
