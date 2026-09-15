extends SceneTree

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const Definition = preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const ToolResult = preload("res://Scripts/Services/MCP/MCPToolResult.gd")
const WireValue = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const RequestIds = preload("res://Scripts/Services/MCP/MCPRequestIds.gd")
const StdioNegotiation = preload("res://Scripts/Services/MCP/MCPStdioNegotiation.gd")

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _run() -> void:
	check("string and safe integer IDs remain distinct typed identities",
		Protocol.request_id_key("7") == "s:7" and Protocol.request_id_key(7) == "i:7")
	check("null fractional bool and unsafe IDs are rejected while empty string remains valid",
		not Protocol.valid_request_id(null) and not Protocol.valid_request_id(1.5)
		and not Protocol.valid_request_id(true) and Protocol.valid_request_id("")
		and not Protocol.valid_request_id(9007199254740992))
	var ids := RequestIds.new()
	check("request ownership rejects duplicates while retaining typed distinctions",
		ids.admit("1") and not ids.admit("1") and ids.admit(1) and ids.size() == 2
		and ids.release("1") and ids.contains(1) and not ids.contains("1"))
	check("request shape rejects malformed params",
		Protocol.validate_request({"jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": []}) != "")
	check("response requires exact typed correlation and one outcome",
		Protocol.validate_response({"jsonrpc": "2.0", "id": "a", "result": {}}, "a") == ""
		and Protocol.validate_response({"jsonrpc": "2.0", "id": 1, "result": {}}, "1") != ""
		and Protocol.validate_response({"jsonrpc": "2.0", "id": "a", "result": {}, "error": {}}, "a") != "")
	var decoded_response: Dictionary = JSON.parse_string(
		'{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"invalid"}}')
	check("real JSON-decoded integral IDs and error codes remain valid",
		Protocol.validate_response(decoded_response, 7) == "")
	check("invalid IDs and scalar results are rejected before correlation",
		Protocol.validate_response({"jsonrpc": "2.0", "id": null, "result": {}}, null) != ""
		and Protocol.validate_response({"jsonrpc": "2.0", "id": "a", "result": 4}, "a") != ""
		and Protocol.validate_response({"jsonrpc": "2.0", "id": "a",
			"error": {"code": 9007199254740992, "message": "unsafe"}}, "a") != "")
	var profile = Profile.modern({"tools": {}}, 4)
	check("modern profile pins era version capability and generation",
		profile.era == Profile.Era.MODERN_2026_07_28 and profile.protocol_version == "2026-07-28"
		and profile.supports("tools") and profile.generation == 4)
	var meta := Protocol.modern_meta("2026-07-28", {})
	check("modern metadata uses namespaced keys and an object capability map",
		meta.has("io.modelcontextprotocol/protocolVersion")
		and meta["io.modelcontextprotocol/clientCapabilities"] is Dictionary
		and meta.get("io.modelcontextprotocol/clientInfo", {}).get("name") == "Minerva")
	var discover := StdioNegotiation.classify_discovery({"result": {
		"resultType": "complete", "ttlMs": 0, "cacheScope": "private",
		"supportedVersions": ["2026-07-28"], "capabilities": {"tools": {}}}})
	check("stdio discovery validates the pinned modern result shape",
		discover.get("modern") and not discover.has("error")
		and discover.result.capabilities.get("tools") is Dictionary)
	check("recognized modern errors never request legacy fallback",
		[-32020, -32021, -32022].all(func(code: int) -> bool:
			var classification := StdioNegotiation.classify_discovery({"error": "modern",
				"rpc_error": {"code": code, "message": "modern"}})
			return classification.get("modern") and not classification.get("fallback")))
	check("method-not-found and probe timeout are legacy fallback evidence",
		StdioNegotiation.classify_discovery({"error": "unknown",
			"rpc_error": {"code": -32601, "message": "unknown"}}).get("fallback")
		and StdioNegotiation.classify_discovery({"error": "timeout"}).get("fallback"))
	var owned_legacy := StdioNegotiation.validate_legacy_initialize({"result": {
		"protocolVersion": "2025-06-18", "capabilities": {},
		"serverName": "scansort", "serverVersion": "0.0.1"}}, true)
	check("hosted legacy plugins retain typed serverName identity compatibility",
		not owned_legacy.has("error")
		and owned_legacy.result.serverInfo == {"name": "scansort", "version": "0.0.1"}
		and StdioNegotiation.validate_legacy_initialize({"result": {
			"protocolVersion": "2025-06-18", "capabilities": {},
			"serverName": "scansort", "serverVersion": "0.0.1"}}).has("error"))
	var raw_definition := "{\"name\":\"probe\",\"inputSchema\":{},\"outputSchema\":{\"type\":\"integer\"},\"future\":7}"
	var definition_value: Dictionary = JSON.parse_string(raw_definition)
	var definition = Definition.from_dict(definition_value, "peer")
	check("tool definition preserves unknown structured fields without schema narrowing",
		definition.original_definition == definition_value and definition.to_mcp_format().future == 7
		and definition.to_mcp_format().has("outputSchema"))
	var raw_result := "{\"resultType\":\"complete\",\"structuredContent\":{\"n\":1},\"future\":true}"
	var decoded_result: Dictionary = JSON.parse_string(raw_result)
	var wire = WireValue.create(raw_result, decoded_result)
	var result = ToolResult.from_mcp(decoded_result, true, wire)
	check("tool result preserves raw bytes and unknown structured fields",
		result.wire_value.forwarding_bytes().get_string_from_utf8() == raw_result
		and result.to_mcp_format().future
		and result.to_application_result().structuredContent.n == 1)
	var legacy = ToolResult.from_mcp({"content": []}, true)
	check("missing modern result discriminator is recorded and repair is explicit",
		legacy.legacy_missing_result_type and not legacy.to_mcp_format().has("resultType")
		and legacy.to_mcp_format(true).resultType == "complete")
	var interaction = ToolResult.from_mcp({"resultType": "input_required", "requestState": "opaque"}, true)
	check("unsupported caller interaction cannot become application success",
		interaction.to_application_result().error_code == "input_required"
		and interaction.to_mcp_format().requestState == "opaque")
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
