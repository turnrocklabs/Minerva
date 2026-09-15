class_name MCPServerConnection
extends RefCounted
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")

const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
## Base class for MCP server connections.
## Handles communication with MCP servers over various transports.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const WireValue = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const ToolResultEnvelope = preload("res://Scripts/Services/MCP/MCPToolResult.gd")
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const StdioNegotiation = preload("res://Scripts/Services/MCP/MCPStdioNegotiation.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const HttpTransport = preload("res://Scripts/Services/MCP/MCPHttpTransport.gd")
const HttpHeaders = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")
const MonotonicDeadline = preload("res://Scripts/Services/MCP/MCPMonotonicDeadline.gd")

signal connected()
signal disconnected()
signal http_notification_received(message: Dictionary, request_id: Variant)
signal tool_result_received(tool_name: String, result: Dictionary)
signal tool_result_envelope_received(tool_name: String, result)

enum TransportType { HTTP, WEBSOCKET, STDIO }

## Server name identifier
var server_name: String = ""

## Transport type for this connection
var transport: TransportType = TransportType.HTTP

## Base URL for HTTP/WebSocket connections
var base_url: String = ""

## Command for STDIO transport (e.g., "nudge")
var stdio_command: String = ""

## Arguments for STDIO transport (e.g., ["serve", "--stdio"])
var stdio_args: PackedStringArray = []

## Whether the server is currently connected
var server_connected: bool = false

## Skip MCP protocol initialization (for REST APIs that don't support it)
var skip_mcp_init: bool = false

## MCP endpoint path (default "/mcp", some servers use "/")
var mcp_endpoint: String = "/mcp"

## Working directory for file operations (sent to server on initialize/set)
var working_directory: String = ""

## Available tools from this server
var tools: Array = []

## WebSocket client for persistent connections
var _websocket: WebSocketPeer = null

## SubProcess for STDIO transport (type not specified - GDExtension may not be loaded)
var _subprocess = null

## In-flight STDIO requests, keyed by MCPProtocol's typed JSON-RPC identity.
## String "7" and integer 7 therefore remain separate. Each value is a
## _PendingRequest whose `resolved` signal fires exactly once — with the
## plugin's response, a timeout error, or a connection-lost error.
var _pending: Dictionary = {}  # typed request key -> _PendingRequest
var _completed_wire_results: Dictionary = {}
var protocol_profile = Profile.new()
var _process_generation := 0

var stdio_startup_budget_sec := 12.0
var stdio_discovery_budget_sec := 1.0

## Active HTTP requests that can be cancelled
var _http_transport = null

## MCP protocol version
const MCP_PROTOCOL_VERSION := "2025-06-18"

## Request ID counter
var _request_id_counter: int = 0

## MCP session ID (for HTTP transport)
var _session_id: String = ""

## Optional handler for plugin-initiated capability requests (bidirectional channel).
## Signature: func(plugin_id: String, capability: String, args: Dictionary) -> Dictionary
## Set by PluginManager after creating the connection for a plugin.
var capability_request_handler: Callable = Callable()

## Plugin ID associated with this connection (set when used as a plugin connection).
var plugin_id: String = ""

## Reference to PluginEventBroker for routing async events/state.
var event_broker = null


func _init(name: String = "", url: String = "", type: TransportType = TransportType.HTTP) -> void:
	server_name = name
	base_url = url
	transport = type
	# Connect to global stop signal - MCP connections are shared, so cancel on any stop
	if SingletonObject:
		SingletonObject.stop_all_requests.connect(_on_stop_all_requests)


## Handle stop signal - MCP connections cancel on any stop request
func _on_stop_all_requests(_history_id: String) -> void:
	cancel_active_requests()


## Configure STDIO transport with command and arguments
func configure_stdio(command: String, args: PackedStringArray = []) -> void:
	stdio_command = command
	stdio_args = args
	transport = TransportType.STDIO


## Connect to the MCP server
func connect_to_server() -> Error:
	match transport:
		TransportType.HTTP:
			# HTTP is stateless, just verify the server is reachable
			return await _verify_http_connection()
		TransportType.WEBSOCKET:
			return await _connect_websocket()
		TransportType.STDIO:
			return await _connect_stdio()
	return ERR_INVALID_PARAMETER


## Disconnect from the server
func disconnect_from_server() -> void:
	print("[MCP %s] Disconnecting..." % server_name)
	server_connected = false
	var disconnected_http = _http_transport
	_http_transport = null
	if disconnected_http != null:
		disconnected_http.disconnect_transport()
	var disconnected_pending: Array = _pending.values()
	var disconnected_process = _subprocess
	_subprocess = null
	var disconnected_websocket = _websocket
	_websocket = null
	_process_generation += 1
	protocol_profile = Profile.new()
	_completed_wire_results.clear()
	disconnected.emit()

	# Detach transport ownership before waking callers: a failed waiter may
	# synchronously reconnect and must never join the process being retired.
	_fail_pending_requests(disconnected_pending, "MCP server '%s' disconnected" % server_name)

	if disconnected_websocket:
		disconnected_websocket.close()
	if disconnected_process:
		print("[MCP %s] Stopping subprocess..." % server_name)
		# Just stop the subprocess - don't try to free it.
		# The subprocess destructor will call stop() again (safely, as it checks _running).
		# Godot will clean up the node when the scene tree is destroyed.
		disconnected_process.stop()
		# Note: We intentionally don't queue_free() here because during shutdown,
		# the subprocess read thread may have pending deferred calls that would
		# crash if the object is freed too soon.

	print("[MCP %s] Disconnected" % server_name)


## Cancel all active HTTP requests (called when user presses stop)
func cancel_active_requests() -> void:
	if _http_transport != null:
		_http_transport.cancel_active()
	if transport == TransportType.STDIO:
		var pending_requests: Array = _pending.values()
		for pending_value: Variant in pending_requests:
			var pending: _PendingRequest = pending_value
			if pending.context != null:
				pending.context.cancel()
			elif _pending.has(Protocol.request_id_key(pending.request_id)):
				if protocol_profile.era == Profile.Era.MODERN_2026_07_28:
					_write_modern_cancel(pending.request_id, pending.generation)
				_resolve_pending(pending.request_id,
					_conn_error("MCP request was cancelled"), null, pending.generation)


## List available tools from the server
func list_tools() -> Array:
	if tools.is_empty():
		await refresh_tools()
	return tools


## Refresh the list of available tools from the server
func refresh_tools() -> Error:
	print("[MCP] Refreshing tools from %s (connected=%s)..." % [server_name, server_connected])

	# Skip tool discovery for REST APIs that don't support MCP protocol
	if skip_mcp_init:
		print("[MCP] Skipping tool discovery (REST API mode)")
		return OK

	var result = await call_tool("tools/list", {})
	print("[MCP] tools/list returned: %s" % str(result).left(200))

	if result.get("error"):
		push_error("Failed to list tools: %s" % result.get("error"))
		return ERR_QUERY_FAILED

	print("[MCP] tools/list result keys: %s" % str(result.keys()))

	tools.clear()
	var tools_data = result.get("tools", [])
	if tools_data is Array:
		print("[MCP] Found %d tools" % tools_data.size())
		for tool_data in tools_data:
			if transport == TransportType.HTTP and protocol_profile.era == Profile.Era.MODERN_2026_07_28 and tool_data is Dictionary:
				if not tool_data.get("inputSchema") is Dictionary or tool_data.inputSchema.get("type") != "object":
					push_warning("Excluded MCP tool with invalid inputSchema root")
					continue
				var header_check := HttpHeaders.annotations(tool_data.get("inputSchema", {}))
				if not header_check.error.is_empty():
					push_warning("Excluded MCP tool %s: %s" % [tool_data.get("name", ""), header_check.error])
					continue
			var tool = MCPToolDefinitionScript.from_dict(tool_data, server_name)
			tools.append(tool)
	else:
		print("[MCP] WARNING: tools_data is not an Array: %s" % typeof(tools_data))

	return OK


## Call a tool on the MCP server.
## timeout_sec is the STDIO per-request budget (0 = unbounded); HTTP/WebSocket
## transports use their own timeouts and ignore it.
func call_tool(tool_name: String, arguments: Dictionary, timeout_sec: float = 120.0) -> Dictionary:
	match transport:
		TransportType.HTTP:
			return await _call_tool_http(tool_name, arguments)
		TransportType.WEBSOCKET:
			return await _call_tool_websocket(tool_name, arguments)
		TransportType.STDIO:
			return await _call_tool_stdio(tool_name, arguments, timeout_sec)

	return {"error": "Invalid transport type"}


## Explicit native lifetime; the existing call_tool API remains unchanged.
func call_tool_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	return await context.run(_call_with_context.bind(tool_name, arguments, context))


func _call_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	match transport:
		TransportType.STDIO:
			return await _call_tool_stdio(tool_name, arguments, context.remaining_seconds(), context)
		TransportType.HTTP:
			return await _call_tool_http(tool_name, arguments, context)
		TransportType.WEBSOCKET:
			return await _call_tool_websocket(tool_name, arguments, context)
	return {"error": "Invalid transport type"}


## Set the working directory for file operations on the server
## This can be called at any time to change the context for subsequent tool calls
func set_working_directory(directory: String) -> Dictionary:
	working_directory = directory

	if not server_connected:
		# Just store it, will be sent on next connect
		return {"success": true, "workingDirectory": directory}

	# Send to server immediately if connected
	match transport:
		TransportType.HTTP:
			return await _call_tool_http("set_working_directory", {"directory": directory})
		TransportType.WEBSOCKET:
			return await _call_tool_websocket("set_working_directory", {"directory": directory})
		TransportType.STDIO:
			return await _call_tool_stdio("set_working_directory", {"directory": directory})

	return {"error": "Invalid transport type"}


## HTTP transport: Verify connection and perform MCP initialization
func _verify_http_connection() -> Error:
	server_connected = false
	protocol_profile = Profile.new()
	print("[MCP HTTP] Connecting to %s..." % base_url)

	# Skip MCP protocol init for REST APIs that don't support it
	if skip_mcp_init:
		# For REST APIs, do a simple health check
		var http := HTTPRequest.new()
		if Engine.get_main_loop():
			Engine.get_main_loop().root.add_child(http)
		else:
			push_error("Cannot make HTTP request: no scene tree available")
			return ERR_CANT_CONNECT

		var health_endpoints := ["%s/health" % base_url, base_url]
		var health_ok := false

		for health_url in health_endpoints:
			print("[MCP HTTP] Health check: %s" % health_url)
			var err := http.request(health_url, [], HTTPClient.METHOD_GET)
			if err != OK:
				continue

			var response: Array = await http.request_completed

			if not is_instance_valid(http):
				return ERR_CANT_CONNECT

			var result_code: int = response[0]
			var response_code: int = response[1]

			if result_code == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300:
				print("[MCP HTTP] Health check OK at %s" % health_url)
				health_ok = true
				break

		http.queue_free()

		if not health_ok:
			print("[MCP HTTP] Health check failed")
			server_connected = false
			return ERR_CANT_CONNECT

		print("[MCP HTTP] Connected (REST API mode)")
		protocol_profile = Profile.custom(_process_generation)
		if _http_transport == null:
			_http_transport = HttpTransport.new()
			_http_transport.request_notification.connect(_on_http_notification)
		_http_transport.configure_custom(_get_mcp_endpoint())
		server_connected = true
		connected.emit()
		return OK

	if _http_transport == null:
		_http_transport = HttpTransport.new()
		_http_transport.request_notification.connect(_on_http_notification)
	var transport_owner = _http_transport
	var init_result: Dictionary = await transport_owner.connect_endpoint(_get_mcp_endpoint(), working_directory)
	if transport_owner != _http_transport or init_result.has("error"):
		return ERR_CANT_CONNECT
	protocol_profile = transport_owner.profile
	server_connected = true
	connected.emit()
	return OK


## Get the MCP endpoint URL using configured endpoint path
func _get_mcp_endpoint() -> String:
	var url = base_url.rstrip("/")
	if mcp_endpoint == "/":
		return url
	return url + mcp_endpoint


func _on_http_notification(message: Dictionary, request_id: Variant) -> void:
	http_notification_received.emit(message, request_id)


## HTTP transport owns profile negotiation, bounded streaming and cancellation.
func _call_tool_http(tool_name: String, arguments: Dictionary, context: ExecutionContext = null) -> Dictionary:
	if _http_transport == null:
		return {"error": "HTTP transport is not connected"}
	var method := tool_name
	var params := arguments
	var schema: Variant = {}
	if tool_name not in ["tools/list", "set_working_directory"]:
		method = "tools/call"
		params = {"name": tool_name, "arguments": arguments}
		for tool in tools:
			if tool.name == tool_name:
				schema = tool.to_mcp_format().get("inputSchema", {})
	var owner = _http_transport
	var owner_generation: int = owner.generation
	var response: Dictionary = await owner.request_method(method, params, schema, context)
	if owner != _http_transport or owner.generation != owner_generation:
		return {"error": "HTTP connection superseded"}
	if response.has("error"):
		return response
	if context != null and context.is_stopped():
		return context.stopped_result()
	var raw_result: Dictionary = response.get("result", {})
	if method == "tools/list":
		return raw_result
	var envelope = ToolResultEnvelope.from_mcp(raw_result,
		owner.profile.era == Profile.Era.MODERN_2026_07_28, response.get("wire"))
	tool_result_envelope_received.emit(tool_name, envelope)
	if owner.generation != owner_generation or (context != null and context.is_stopped()):
		return {"error": "HTTP request cancelled during result delivery"}
	var result: Dictionary = envelope.to_application_result()
	if envelope.result_type == "complete":
		result = _normalize_mcp_tool_result(result)
	tool_result_received.emit(tool_name, result)
	return result


## WebSocket transport: Connect to server
func _connect_websocket() -> Error:
	_websocket = WebSocketPeer.new()
	var err := _websocket.connect_to_url(base_url)
	if err != OK:
		_websocket = null
		return err

	# Wait for connection (with timeout)
	var timeout := 10.0
	var elapsed := 0.0
	while _websocket.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_websocket.poll()
		await Engine.get_main_loop().process_frame
		elapsed += Engine.get_main_loop().root.get_process_delta_time()
		if elapsed > timeout:
			_websocket.close()
			_websocket = null
			return ERR_TIMEOUT

	if _websocket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_websocket = null
		return ERR_CANT_CONNECT

	protocol_profile = Profile.custom(_process_generation)
	server_connected = true
	connected.emit()
	return OK


## WebSocket transport: Call a tool
func _call_tool_websocket(tool_name: String, arguments: Dictionary, context: ExecutionContext = null) -> Dictionary:
	if not _websocket or _websocket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return {"error": "WebSocket not connected"}

	var request_id := str(randi())
	var request := {
		"jsonrpc": "2.0",
		"id": request_id,
		"method": "tools/call",
		"params": {
			"name": tool_name,
			"arguments": arguments
		}
	}

	var err := _websocket.send_text(JSON.stringify(request))
	if err != OK:
		return {"error": "Failed to send WebSocket message"}

	# Wait for response with matching ID
	var timeout := 30.0
	var elapsed := 0.0
	while elapsed < timeout:
		if context != null and context.is_stopped():
			return context.stopped_result()
		if not is_instance_valid(_websocket):
			return {"error": "WebSocket disconnected"}
		_websocket.poll()
		while _websocket.get_available_packet_count() > 0:
			var packet := _websocket.get_packet().get_string_from_utf8()
			var json := JSON.new()
			if json.parse(packet) == OK and json.data is Dictionary:
				var response: Dictionary = json.data
				if response.get("id") == request_id:
					var raw_result: Variant = response.get("result", {})
					if raw_result is Dictionary:
						tool_result_envelope_received.emit(tool_name, ToolResultEnvelope.from_mcp(
							raw_result, false, WireValue.create(packet, response)))
					var result := _normalize_mcp_tool_result(raw_result)
					tool_result_received.emit(tool_name, result)
					return result

		await Engine.get_main_loop().process_frame
		elapsed += Engine.get_main_loop().root.get_process_delta_time()

	return {"error": "WebSocket request timed out"}


## Get a tool definition by name
func get_tool(tool_name: String):
	for tool in tools:
		if tool.name == tool_name:
			return tool
	return null


## Check if this server has a specific tool
func has_tool(tool_name: String) -> bool:
	return get_tool(tool_name) != null


# ============================================
# STDIO Transport Implementation
# ============================================

## STDIO transport: Connect by spawning subprocess and performing MCP handshake
func _connect_stdio() -> Error:
	print("[MCP STDIO] Connecting via STDIO transport...")
	print("[MCP STDIO] Command: %s %s" % [stdio_command, str(stdio_args)])
	var startup_deadline_ms := Time.get_ticks_msec() + int(stdio_startup_budget_sec * 1000.0)

	if stdio_command.is_empty():
		push_error("STDIO transport requires command to be set")
		return ERR_INVALID_PARAMETER

	# Create SubProcess node (check if GDExtension is available)
	if not ClassDB.class_exists("SubProcess"):
		push_error("SubProcess GDExtension not available - STDIO transport not supported")
		return ERR_UNAVAILABLE
	_process_generation += 1
	var connection_generation: int = _process_generation
	protocol_profile = Profile.new()
	protocol_profile.generation = connection_generation
	_subprocess = ClassDB.instantiate("SubProcess")
	var created_process = _subprocess

	if not Engine.get_main_loop():
		push_error("Cannot spawn subprocess: no scene tree available")
		_subprocess.free()
		_subprocess = null
		return ERR_CANT_CREATE

	Engine.get_main_loop().root.add_child(_subprocess)

	# During app teardown add_child can FAIL (root busy removing children).
	# Starting the process anyway would orphan it: the awaits below never
	# resume once the tree dies, stop() never runs, and the child's live pipes
	# + reader threads keep the dying Minerva process alive for minutes
	# (slow-app-close bug, 2026-07-03). Bail out instead.
	if _subprocess.get_parent() == null:
		push_error("Cannot spawn subprocess for '%s': scene tree rejected the node (shutting down?)" % stdio_command)
		_subprocess.free()
		_subprocess = null
		return ERR_CANT_CREATE

	# Start the subprocess
	print("[MCP STDIO] Starting subprocess...")
	if not created_process.start(stdio_command, stdio_args):
		push_error("Failed to start MCP server subprocess: %s" % stdio_command)
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CREATE

	# Give the child a short unscaled startup turn within the shared deadline.
	var startup_delay := minf(0.1, _remaining_startup_seconds(startup_deadline_ms))
	if startup_delay <= 0.0:
		disconnect_from_server()
		return ERR_TIMEOUT
	await Engine.get_main_loop().create_timer(startup_delay, true, false, true).timeout
	if connection_generation != _process_generation or created_process != _subprocess:
		return ERR_CANT_CONNECT

	if not created_process.is_running():
		push_error("MCP server subprocess exited immediately")
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CONNECT

	# Connect the single always-live stdout reader. Every line the plugin emits
	# — tool responses, plugin-initiated capability requests, event/state/notify
	# messages — is dispatched by _drain_stdout; a response is routed to its
	# waiter by JSON-RPC id (see _stdio_request / _resolve_pending).
	var connected_process = created_process
	if connected_process.has_signal("output_ready"):
		connected_process.output_ready.connect(_drain_stdout.bind(connected_process))
	if connected_process.has_signal("io_overflow"):
		connected_process.io_overflow.connect(_on_stdio_io_failure.bind(connected_process))
	# Low-frequency backstop: re-drain in case an output_ready signal is ever
	# missed, and fail outstanding requests if the subprocess dies.
	_backstop_tick(connected_process)

	print("[MCP STDIO] Subprocess running, performing MCP handshake...")

	# Probe modern MCP first, then use the initialized legacy lane only when the
	# peer gives no recognized modern response. Both phases share one deadline.
	var init_result := await _negotiate_stdio(connection_generation, startup_deadline_ms)
	if connection_generation != _process_generation or connected_process != _subprocess:
		return ERR_CANT_CONNECT
	if init_result.get("error"):
		push_error("MCP initialization failed: %s" % init_result.get("error"))
		var failed_process = _subprocess
		_subprocess = null
		failed_process.stop()
		failed_process.queue_free()
		return ERR_CANT_CONNECT

	print("[MCP STDIO] Handshake successful!")
	server_connected = true
	connected.emit()
	return OK


## Send MCP initialize request
func _negotiate_stdio(generation: int, startup_deadline_ms: int) -> Dictionary:
	var probe_id: String = _next_request_id()
	var startup_remaining := _remaining_startup_seconds(startup_deadline_ms)
	if startup_remaining <= 0.0:
		return _conn_error("MCP startup budget expired before discovery")
	var probe_budget := minf(stdio_discovery_budget_sec, startup_remaining)
	var probe := await _stdio_request(StdioNegotiation.discovery_request(probe_id),
		probe_budget, "server/discover", null, generation)
	if generation != _process_generation:
		return _conn_error("MCP process changed during discovery")
	var probe_wire = _take_completed_wire(probe_id)
	if probe_wire != null:
		var validation_budget := _remaining_startup_seconds(startup_deadline_ms)
		if validation_budget <= 0.0:
			return _conn_error("MCP startup budget expired before discovery validation")
		var numeric_check: Dictionary = await WireAdapter.validate_for_application(
			probe_wire, validation_budget)
		if generation != _process_generation:
			return _conn_error("MCP process changed while validating discovery")
		if not numeric_check.get("ok", false):
			return _conn_error(_wire_validation_message(numeric_check))
	var classified := StdioNegotiation.classify_discovery(probe)
	if classified.modern:
		if classified.has("error"):
			# A specified modern protocol error proves the peer's era. It is not
			# permission to retry the request through legacy initialization.
			protocol_profile = Profile.modern({}, generation)
			return _conn_error(classified.error)
		var discovered: Dictionary = classified.result
		protocol_profile = Profile.modern(discovered.capabilities, generation)
		if Time.get_ticks_msec() > startup_deadline_ms:
			return _conn_error("MCP startup budget expired during discovery validation")
		return discovered

	var remaining := _remaining_startup_seconds(startup_deadline_ms)
	if remaining <= 0.0:
		return _conn_error("MCP startup budget expired before legacy initialization")
	var init_id := _next_request_id()
	var init := await _stdio_request(StdioNegotiation.legacy_initialize_request(
		init_id, working_directory), remaining, "initialize", null, generation)
	if generation != _process_generation:
		return _conn_error("MCP process changed during initialization")
	var init_wire = _take_completed_wire(init_id)
	if init_wire != null:
		var init_validation_budget := _remaining_startup_seconds(startup_deadline_ms)
		if init_validation_budget <= 0.0:
			return _conn_error("MCP startup budget expired before initialization validation")
		var init_numeric: Dictionary = await WireAdapter.validate_for_application(
			init_wire, init_validation_budget)
		if generation != _process_generation:
			return _conn_error("MCP process changed while validating initialization")
		if not init_numeric.get("ok", false):
			return _conn_error(_wire_validation_message(init_numeric))
	var validated := StdioNegotiation.validate_legacy_initialize(init)
	if validated.has("error"):
		return validated
	var initialized: Dictionary = validated.result
	if Time.get_ticks_msec() > startup_deadline_ms:
		return _conn_error("MCP startup budget expired during initialization validation")
	protocol_profile = Profile.legacy(initialized.protocolVersion,
		initialized.capabilities, generation)
	if not _write_stdio_notification({"jsonrpc": Protocol.JSON_RPC_VERSION,
			"method": "notifications/initialized"}, generation):
		return _conn_error("failed to write initialized notification to MCP server '%s'" % server_name)
	return initialized


func _remaining_startup_seconds(deadline_ms: int) -> float:
	return maxf(0.0, float(deadline_ms - Time.get_ticks_msec()) / 1000.0)


func _take_completed_wire(request_id: Variant):
	var key := Protocol.request_id_key(request_id)
	var wire_value = _completed_wire_results.get(key)
	_completed_wire_results.erase(key)
	return wire_value


func _wire_validation_message(result: Dictionary) -> String:
	var error_value: Variant = result.get("error", {})
	return str(error_value.get("message", "MCP response changed during numeric conversion")) \
		if error_value is Dictionary else str(error_value)


func _stdio_method_request(method: String, params: Dictionary) -> Dictionary:
	var request_id: String = _next_request_id()
	if protocol_profile.era == Profile.Era.MODERN_2026_07_28:
		return StdioNegotiation.modern_request(method, request_id, params)
	return {"jsonrpc": Protocol.JSON_RPC_VERSION, "id": request_id,
		"method": method, "params": params}


func _write_stdio_notification(notification: Dictionary, generation: int) -> bool:
	var process = _subprocess
	if process == null or generation != _process_generation or not process.is_running():
		return false
	if process.write_data(JSON.stringify(notification) + "\n"):
		return true
	_on_stdio_io_failure(process)
	return false


func _write_modern_cancel(request_id: Variant, generation: int) -> void:
	_write_stdio_notification({"jsonrpc": Protocol.JSON_RPC_VERSION,
		"method": "notifications/cancelled", "params": {"requestId": request_id}}, generation)


## Generate next request ID
func _next_request_id() -> String:
	_request_id_counter += 1
	return str(_request_id_counter)


## Send a JSON-RPC request over STDIO and await its response.
##
## The request is admitted to the bounded native writer and a _PendingRequest is registered under
## its JSON-RPC id; the always-live reader (_drain_stdout) routes the matching
## response back by id. No serialization gate, no polling — any number of
## requests may be in flight on the one connection at once.
##
## timeout_sec is the caller's per-request budget. When it elapses the request
## resolves with a timeout error; timeout_sec = 0 means unbounded (resolves only
## on a real response or a connection loss). tool_name, when given, is woven
## into timeout/error messages for debuggability.
func _stdio_request(request: Dictionary, timeout_sec: float = 120.0, tool_name: String = "", context: ExecutionContext = null, generation: int = -1) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		return _conn_error("MCP server '%s' is not running" % server_name)

	if context != null and context.is_stopped():
		return context.stopped_result()
	var request_id: Variant = request.get("id")
	var request_key := Protocol.request_id_key(request_id)
	if request_key.is_empty() or _pending.has(request_key):
		return _conn_error("MCP request id is invalid or already outstanding")
	var owned_generation: int = _process_generation if generation < 0 else generation
	if owned_generation != _process_generation:
		return _conn_error("MCP process changed before request dispatch")
	var serialized := JsonSerialization.encode(request)
	if not serialized.ok:
		return _conn_error(serialized.error.message)
	var pending := _PendingRequest.new()
	pending.tool_name = tool_name
	pending.created_ms = Time.get_ticks_msec()
	pending.capture_wire = true
	pending.request_id = request_id
	pending.generation = owned_generation
	pending.context = context
	_pending[request_key] = pending
	var on_cancel := func() -> void:
		if protocol_profile.era == Profile.Era.MODERN_2026_07_28:
			_write_modern_cancel(request_id, owned_generation)
		_resolve_pending(request_id, context.stopped_result(), null, owned_generation)
	if context != null:
		context.lifetime.cancelled.connect(on_cancel)

	var request_json: String = serialized.raw + "\n"
	var log_json := request_json.left(200)
	if request_json.length() > 200:
		log_json += "..."
	print("[MCP %s] Sending: %s" % [server_name, log_json])

	if not _subprocess.write_data(request_json):
		_pending.erase(request_key)
		if context != null and context.lifetime.cancelled.is_connected(on_cancel):
			context.lifetime.cancelled.disconnect(on_cancel)
		_on_stdio_io_failure()
		return _conn_error("failed to write request to MCP server '%s'" % server_name)

	if timeout_sec > 0.0 and not pending.done:
		var label: String = tool_name if tool_name != "" else ("id " + str(request_id))
		pending.deadline_error = _conn_error("MCP request (%s) to '%s' timed out after %.0fs"
				% [label, server_name, timeout_sec])
		pending.deadline_timeout_sec = timeout_sec
		_arm_pending_deadline(pending)

	if not pending.done:
		await pending.resolved
	_cancel_pending_deadline(pending)
	if context != null and context.lifetime.cancelled.is_connected(on_cancel):
		context.lifetime.cancelled.disconnect(on_cancel)
	return _stdio_finalize(pending.result)


## Resolve an in-flight request exactly once (first-wins). A real response, a
## timeout, and a connection loss all funnel through here; whichever reaches a
## given id first wins, and any later call for that id is a no-op.
func _resolve_pending(request_id: Variant, result: Dictionary, wire_value = null, generation: int = -1) -> void:
	var request_key := Protocol.request_id_key(request_id)
	if not _pending.has(request_key):
		return
	var pending: _PendingRequest = _pending[request_key]
	if generation >= 0 and pending.generation != generation:
		return
	_pending.erase(request_key)
	if wire_value != null and pending.capture_wire:
		_completed_wire_results[request_key] = wire_value
	pending.done = true
	pending.result = result
	_cancel_pending_deadline(pending)
	pending.resolved.emit(result)


func _arm_pending_deadline(pending: _PendingRequest) -> void:
	if pending.done or not _pending.has(Protocol.request_id_key(pending.request_id)):
		return
	pending.deadline = MonotonicDeadline.new()
	pending.deadline_callback = _resolve_pending.bind(pending.request_id,
		pending.deadline_error, null, pending.generation)
	pending.deadline.expired.connect(pending.deadline_callback)
	if not pending.deadline.start(float(pending.deadline_timeout_sec)):
		_resolve_pending(pending.request_id,
			_conn_error("MCP request deadline is unavailable"), null, pending.generation)


func _cancel_pending_deadline(pending: _PendingRequest) -> void:
	if pending.deadline != null:
		pending.deadline.cancel()
		if pending.deadline_callback.is_valid() \
				and pending.deadline.expired.is_connected(pending.deadline_callback):
			pending.deadline.expired.disconnect(pending.deadline_callback)
	pending.deadline = null
	pending.deadline_callback = Callable()


func _on_stdio_io_failure(expected_process = null) -> void:
	if _subprocess == null or (expected_process != null and expected_process != _subprocess):
		return
	var failed_process = _subprocess
	var failed_pending: Array = _pending.values()
	_subprocess = null
	server_connected = false
	_process_generation += 1
	protocol_profile = Profile.new()
	_completed_wire_results.clear()
	disconnected.emit()
	_fail_pending_requests(failed_pending,
		"MCP server '%s' exceeded a subprocess I/O bound or lost its input pipe" % server_name)
	failed_process.stop()
	if failed_process is Node and is_instance_valid(failed_process):
		failed_process.queue_free()


## Fail every outstanding request — used on disconnect / subprocess exit so no
## caller is left awaiting a response that will never arrive.
func _fail_all_pending(reason: String) -> void:
	var pending_requests: Array = _pending.values()
	_fail_pending_requests(pending_requests, reason)


func _fail_pending_requests(pending_requests: Array, reason: String) -> void:
	var err := _conn_error(reason)
	for pending_value: Variant in pending_requests:
		var pending: _PendingRequest = pending_value
		_resolve_pending(pending.request_id, err, null, pending.generation)


## Number of STDIO requests currently awaiting a response (introspection).
func pending_request_count() -> int:
	return _pending.size()


## Build a connection-layer error result. The message is human-readable so a
## panel can surface it directly to the user.
func _conn_error(message: String) -> Dictionary:
	return {"error": message}


## Convert a resolved value into the _stdio_request return contract: success ->
## the full JSON-RPC message (carries "result"); any error -> {"error": <string>}.
func _stdio_finalize(resolved: Dictionary) -> Dictionary:
	if not resolved.has("error"):
		return resolved
	var err = resolved["error"]
	if err is Dictionary:
		return {"error": str(err.get("message", "Unknown error")),
			"rpc_error": err.duplicate(true)}
	return {"error": str(err)}


## Handle a plugin-initiated minerva/capability request received mid-execution.
## Dispatches through capability_request_handler (if set), writes the result
## back to the plugin's stdin, and returns.
func _handle_plugin_capability_request(msg: Dictionary) -> void:
	if protocol_profile.era != Profile.Era.INITIALIZED_LEGACY:
		push_warning("[MCP STDIO] Ignoring proprietary capability request outside the legacy profile")
		return
	var origin_process = _subprocess
	var cap_id = msg.get("id", null)
	var params: Dictionary = msg.get("params", {})
	var capability: String = str(params.get("capability", ""))
	var args: Dictionary = params.get("args", {})

	print("[MCP STDIO] Plugin capability request: %s (id=%s)" % [capability, str(cap_id)])

	var result_payload: Dictionary
	if capability_request_handler.is_valid():
		var broker_result: Dictionary = await capability_request_handler.call(plugin_id, capability, args)
		result_payload = broker_result
	else:
		push_warning("[MCP STDIO] No capability_request_handler set — denying '%s' for plugin '%s'" % [capability, plugin_id])
		result_payload = {
			"success": false,
			"error_code": "no_handler",
			"error_message": "No capability request handler configured",
		}

	# Send JSON-RPC result back to plugin stdin
	var response: Dictionary = {
		"jsonrpc": "2.0",
		"id": cap_id,
		"result": result_payload,
	}
	var response_json := JSON.stringify(response) + "\n"
	print("[MCP STDIO] Writing capability result back: %s" % response_json.left(200))
	if origin_process == null or origin_process != _subprocess:
		return
	if not origin_process.write_data(response_json):
		push_warning("[MCP STDIO] Failed to write capability result back to plugin '%s'" % plugin_id)
		_on_stdio_io_failure()


## STDIO transport: Call a tool
func _call_tool_stdio(tool_name: String, arguments: Dictionary, timeout_sec: float = 120.0, context: ExecutionContext = null) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		return {"error": "STDIO transport not connected"}
	if protocol_profile.era == Profile.Era.MODERN_2026_07_28 \
			and not protocol_profile.supports("tools"):
		return {"error": "Modern MCP server does not advertise the tools capability"}

	# For tools/list, use that method directly. Unwrap the JSON-RPC envelope
	# so callers (refresh_tools) see {tools: [...]} at the top level — matches
	# the post-`rpc_response.get("result")` shape contract used by the other
	# transports and by STDIO profile negotiation.
	if tool_name == "tools/list":
		var list_request := _stdio_method_request("tools/list", {})
		var list_generation := _process_generation
		var list_response := await _stdio_request(list_request, timeout_sec,
			"tools/list", context, list_generation)
		var list_wire = _take_completed_wire(list_request.id)
		if list_wire != null:
			var list_numeric: Dictionary = await WireAdapter.validate_for_application(list_wire)
			if list_generation != _process_generation:
				return {"error": "MCP process changed while validating tools/list"}
			if not list_numeric.get("ok", false):
				return {"error": _wire_validation_message(list_numeric)}
		if context != null and context.is_stopped():
			return context.stopped_result()
		if list_response.get("error"):
			return {"error": str(list_response.error)}
		var inner = list_response.get("result", {})
		if inner is Dictionary:
			return inner
		return {"error": "tools/list response 'result' was not a Dictionary (got type=%d, value=%s)" % [typeof(inner), str(inner).left(120)]}

	# For regular tool calls, use tools/call with wrapped params
	var request := _stdio_method_request("tools/call", {
			"name": tool_name,
			"arguments": arguments
		})

	var call_generation := _process_generation
	var response := await _stdio_request(request, timeout_sec, tool_name, context,
		call_generation)
	var source_wire = _take_completed_wire(request.id)
	if source_wire != null:
		var numeric_check: Dictionary = await WireAdapter.validate_for_application(source_wire)
		if call_generation != _process_generation:
			return {"error": "MCP process changed while validating tool result"}
		if not numeric_check.get("ok", false):
			return {"error": _wire_validation_message(numeric_check)}
	if context != null and context.is_stopped():
		return context.stopped_result()
	if response.get("error"):
		return {"error": str(response.error)}

	var raw_result: Variant = response.get("result", {})
	if raw_result is Dictionary:
		tool_result_envelope_received.emit(tool_name,
			ToolResultEnvelope.from_mcp(raw_result,
				protocol_profile.era == Profile.Era.MODERN_2026_07_28, source_wire))
	var result = _normalize_mcp_tool_result(raw_result)
	tool_result_received.emit(tool_name, result)
	return result


func _normalize_mcp_tool_result(result) -> Dictionary:
	# MCP tools/call wraps plugin payloads as {content: [{type: "text", text: "..."}]}.
	# Return the parsed payload so callers see the tool's actual result.
	if result is Dictionary and result.has("content"):
		var content_raw = result.get("content", [])
		if content_raw is String:
			return {"text": content_raw, "success": true}
		if content_raw is Array and content_raw.size() > 0 and content_raw[0] is Dictionary:
			var content: Array = content_raw
			var content_item: Dictionary = content[0]
			if content_item.get("type") == "text":
				var text_content: String = content_item.get("text", "{}")
				var inner_json := JSON.new()
				var inner_err := inner_json.parse(text_content)
				if inner_err == OK and inner_json.data is Dictionary:
					return inner_json.data
				if inner_err == OK:
					return {"result": inner_json.data, "success": true}
				return {"text": text_content, "success": true}
	if result is Dictionary:
		return result
	return {"result": result, "success": true}


# ---------------------------------------------------------------------------
# STDIO stdout reader + dispatcher
# ---------------------------------------------------------------------------

## The single always-live stdout reader. Connected to the subprocess's
## output_ready signal and also called by the backstop timer. Drains every
## available line and dispatches it: plugin-initiated messages (capability
## requests, event/state/notify) go to their handlers; a JSON-RPC response —
## an "id" with no "method" — is routed to its waiter via _resolve_pending.
func _drain_stdout(expected_process = null) -> void:
	var process = _subprocess
	if process == null or (expected_process != null and expected_process != process) \
			or not process.is_running():
		return

	# Re-guard each iteration: a dispatched message (or engine-exit teardown)
	# can free _subprocess mid-drain, after which has_output() would deref null.
	while process == _subprocess and is_instance_valid(process) and process.has_output():
		var line: String = process.read_line()
		if line.is_empty():
			continue

		var log_line: String = line.left(200)
		if line.length() > 200:
			log_line += "..."
		print("[MCP %s] Received: %s" % [server_name, log_line])

		var json := JSON.new()
		if json.parse(line) != OK or not json.data is Dictionary:
			push_warning("[MCP %s] Unparseable line from plugin '%s': %s"
					% [server_name, plugin_id, line.left(200)])
			continue

		var msg: Dictionary = json.data
		var method: String = str(msg.get("method", ""))

		if method != "":
			# Plugin-initiated message.
			match method:
				"minerva/capability":
					# Bidirectional channel — dispatched as a background
					# coroutine so the reader never blocks on the host's reply.
					if protocol_profile.era == Profile.Era.INITIALIZED_LEGACY:
						_validate_legacy_message_then_dispatch(line, msg,
							_process_generation, _handle_plugin_capability_request)
					else:
						_reject_modern_server_request(msg, _process_generation)
				"minerva/plugin_event":
					if protocol_profile.era == Profile.Era.INITIALIZED_LEGACY:
						_validate_legacy_message_then_dispatch(line, msg,
							_process_generation, _handle_async_plugin_event)
				"minerva/plugin_state":
					if protocol_profile.era == Profile.Era.INITIALIZED_LEGACY:
						_validate_legacy_message_then_dispatch(line, msg,
							_process_generation, _handle_async_plugin_state)
				"host.notify":
					if protocol_profile.era == Profile.Era.INITIALIZED_LEGACY and not msg.has("id"):
						_validate_legacy_message_then_dispatch(line, msg,
							_process_generation, _handle_host_notify)
					else:
						print("[MCP %s] Ignoring host.notify with unexpected id from plugin '%s'"
								% [server_name, plugin_id])
				"notifications/tools/list_changed":
					# go-sdk emits this on startup, safe to ignore.
					pass
				_:
					print("[MCP %s] Unrecognized method from plugin '%s': %s"
							% [server_name, plugin_id, method])
		elif msg.has("id"):
			# A JSON-RPC response — route it to its waiter by id. An unmatched
			# id (a stray frame, or a response to an already-resolved request)
			# is a harmless no-op inside _resolve_pending.
			_route_stdio_response(line, msg, _process_generation)
		else:
			push_warning("[MCP %s] Discarding frame with neither method nor id from plugin '%s'"
					% [server_name, plugin_id])


func _route_stdio_response(raw_line: String, message: Dictionary, generation: int) -> void:
	var request_id: Variant = message.get("id")
	var request_key := Protocol.request_id_key(request_id)
	if not _pending.has(request_key):
		return
	var pending: _PendingRequest = _pending[request_key]
	if pending.generation != generation:
		return
	var shape_error := Protocol.validate_response(message, pending.request_id)
	if not shape_error.is_empty():
		_resolve_pending(pending.request_id,
			_conn_error("Invalid MCP response: %s" % shape_error), null, generation)
		return
	_resolve_pending(request_id, message, WireValue.create(raw_line, message), generation)


func _validate_legacy_message_then_dispatch(raw_line: String, message: Dictionary,
		generation: int, handler: Callable) -> void:
	if protocol_profile.era != Profile.Era.INITIALIZED_LEGACY:
		return
	var shape_error := Protocol.validate_request(message)
	if not shape_error.is_empty():
		push_warning("[MCP STDIO] Rejected malformed legacy callback: %s" % shape_error)
		return
	var numeric_check: Dictionary = await WireAdapter.validate_for_application(
		WireValue.create(raw_line, message))
	if generation != _process_generation or protocol_profile.generation != generation:
		return
	if not numeric_check.get("ok", false):
		push_warning("[MCP STDIO] Rejected legacy callback: %s" %
			_wire_validation_message(numeric_check))
		return
	handler.call(message)


func _reject_modern_server_request(message: Dictionary, generation: int) -> void:
	if protocol_profile.era != Profile.Era.MODERN_2026_07_28 or not message.has("id") \
			or not Protocol.validate_request(message).is_empty():
		return
	_write_stdio_notification({"jsonrpc": Protocol.JSON_RPC_VERSION, "id": message.id,
		"error": {"code": -32601,
			"message": "Proprietary server callbacks are unavailable in modern MCP"}}, generation)


## Low-frequency backstop. Re-drains stdout in case an output_ready signal is
## ever missed, and fails all outstanding requests if the subprocess has died.
## Self-rearming while the subprocess runs; stops once it exits / disconnects.
func _backstop_tick(expected_process = null) -> void:
	if not _subprocess or (expected_process != null and expected_process != _subprocess):
		return
	if not _subprocess.is_running():
		_on_stdio_io_failure(expected_process)
		return
	_drain_stdout(_subprocess)
	Engine.get_main_loop().create_timer(0.25).timeout.connect(_backstop_tick.bind(_subprocess))


func _handle_async_plugin_event(msg: Dictionary) -> void:
	var params: Dictionary = msg.get("params", {})
	var event_name: String = str(params.get("event", ""))
	var payload: Dictionary = params.get("payload", {})

	if event_name.is_empty():
		push_warning("[MCP STDIO Async] Plugin '%s' sent event with empty name" % plugin_id)
		return

	print("[MCP STDIO Async] Plugin '%s' event: %s" % [plugin_id, event_name])

	if event_broker != null:
		event_broker.handle_plugin_event(plugin_id, event_name, payload)
	else:
		push_warning("[MCP STDIO Async] No event_broker set — dropping event '%s' from plugin '%s'" % [event_name, plugin_id])


## Handle a host.notify notification from the plugin.
## Delegates to PluginNotifyRouter (no response is sent — this is a one-way channel).
func _handle_host_notify(msg: Dictionary) -> void:
	var params: Dictionary = msg.get("params", {})
	print("[MCP STDIO] host.notify from plugin '%s': level=%s message=%s" % [
		plugin_id,
		str(params.get("level", "?")),
		str(params.get("message", "")).left(120)
	])
	var RouterScript = load("res://Scripts/Services/Plugins/PluginNotifyRouter.gd")
	if RouterScript:
		RouterScript.route(plugin_id, params)
	else:
		push_warning("[MCP STDIO] PluginNotifyRouter not found — cannot route host.notify from '%s'" % plugin_id)


func _handle_async_plugin_state(msg: Dictionary) -> void:
	var params: Dictionary = msg.get("params", {})
	var state: Dictionary = params.get("state", {})

	if state.is_empty():
		push_warning("[MCP STDIO Async] Plugin '%s' sent empty state update" % plugin_id)
		return

	print("[MCP STDIO Async] Plugin '%s' state update (keys: %s)" % [plugin_id, str(state.keys())])

	if event_broker != null:
		event_broker.handle_plugin_state(plugin_id, state)
	else:
		push_warning("[MCP STDIO Async] No event_broker set — dropping state from plugin '%s'" % plugin_id)


## One in-flight STDIO request. `resolved` fires exactly once — see
## _resolve_pending. tool_name / created_ms back the timeout messages and
## pending-request introspection.
class _PendingRequest extends RefCounted:
	var done := false
	var result: Dictionary = {}
	signal resolved(result: Dictionary)
	var tool_name: String = ""
	var created_ms: int = 0
	var capture_wire := false
	var request_id: Variant
	var generation := 0
	var context: ExecutionContext = null
	var deadline_timeout_sec := 0.0
	var deadline_error: Dictionary = {}
	var deadline
	var deadline_callback: Callable
