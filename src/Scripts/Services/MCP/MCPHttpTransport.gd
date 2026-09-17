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
signal catalog_watch_message(message: Dictionary, generation: int)
signal catalog_watch_closed(result: Dictionary, generation: int)
var profile = Profile.new()
var endpoint := ""
var session := ""
var generation := 0
var _counter := 0
var _active: Dictionary = {}
var _watch_request = null

func disconnect_transport() -> void:
	generation += 1
	profile = Profile.new()
	session = ""
	var previous := _active.values()
	_active.clear()
	for request in previous:
		request.cancel("HTTP connection disconnected")
	var previous_watch = _watch_request
	_watch_request = null
	if previous_watch != null:
		previous_watch.cancel("HTTP connection disconnected")

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


func start_tools_watch(request_id: Variant) -> bool:
	var tools_capability: Variant = profile.capabilities.get("tools")
	if profile.era != Profile.Era.MODERN_2026_07_28 \
			or not tools_capability is Dictionary \
			or tools_capability.get("listChanged") != true:
		return false
	if _watch_request != null:
		_watch_request.cancel("HTTP catalog watch replaced")
	var message := Negotiation.modern_request("subscriptions/listen", request_id,
		{"notifications": {"toolsListChanged": true}})
	var built := Headers.build(message, {}, profile.protocol_version, "")
	if built.has("error"):
		return false
	var serialized := JsonSerialization.encode(message)
	if not serialized.get("ok", false):
		return false
	var request = Request.new()
	_watch_request = request
	var owner := generation
	request.request_notification.connect(func(notification: Dictionary,
			_request_id: Variant) -> void:
		if owner == generation and _watch_request == request:
			catalog_watch_message.emit(notification, owner))
	_run_tools_watch(request, owner, message, built.headers,
		str(serialized.raw).to_utf8_buffer())
	return true


func stop_tools_watch(reason: String = "HTTP catalog watch stopped") -> void:
	var previous = _watch_request
	_watch_request = null
	if previous != null:
		previous.cancel(reason)


func _run_tools_watch(request, owner: int, message: Dictionary,
		headers: PackedStringArray, body: PackedByteArray) -> void:
	var result: Dictionary = await request.execute(endpoint, headers, message, body,
		10.0, null, true)
	if owner != generation or _watch_request != request:
		return
	_watch_request = null
	catalog_watch_closed.emit(result, owner)

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
	var probe_rpc_code: int = int(probe.get("rpc_error", {}).get("code", 0))
	# A legacy session server can parse the harmless discovery POST but reject
	# the unknown method as either Invalid Request or Method Not Found. The
	# structured status/code pair is fallback evidence; peer message text is not.
	var legacy_rejection: bool = probe_status in [0, 400, 404, 405] \
		or (probe_status in [200, 400, 404, 405] and probe_rpc_code in [-32600, -32601])
	if not legacy_rejection:
		return probe
	var initialized: Dictionary = await _send(Negotiation.legacy_initialize_request(_id(), working_directory), "2025-06-18", {}, maxf(0.001, float(startup_end - Time.get_ticks_msec()) / 1000.0))
	if owner != generation:
		return {"error": "HTTP connection superseded"}
	var validated := Negotiation.validate_legacy_initialize(initialized)
	if validated.has("error"):
		validated["discovery_fallback"] = {
			"http_status": probe_status,
			"rpc_code": probe_rpc_code,
		}
		validated["initialize_failure"] = _failure_category(initialized)
		return validated
	profile = Profile.legacy(validated.result.protocolVersion, validated.result.capabilities, owner)
	for header: String in initialized.get("headers", PackedStringArray()):
		if header.to_lower().begins_with("mcp-session-id:"):
			session = header.substr(15).strip_edges()
	var acknowledged: Dictionary = await _send({"jsonrpc": "2.0", "method": "notifications/initialized"}, profile.protocol_version, {}, maxf(0.001, float(startup_end - Time.get_ticks_msec()) / 1000.0))
	if owner != generation:
		return {"error": "HTTP connection superseded"}
	return acknowledged if acknowledged.has("error") else validated


static func _failure_category(response: Dictionary) -> Dictionary:
	var category := {"http_status": int(response.get("status", 0))}
	var rpc_error: Variant = response.get("rpc_error")
	if rpc_error is Dictionary:
		category["rpc_code"] = int(rpc_error.get("code", 0))
	elif response.has("validation"):
		category["kind"] = "numeric_validation"
	else:
		category["kind"] = "invalid_initialize"
	return category

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
