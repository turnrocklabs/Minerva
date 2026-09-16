class_name MinervaMCPHttpServer
extends Node

## HTTP server that exposes Minerva's MCP tools to external agents.
## Implements the MCP protocol (JSON-RPC 2.0 over HTTP).

signal server_started(port: int)
signal server_stopped()
signal client_connected(session_id: String)
signal tool_executed(tool_name: String, session_id: String)

const DEFAULT_PORT = 9315
## Bind to the IPv4 loopback only. The MCP endpoint is unauthenticated, so it
## must never be reachable off-host; binding "127.0.0.1" (instead of Godot's
## "*" default = all interfaces) lets the OS reject non-local connections at
## the socket layer.
const BIND_ADDRESS = "127.0.0.1"
const LATEST_PROTOCOL_VERSION = "2025-06-18"
const SUPPORTED_PROTOCOL_VERSIONS = [
	"2025-06-18",
	"2025-03-26",
	"2024-11-05"
]
const CONNECTION_TIMEOUT = 30.0  # seconds
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const PublicProtocol = preload("res://Scripts/Services/MCP/MCPPublicServerProtocol.gd")
const PublicAdmission = preload("res://Scripts/Services/MCP/MCPPublicToolAdmission.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const WireValue = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
const ToolSchemaRuntime = preload("res://Scripts/Services/MCP/MCPToolSchemaRuntime.gd")
const ExportCatalog = preload("res://Scripts/Services/MCP/MCPExportCatalog.gd")
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
const HttpHeaders = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")
const NativeWireAdapter = preload("res://Scripts/Services/MCP/MCPNativeWireAdapter.gd")
const MAX_CONNECTIONS := 64

var _tcp_server: TCPServer = null
var _connections: Array = []  # Array of MinervaMCPHttpConnection
var _sessions: Dictionary = {}  # session_id -> {created_at, last_activity}
var _is_running: bool = false
var _port: int = DEFAULT_PORT
var _inflight_connections: Dictionary = {}  # conn -> true (handling) / false (done)
var _export_catalog = ExportCatalog.new()
var _tool_admission = PublicAdmission.new()
var _active_request_contexts: Dictionary = {}  # request connection -> context

# Reference to the MCP manager and minerva server
var _mcp_manager = null

# Preload the connection class
const MinervaMCPHttpConnectionScript = preload("res://Scripts/Services/MCP/MinervaMCPHttpConnection.gd")


func _ready() -> void:
	_mcp_manager = SingletonObject.get_mcp_manager()


func _process(_delta: float) -> void:
	if not _is_running:
		return

	_accept_new_connections()
	_process_connections()
	_cleanup_stale_sessions()


## Start the HTTP server on the specified port.
func start_server(port: int = DEFAULT_PORT) -> Error:
	if _is_running:
		push_warning("[MCP HTTP] Server already running on port %d" % _port)
		return ERR_ALREADY_IN_USE

	_tcp_server = TCPServer.new()
	var err = _tcp_server.listen(port, BIND_ADDRESS)

	if err != OK:
		push_error("[MCP HTTP] Failed to start server on port %d: %s" % [port, error_string(err)])
		_tcp_server = null
		return err

	_port = port
	if port == 0:
		_port = _tcp_server.get_local_port()
	_is_running = true

	print("[MCP HTTP] Server started on %s:%d" % [BIND_ADDRESS, _port])
	server_started.emit(_port)
	return OK


## Stop the HTTP server.
func stop_server() -> void:
	if not _is_running:
		return

	# Detach ownership before cancellation callbacks can synchronously re-enter.
	var old_connections := _connections.duplicate()
	var old_contexts := _active_request_contexts.values()
	_connections.clear()
	_inflight_connections.clear()
	_active_request_contexts.clear()
	_is_running = false
	var old_server := _tcp_server
	_tcp_server = null
	_sessions.clear()
	if old_server:
		old_server.stop()
	for context in old_contexts:
		context.cancel()
	for conn in old_connections:
		conn.close()
	print("[MCP HTTP] Server stopped")
	server_stopped.emit()


## Check if server is running.
func is_running() -> bool:
	return _is_running


## Get the port the server is running on.
func get_port() -> int:
	return _port if _is_running else 0


func invalidate_tools_catalog(_reason: String = "") -> void:
	_export_catalog.invalidate()


func _accept_new_connections() -> void:
	if not _tcp_server or not _tcp_server.is_connection_available():
		return

	var peer = _tcp_server.take_connection()
	if peer:
		if _connections.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			return
		var conn = MinervaMCPHttpConnectionScript.new(peer)
		_connections.append(conn)


func _process_connections() -> void:
	for conn in _connections.duplicate():
		if not _connections.has(conn):
			continue
		if conn.absolute_deadline_expired() or not conn.is_peer_connected():
			var active_context = _active_request_contexts.get(conn)
			if active_context != null:
				_active_request_contexts.erase(conn)
				active_context.cancel()
			_inflight_connections.erase(conn)
			conn.close()
			_connections.erase(conn)
			continue

		# Skip connections being handled asynchronously
		if _inflight_connections.has(conn):
			if not _inflight_connections[conn]:
				var flush_error: Error = conn.flush_output()
				if flush_error != OK or not conn.has_pending_output() \
						or conn.absolute_deadline_expired():
					_inflight_connections.erase(conn)
					conn.close()
					_connections.erase(conn)
			continue

		# Check for timeout or disconnection
		if conn.is_timed_out(CONNECTION_TIMEOUT) or not conn.is_peer_connected():
			conn.close()
			_connections.erase(conn)
			continue

		# Try to read and process request
		var request = conn.process_data()
		if conn.state == MinervaMCPHttpConnectionScript.ConnectionState.ERROR:
			var status: int = 413 if conn.error_reason.contains("budget") else 400
			if conn.error_reason.contains("ambiguous request authority"):
				_send_jsonrpc_error(conn, null, PublicProtocol.HEADER_ERROR,
					conn.error_reason, {}, 400)
			else:
				_send_error(conn, status, conn.error_reason)
			_inflight_connections[conn] = false
			continue
		if request.is_empty():
			continue

		if conn.state == MinervaMCPHttpConnectionScript.ConnectionState.COMPLETE:
			# Fire-and-forget: handle asynchronously without blocking the loop.
			# This allows other connections to be processed while a tool executes.
			_inflight_connections[conn] = true
			_handle_connection_async(conn, request)

	# Connections are removed by identity so synchronous stop/restart callbacks
	# cannot invalidate numeric indices from this snapshot.


func _cleanup_stale_sessions() -> void:
	var now = Time.get_unix_time_from_system()
	var stale_threshold = 3600.0  # 1 hour

	var to_remove: Array[String] = []
	for session_id in _sessions:
		if now - _sessions[session_id].last_activity > stale_threshold:
			to_remove.append(session_id)

	for session_id in to_remove:
		_sessions.erase(session_id)


## Handle a connection's request asynchronously and clean up when done.
## Called fire-and-forget from _process_connections so other connections aren't blocked.
func _handle_connection_async(conn, request: Dictionary) -> void:
	await _handle_request(conn, request)
	# The response is queued for bounded partial writes on the process loop.
	# Marking the handler done transfers ownership to that flush path.
	if _inflight_connections.has(conn):
		_inflight_connections[conn] = false


func _handle_request(conn, request: Dictionary) -> void:
	var method = request.get("method", "")
	var path = request.get("path", "")
	var body = request.get("body", "")
	var session_id = request.get("session_id", "")
	var headers: Dictionary = request.get("headers", {})
	# Privileged browser documents use the generation-bound native bridge.
	# Reject every browser-originated HTTP request before OPTIONS or routing.
	if headers.has("origin"):
		_send_error(conn, 403, "Browser Origin requests are not accepted")
		return

	if method == "OPTIONS":
		conn.send_response(200, {}, "")
		return

	# Only accept POST to /mcp
	if method != "POST":
		_send_error(conn, 405, "Method not allowed")
		return

	if path != "/mcp" and path != "/":
		_send_error(conn, 404, "Not found")
		return

	# Parse JSON body
	var json = JSON.new()
	var parse_result = json.parse(body)
	if parse_result != OK:
		_send_jsonrpc_error(conn, null, -32700, "Parse error")
		return

	var json_body = json.data
	if not json_body is Dictionary:
		_send_jsonrpc_error(conn, null, -32600, "Invalid request")
		return

	# Godot's decoder can round source numbers. The shared native gate repairs
	# supported binary64 values and rejects representations it cannot preserve.
	var wire = WireValue.create(body, json_body)
	var numeric: Dictionary = await WireAdapter.validate_for_application(wire)
	if not _is_running or not _connections.has(conn) or not conn.is_peer_connected():
		return
	if not numeric.get("ok", false):
		_send_jsonrpc_error(conn, null, -32600, "Invalid numeric representation")
		return
	if not wire.parsed is Dictionary:
		_send_jsonrpc_error(conn, null, -32600, "Invalid request")
		return

	# Handle JSON-RPC request
	await _handle_jsonrpc(conn, wire.parsed, session_id, headers)


func _handle_jsonrpc(conn, request: Dictionary, session_id: String,
		headers: Dictionary = {}) -> void:
	var method_value: Variant = request.get("method")
	var method: String = method_value if method_value is String else ""
	var params = request.get("params", {})
	var request_id = request.get("id")  # Can be null for notifications
	var response_id: Variant = request_id if Protocol.valid_request_id(request_id) else null
	var profile := PublicProtocol.classify(request,
		str(headers.get("mcp-protocol-version", "")))
	if not profile.get("ok", false):
		var protocol_error: Dictionary = profile.error
		_send_jsonrpc_error(conn, response_id, int(protocol_error.code),
			str(protocol_error.message), protocol_error.get("data", {}), 400)
		return
	var modern: bool = profile.modern
	if modern:
		var schema: Variant = true
		if method == "tools/call" and params.get("name") is String \
				and _mcp_manager != null:
			var mirror_definition = _mcp_manager.tool_registry.get(params.name)
			if mirror_definition != null and str(mirror_definition.server_name) == "minerva":
				schema = mirror_definition.native_input_schema() \
					if mirror_definition.has_method("native_input_schema") \
					else mirror_definition.input_schema
		var mirror_error: String = HttpHeaders.validate_mirror(request, schema,
			headers, Protocol.MODERN_VERSION)
		if not mirror_error.is_empty():
			_send_jsonrpc_error(conn, response_id, PublicProtocol.HEADER_ERROR,
				mirror_error, {}, 400)
			return

	if not request.has("id"):
		if method == "notifications/initialized":
			conn.send_response(202, {}, "")
		elif method == "notifications/cancelled":
			conn.send_response(202, {}, "")
		else:
			conn.send_response(202, {}, "")
		return

	# Route to appropriate handler
	match method:
		"server/discover":
			_send_jsonrpc_result(conn, response_id, PublicProtocol.discovery_result())
		"initialize":
			_handle_initialize(conn, params, request_id)
		"tools/list":
			_handle_tools_list(conn, params, request_id, session_id, modern)
		"tools/call":
			await _handle_tools_call(conn, params, request_id, session_id, modern)
		"subscriptions/listen":
			var subscription_error := PublicProtocol.validate_subscription_params(params)
			if subscription_error.is_empty():
				conn.send_sse(PublicProtocol.subscription_messages(request_id))
			else:
				_send_jsonrpc_error(conn, request_id, -32602, subscription_error)
		_:
			_send_jsonrpc_error(conn, request_id, -32601,
				"Method not found: %s" % method, {}, 404 if modern else 200)


func _handle_initialize(conn, params: Dictionary, request_id) -> void:
	var requested_version_value: Variant = params.get("protocolVersion")
	if not requested_version_value is String:
		_send_jsonrpc_error(conn, request_id, -32602,
			"initialize protocolVersion must be a string")
		return
	if params.has("capabilities") and not params.capabilities is Dictionary:
		_send_jsonrpc_error(conn, request_id, -32602,
			"initialize capabilities must be an object")
		return
	if params.has("clientInfo") and not params.clientInfo is Dictionary:
		_send_jsonrpc_error(conn, request_id, -32602,
			"initialize clientInfo must be an object")
		return
	var requested_protocol_version: String = requested_version_value
	var negotiated_protocol_version := _negotiate_protocol_version(requested_protocol_version)

	# Create a new session
	var new_session_id = SingletonObject.generate_UUID()
	_sessions[new_session_id] = {
		"created_at": Time.get_unix_time_from_system(),
		"last_activity": Time.get_unix_time_from_system(),
		"client_info": params.get("clientInfo", {}),
		"protocol_version": negotiated_protocol_version,
		"enabled_sets": []  # empty = all sets enabled (backward compatible)
	}

	client_connected.emit(new_session_id)

	var result = {
		"protocolVersion": negotiated_protocol_version,
		"serverInfo": {
			"name": "minerva",
			"version": "1.0.0"
		},
		"capabilities": {
			"tools": {}
		}
	}

	var headers = {
		"MCP-Session-Id": new_session_id,
		"MCP-Protocol-Version": negotiated_protocol_version
	}

	_send_jsonrpc_result(conn, request_id, result, headers)


func _negotiate_protocol_version(requested_protocol_version: String) -> String:
	if requested_protocol_version in SUPPORTED_PROTOCOL_VERSIONS:
		return requested_protocol_version
	return LATEST_PROTOCOL_VERSION


func _handle_tools_list(conn, _params: Dictionary, request_id, session_id: String,
		modern: bool = false) -> void:
	# Update session activity
	if _sessions.has(session_id):
		_sessions[session_id].last_activity = Time.get_unix_time_from_system()

	var tools: Array[Dictionary] = []

	if _mcp_manager and _mcp_manager.minerva_server:
		var minerva_server = _mcp_manager.minerva_server
		var catalog: Dictionary = _export_catalog.snapshot(
			_mcp_manager.tool_registry, minerva_server._enabled_tool_sets)
		if not catalog.get("ok", false):
			_send_jsonrpc_error(conn, request_id, -32603,
				"Public tool catalog is invalid")
			return
		tools = catalog.tools

	var result = {
		"tools": tools
	}
	if modern:
		result = PublicProtocol.complete_result(result)
		result["ttlMs"] = 0
		result["cacheScope"] = "private"

	_send_jsonrpc_result(conn, request_id, result)


func _handle_tools_call(conn, params: Dictionary, request_id, session_id: String,
		modern: bool = false) -> void:
	# Update session activity
	if _sessions.has(session_id):
		_sessions[session_id].last_activity = Time.get_unix_time_from_system()

	var tool_name_value: Variant = params.get("name")
	var arguments = params.get("arguments", {})
	# TODO: extract agent_id from X-Agent-Id header
	var agent_value: Variant = params.get("agent_id", "")
	if not agent_value is String:
		_send_jsonrpc_error(conn, request_id, -32602, "agent_id must be a string")
		return
	var agent_id: String = agent_value

	if not tool_name_value is String or tool_name_value.is_empty():
		_send_jsonrpc_error(conn, request_id, -32602, "Missing tool name")
		return
	var tool_name: String = tool_name_value
	if not arguments is Dictionary:
		_send_jsonrpc_error(conn, request_id, -32602, "Tool arguments must be an object")
		return
	var dispatched_definition = _mcp_manager.tool_registry.get(tool_name) \
		if _mcp_manager != null else null
	if dispatched_definition == null:
		_send_jsonrpc_error(conn, request_id, -32602, "Unknown tool: %s" % tool_name)
		return
	if str(dispatched_definition.server_name) != "minerva":
		_send_jsonrpc_error(conn, request_id, -32602, "Unknown tool: %s" % tool_name)
		return
	var native_schema: Variant = dispatched_definition.native_input_schema() \
		if dispatched_definition.has_method("native_input_schema") \
		else dispatched_definition.input_schema
	var admission: Dictionary = _tool_admission.acquire()
	if not admission.get("ok", false):
		_send_overload(conn, request_id, admission)
		return
	var lease = admission.lease
	var input_validation: Dictionary = await ToolSchemaRuntime.validate(native_schema, arguments)
	if not input_validation.get("ok", false):
		lease.release()
		_send_jsonrpc_error(conn, request_id, -32602,
			"Tool arguments do not match inputSchema", {
				"validation": input_validation.get("error", {}).get("code", "invalid")})
		return
	if not _is_running or not _connections.has(conn) or not conn.is_peer_connected() \
			or _mcp_manager.tool_registry.get(tool_name) != dispatched_definition:
		lease.release()
		return

	# Enforce tool set filtering
	if _mcp_manager and _mcp_manager.minerva_server:
		var enabled_sets: Array = _mcp_manager.minerva_server._enabled_tool_sets
		if not enabled_sets.is_empty():
			# Check if this tool's set is enabled
			if _mcp_manager.tool_registry.has(tool_name):
				var tool_def = _mcp_manager.tool_registry[tool_name]
				if tool_def.tool_set != "meta" and tool_def.tool_set not in enabled_sets:
					lease.release()
					_send_jsonrpc_error(conn, request_id, -32602,
						"Tool set '%s' is not enabled for this session. Use minerva_enable_tool_sets to enable it." % tool_def.tool_set)
					return

	# Execute the tool
	if not _mcp_manager or not _mcp_manager.minerva_server:
		var has_manager := _mcp_manager != null
		var has_server := false
		if _mcp_manager:
			has_server = _mcp_manager.minerva_server != null
		var debug_msg := "Minerva server not available (_mcp_manager=%s, minerva_server=%s)" % [has_manager, has_server]
		print("[MCP HTTP] " + debug_msg)
		lease.release()
		_send_jsonrpc_error(conn, request_id, -32603, debug_msg)
		return
	var context = ExecutionContext.create("http", "", agent_id)
	_active_request_contexts[conn] = context
	_monitor_request_connection(conn, context)
	tool_executed.emit(tool_name, session_id)
	if context.is_stopped() or not _is_running or not _connections.has(conn):
		lease.release()
		if _active_request_contexts.get(conn) == context:
			_active_request_contexts.erase(conn)
		return
	var tool_outcome = await _mcp_manager.minerva_server.execute_tool_for_http_outcome(
		tool_name, arguments, agent_id, context)
	lease.release()
	if _active_request_contexts.get(conn) == context:
		_active_request_contexts.erase(conn)
	if context.is_stopped():
		return

	_send_jsonrpc_result(conn, request_id,
		_public_result_from_outcome(tool_outcome, modern))


func _public_result_from_outcome(outcome, modern: bool) -> Dictionary:
	if outcome != null and outcome.envelope != null \
			and outcome.envelope.result_type != "complete":
		# Multi-round interaction belongs to the upstream plugin session. Public
		# callers receive a bounded local failure without opaque continuation state.
		var unsupported := {"content": [{"type": "text", "text": JSON.stringify({
			"success": false,
			"error": "Upstream tool interaction is not supported through this endpoint",
			"error_code": "unsupported_interaction",
		})}], "isError": true}
		return PublicProtocol.complete_result(unsupported) if modern else unsupported
	if outcome != null and outcome.envelope != null and outcome.wire_authoritative \
			and outcome.envelope.result_type == "complete":
		var preserved: Dictionary = outcome.envelope.to_mcp_format()
		preserved.erase("resultType")
		# Caller-interaction fields belong to the upstream session and are never
		# re-exported through Minerva's independent public request.
		preserved.erase("requestState")
		preserved.erase("inputRequests")
		return PublicProtocol.complete_result(preserved) if modern else preserved
	var application: Variant = outcome.application if outcome != null else {
		"success": false, "error": "Tool outcome is unavailable"}
	var adapted: Dictionary = NativeWireAdapter.adapt(application)
	if not adapted.get("ok", false):
		application = {"success": false, "error": str(adapted.get("error",
			"Native tool result cannot be represented on the MCP wire"))}
	else:
		application = adapted.value
	var serialized: Dictionary = JsonSerialization.encode(application)
	var text: String = serialized.get("raw", "{\"success\":false,\"error\":\"Native result serialization failed\"}")
	var result := {"content": [{"type": "text", "text": text}]}
	if outcome != null and outcome.validated_structured_content != null \
			and application is Dictionary \
			and application.get("success", application.get("allowed",
				not (application.has("error") or application.has("error_code") \
				or not str(application.get("error_message", "")).is_empty()))) == true:
		result["structuredContent"] = outcome.validated_structured_content
	# Host-only augmentation changes the application text, while a previously
	# validated structured result still satisfies the exported output schema.
	# Local validation/conformance failures are unsuccessful and never enter here.
	if outcome != null and outcome.envelope != null \
			and application is Dictionary \
			and application.get("success", not application.has("error")) \
			and outcome.envelope.original_result.has("structuredContent"):
		result["structuredContent"] = outcome.envelope.original_result.structuredContent
	if application is Dictionary and (application.get("success") == false \
			or application.get("allowed") == false \
			or application.has("error") or application.has("error_message")):
		result["isError"] = true
	return PublicProtocol.complete_result(result) if modern else result


func _send_jsonrpc_result(conn, request_id, result: Dictionary, extra_headers: Dictionary = {}) -> void:
	var response = {
		"jsonrpc": "2.0",
		"result": result,
		"id": _normalize_jsonrpc_id(request_id)
	}

	var serialized: Dictionary = JsonSerialization.encode(response)
	if not serialized.get("ok", false):
		_send_jsonrpc_error(conn, request_id, -32603,
			"MCP response cannot be represented as JSON")
		return
	var body: String = serialized.raw
	if body.to_utf8_buffer().size() > MinervaMCPHttpConnectionScript.MAX_BODY_BYTES:
		_send_jsonrpc_error(conn, request_id, -32000,
			"MCP response exceeds the 32 MiB byte budget")
		return
	if conn.is_browser_control() and body.to_utf8_buffer().size() > PluginPayloadLimits.CONTROL_BYTES:
		_send_jsonrpc_error(conn, request_id, -32000, "payload_too_large: MCP response exceeds 65536 UTF-8 bytes")
		return
	conn.send_response(200, extra_headers, body)


func _send_jsonrpc_error(conn, request_id, code: int, message: String,
		data: Dictionary = {}, status_code: int = 200,
		extra_headers: Dictionary = {}) -> void:
	var response = {
		"jsonrpc": "2.0",
		"error": {
			"code": code,
			"message": message
		},
		"id": _normalize_jsonrpc_id(request_id)
	}
	if not data.is_empty():
		response.error["data"] = data

	var serialized: Dictionary = JsonSerialization.encode(response)
	var body: String = serialized.get("raw", "")
	if not serialized.get("ok", false):
		body = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"MCP error cannot be represented as JSON\"},\"id\":null}"
	if body.to_utf8_buffer().size() > MinervaMCPHttpConnectionScript.MAX_BODY_BYTES:
		var bounded: Dictionary = JsonSerialization.encode({"jsonrpc": "2.0", "error": {
			"code": -32000, "message": "MCP error response exceeds the byte budget"},
			"id": _normalize_jsonrpc_id(request_id)})
		body = bounded.get("raw", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"MCP error cannot be represented as JSON\"},\"id\":null}")
	conn.send_response(status_code, extra_headers, body)


func _send_overload(conn, request_id, admission: Dictionary) -> void:
	_send_jsonrpc_error(conn, request_id, -32000,
		"MCP tool admission is temporarily unavailable", {
			"reason": admission.get("reason", "overloaded")}, 429, {
			"Retry-After": str(admission.get("retry_after", 1))})


func _monitor_request_connection(conn, context) -> void:
	while _active_request_contexts.get(conn) == context and not context.is_stopped():
		if not conn.is_peer_connected():
			context.cancel()
			return
		await get_tree().process_frame


func _normalize_jsonrpc_id(request_id):
	if not Protocol.valid_request_id(request_id):
		return null
	if request_id is float:
		return int(request_id)
	return request_id


func _send_error(conn, status_code: int, message: String) -> void:
	conn.send_response(status_code, {"Content-Type": "text/plain; charset=utf-8"}, message)
