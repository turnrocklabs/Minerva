class_name MCPStdioNegotiation
extends RefCounted
## Pure request construction and response classification for the STDIO profile
## handshake. The connection owns I/O, deadlines, and process generations.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

const MODERN_ERROR_CODES: Array[int] = [-32022, -32021, -32020, -32602]
const LEGACY_VERSIONS: Array[String] = ["2025-06-18", "2025-03-26", "2024-11-05"]


static func discovery_request(request_id: Variant) -> Dictionary:
	return {
		"jsonrpc": Protocol.JSON_RPC_VERSION,
		"id": request_id,
		"method": "server/discover",
		"params": {
			"_meta": Protocol.modern_meta(Protocol.MODERN_VERSION, {}),
		},
	}


static func legacy_initialize_request(request_id: Variant, working_directory: String = "") -> Dictionary:
	var params := {
		"protocolVersion": "2025-06-18",
		"capabilities": {},
		"clientInfo": {"name": "Minerva", "version": "1.0.0"},
	}
	if not working_directory.is_empty():
		params["workingDirectory"] = working_directory
	return {
		"jsonrpc": Protocol.JSON_RPC_VERSION,
		"id": request_id,
		"method": "initialize",
		"params": params,
	}


static func modern_request(method: String, request_id: Variant, params: Dictionary) -> Dictionary:
	var modern_params := params.duplicate(true)
	var caller_meta: Dictionary = modern_params.get("_meta", {}) if modern_params.get("_meta", {}) is Dictionary else {}
	caller_meta.merge(Protocol.modern_meta(Protocol.MODERN_VERSION, {}), true)
	modern_params["_meta"] = caller_meta
	return {"jsonrpc": Protocol.JSON_RPC_VERSION, "id": request_id,
		"method": method, "params": modern_params}


static func classify_discovery(response: Dictionary) -> Dictionary:
	if response.has("rpc_error"):
		var rpc_error: Dictionary = response.rpc_error
		var code: int = int(rpc_error.get("code", 0))
		return {"modern": code in MODERN_ERROR_CODES, "fallback": code not in MODERN_ERROR_CODES,
			"error": str(rpc_error.get("message", "Discovery failed")), "error_code": code}
	if response.has("error"):
		return {"modern": false, "fallback": true, "error": str(response.error)}
	var result_value: Variant = response.get("result")
	if not result_value is Dictionary:
		return {"modern": true, "fallback": false, "error": "server/discover result must be an object"}
	var result: Dictionary = result_value
	if not result.get("supportedVersions") is Array or result.supportedVersions.is_empty():
		return {"modern": true, "fallback": false,
			"error": "server/discover supportedVersions must be a non-empty array"}
	for version: Variant in result.supportedVersions:
		if not version is String or String(version).is_empty():
			return {"modern": true, "fallback": false,
				"error": "server/discover supportedVersions contains an invalid version"}
	if Protocol.MODERN_VERSION not in result.supportedVersions:
		return {"modern": true, "fallback": false,
			"error": "server/discover does not support protocolVersion %s" % Protocol.MODERN_VERSION}
	if not result.get("capabilities") is Dictionary:
		return {"modern": true, "fallback": false, "error": "server/discover capabilities must be an object"}
	var capabilities: Dictionary = result.capabilities
	if capabilities.has("tools") and not capabilities.tools is Dictionary:
		return {"modern": true, "fallback": false,
			"error": "server/discover tools capability must be an object"}
	if result.get("resultType") != "complete":
		return {"modern": true, "fallback": false, "error": "server/discover resultType must be complete"}
	var ttl: Variant = result.get("ttlMs")
	if (not ttl is int and not ttl is float) or not is_finite(float(ttl)) \
			or float(ttl) < 0.0 or float(ttl) > Protocol.MAX_SAFE_INTEGER:
		return {"modern": true, "fallback": false,
			"error": "server/discover ttlMs must be a safe non-negative number"}
	if result.get("cacheScope") not in ["public", "private"]:
		return {"modern": true, "fallback": false, "error": "server/discover cacheScope is invalid"}
	if result.has("_meta"):
		if not result._meta is Dictionary:
			return {"modern": true, "fallback": false, "error": "server/discover _meta must be an object"}
		var server_info: Variant = result._meta.get("io.modelcontextprotocol/serverInfo")
		if server_info != null and (not server_info is Dictionary \
				or not server_info.get("name") is String or String(server_info.name).is_empty() \
				or not server_info.get("version") is String or String(server_info.version).is_empty()):
			return {"modern": true, "fallback": false, "error": "server/discover serverInfo is incomplete"}
	return {"modern": true, "fallback": false, "result": result}


static func validate_legacy_initialize(response: Dictionary,
		allow_hosted_plugin_identity_aliases: bool = false) -> Dictionary:
	if response.has("error"):
		return {"error": str(response.error)}
	var result_value: Variant = response.get("result")
	if not result_value is Dictionary:
		return {"error": "initialize result must be an object"}
	var result: Dictionary = result_value
	if not result.get("protocolVersion") is String:
		return {"error": "initialize protocolVersion must be a string"}
	var version: String = result.protocolVersion
	if version not in LEGACY_VERSIONS:
		return {"error": "initialize returned unsupported protocolVersion '%s'" % version}
	if not result.get("capabilities") is Dictionary:
		return {"error": "initialize result is missing capabilities or serverInfo"}
	if not result.get("serverInfo") is Dictionary and allow_hosted_plugin_identity_aliases:
		var legacy_name: Variant = result.get("serverName")
		var legacy_version: Variant = result.get("serverVersion")
		if legacy_name is String and not String(legacy_name).is_empty() \
				and legacy_version is String and not String(legacy_version).is_empty():
			result = result.duplicate(true)
			result["serverInfo"] = {"name": legacy_name, "version": legacy_version}
	if not result.get("serverInfo") is Dictionary:
		return {"error": "initialize result is missing capabilities or serverInfo"}
	var server_info: Dictionary = result.serverInfo
	if not server_info.get("name") is String or String(server_info.name).is_empty() \
			or not server_info.get("version") is String or String(server_info.version).is_empty():
		return {"error": "initialize serverInfo is incomplete"}
	return {"result": result}
