extends RefCounted
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
## HTTP profiles belong to an endpoint generation. No failed tool call is replayed:
## a missing reply after submission does not prove that execution did not occur.
const Request = preload("res://Scripts/Services/MCP/MCPHttpRequest.gd")
const Headers = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")
const Negotiation = preload("res://Scripts/Services/MCP/MCPStdioNegotiation.gd")
const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const Adapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
signal request_notification(message: Dictionary, request_id: Variant)
var profile = Profile.new()
var endpoint := ""
var session := ""
var generation := 0
var _counter := 0
var _active: Dictionary = {}

func disconnect_transport() -> void:
	generation += 1
	profile = Profile.new()
	session = ""
	var previous := _active.values()
	_active.clear()
	for request in previous:
		request.cancel("HTTP connection disconnected")

func configure_custom(url: String) -> void:
	disconnect_transport()
	endpoint = url
	profile = Profile.custom(generation)
	profile.protocol_version = "2025-06-18"

func cancel_active() -> void:
	var previous := _active.values()
	_active.clear()
	for request in previous:
		request.cancel()

func _id() -> String:
	_counter += 1
	return "http-%d-%d" % [generation, _counter]

func connect_endpoint(url: String, working_directory: String = "") -> Dictionary:
	disconnect_transport()
	endpoint = url
	var owner := generation
	var startup_end := Time.get_ticks_msec() + 12000
	var probe: Dictionary = await _send(Negotiation.discovery_request(_id()), Protocol.MODERN_VERSION, {}, 5.0)
	if owner != generation:
		return {"error": "HTTP connection superseded"}
	var classified := Negotiation.classify_discovery(probe)
	if classified.modern:
		profile = Profile.modern({}, owner)
		if classified.has("error"):
			var failure := probe.duplicate()
			failure["error"] = classified.error
			return failure
		profile = Profile.modern(classified.result.capabilities, owner)
		return {"result": classified.result}
	# Only the harmless probe may fall back. Invalid/unsafe wire data must not
	# be disguised as legacy, nor may authentication or service failures retry.
	if probe.has("validation") or probe.get("status", 0) in [401, 403, 429] \
			or int(probe.get("status", 0)) >= 500:
		return probe
	var probe_status: int = int(probe.get("status", 0))
	var legacy_rejection: bool = probe_status in [0, 400, 404, 405] or probe.get("rpc_error", {}).get("code") == -32601
	if not legacy_rejection:
		return probe
	var initialized: Dictionary = await _send(Negotiation.legacy_initialize_request(_id(), working_directory), "2025-06-18", {}, maxf(0.001, float(startup_end - Time.get_ticks_msec()) / 1000.0))
	if owner != generation:
		return {"error": "HTTP connection superseded"}
	var validated := Negotiation.validate_legacy_initialize(initialized)
	if validated.has("error"):
		return validated
	profile = Profile.legacy(validated.result.protocolVersion, validated.result.capabilities, owner)
	for header: String in initialized.get("headers", PackedStringArray()):
		if header.to_lower().begins_with("mcp-session-id:"):
			session = header.substr(15).strip_edges()
	var acknowledged: Dictionary = await _send({"jsonrpc": "2.0", "method": "notifications/initialized"}, profile.protocol_version, {}, maxf(0.001, float(startup_end - Time.get_ticks_msec()) / 1000.0))
	if owner != generation:
		return {"error": "HTTP connection superseded"}
	return acknowledged if acknowledged.has("error") else validated

func request_method(method: String, params: Dictionary, schema: Variant = {}, context = null) -> Dictionary:
	if profile.era == Profile.Era.UNKNOWN:
		return {"error": "HTTP MCP connection is not negotiated"}
	var request := {"jsonrpc": "2.0", "id": _id(), "method": method, "params": params}
	if profile.era == Profile.Era.MODERN_2026_07_28:
		request = Negotiation.modern_request(method, request.id, params)
		if method in ["tools/call", "tools/list"] and not profile.supports("tools"):
			return {"error": "HTTP peer does not advertise tools"}
	return await _send(request, profile.protocol_version, schema, context.remaining_seconds() if context != null else 120.0, context)

func _send(message: Dictionary, version: String, schema: Variant, timeout: float, context = null) -> Dictionary:
	if _active.size() >= 32:
		return {"error": "HTTP request admission limit reached", "error_code": "queue_full"}
	if context != null and context.is_stopped():
		return context.stopped_result()
	var built := Headers.build(message, schema, version, session if version != Protocol.MODERN_VERSION else "")
	if built.has("error"):
		return built
	var owner := generation
	var expires := Time.get_ticks_msec() + int(ceil(timeout * 1000.0))
	var request = Request.new()
	_active[request.get_instance_id()] = request
	request.request_notification.connect(_on_request_notification.bind(owner, request.get_instance_id()))
	# Gate outbound Dictionary adaptation too; an unsafe integer must not reach
	# a tool simply because it originated in native rather than HTTP code.
	var serialized := JsonSerialization.encode(message)
	if not serialized.ok:
		_active.erase(request.get_instance_id())
		return {"error": serialized.error.message, "validation": serialized}
	var raw: String = serialized.raw
	var parsed: Variant = JSON.parse_string(raw)
	var numeric: Dictionary = await Adapter.validate_for_application(Wire.create(raw, parsed))
	if owner != generation or request.done:
		return {"error": "HTTP request cancelled before dispatch"}
	if context != null and context.is_stopped():
		_active.erase(request.get_instance_id())
		return context.stopped_result()
	if not numeric.get("ok", false):
		_active.erase(request.get_instance_id())
		return {"error": "Unsafe outgoing numeric representation", "validation": numeric}
	var remaining := float(expires - Time.get_ticks_msec()) / 1000.0
	if remaining <= 0.0:
		_active.erase(request.get_instance_id())
		return {"error": "HTTP deadline exceeded before submission", "error_code": "deadline_exceeded"}
	var response: Dictionary = await request.execute(endpoint, built.headers, message, raw.to_utf8_buffer(), minf(remaining, context.remaining_seconds()) if context != null else remaining, context)
	if _active.get(request.get_instance_id()) == request:
		_active.erase(request.get_instance_id())
	if owner != generation:
		return {"error": "HTTP response belongs to an old connection"}
	return response

func _on_request_notification(message: Dictionary, rpc_id: Variant, owner: int, request_id: int) -> void:
	if owner == generation and _active.has(request_id):
		request_notification.emit(message, rpc_id)
