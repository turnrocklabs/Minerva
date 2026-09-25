class_name MCPServerConnection
extends RefCounted
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")

const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
## Base class for MCP server connections.
## Handles communication with MCP servers over various transports.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")
const WireValue = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const ToolResultEnvelope = preload("res://Scripts/Services/MCP/MCPToolResult.gd")
const ToolCallOutcome = preload("res://Scripts/Services/MCP/MCPToolCallOutcome.gd")
const ToolResultAdapter = preload("res://Scripts/Services/MCP/MCPToolResultAdapter.gd")
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const StdioNegotiation = preload("res://Scripts/Services/MCP/MCPStdioNegotiation.gd")
const WireAdapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const HttpTransport = preload("res://Scripts/Services/MCP/MCPHttpTransport.gd")
const HttpHeaders = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")
const MonotonicDeadline = preload("res://Scripts/Services/MCP/MCPMonotonicDeadline.gd")
const ToolSchemaRuntime = preload("res://Scripts/Services/MCP/MCPToolSchemaRuntime.gd")
const Diagnostics = preload("res://Scripts/Services/MCP/MCPServerDiagnostics.gd")
const CatalogWatch = preload("res://Scripts/Services/MCP/MCPToolCatalogWatch.gd")

signal connected()
signal disconnected()
signal http_notification_received(message: Dictionary, request_id: Variant)
signal tool_result_received(tool_name: String, result: Dictionary)
signal tool_result_envelope_received(tool_name: String, result)
signal tools_list_changed()
signal catalog_committed()
signal _catalog_refresh_finished(serial: int, result: int)

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
var last_failure_reason: String = ""

## Skip MCP protocol initialization (for REST APIs that don't support it)
var skip_mcp_init: bool = false

## MCP endpoint path (default "/mcp", some servers use "/")
var mcp_endpoint: String = "/mcp"

## Working directory for file operations (sent to server on initialize/set)
var working_directory: String = ""

## Available tools from this server
var tools: Array = []
var _tools_refresh_epoch := 0
var _catalog_refresh_running := false
var _catalog_refresh_dirty := false
var _catalog_refresh_serial := 0
var _catalog_refresh_result: Error = OK
var catalog_conformance_errors: Array[String] = []
const MAX_TOOL_PAGES := 32
const MAX_DISCOVERED_TOOLS := 10000


func _safe_peer_error_category(error_value: Variant) -> String:
	if error_value is Dictionary:
		var code: Variant = error_value.get("code")
		if code is int:
			return "peer error code %d" % code
		if code is float and is_finite(code) and code == floor(code) \
				and abs(code) <= 9007199254740991.0:
			return "peer error code %d" % int(code)
	return "peer error"

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
var _catalog_watch = CatalogWatch.new()
var _catalog_watch_owner = null
var _catalog_watch_retry_token := 0
var _suppress_watch_stop_callback := false
var _stdio_watch_queue: Array[Dictionary] = []
var _stdio_watch_validating := false
const MAX_STDIO_WATCH_QUEUE := 64
const MAX_STDERR_LINES_PER_DRAIN := 32

## MCP protocol version
const MCP_PROTOCOL_VERSION := "2025-06-18"

## Request ID counter
var _request_id_counter: int = 0

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
	_catalog_watch.refresh_requested.connect(_on_catalog_watch_refresh)
	_catalog_watch.stopped.connect(_on_catalog_watch_protocol_stopped)


## Handle stop signal - MCP connections cancel on any stop request
func _on_stop_all_requests(_history_id: String) -> void:
	cancel_active_requests()


## Configure STDIO transport with command and arguments
func configure_stdio(command: String, args: PackedStringArray = []) -> void:
	stdio_command = command
	stdio_args = args
	transport = TransportType.STDIO


## Called with each new process generation as the STDIO child starts, to
## give that child environment entries of its own ({name: value}; none when
## invalid): SubProcess.start_with_env passes them to it alone, never to
## this process's environment. A child that needs them is not started
## without that native support.
var stdio_env_for_generation: Callable = Callable()


## The generation of the process this connection runs (a new one each start).
func process_generation() -> int:
	return _process_generation


## JSON-RPC request `method` with `params` on the STDIO process, for the
## owner of a backend's private methods (PluginPanelAuthority), never
## MCP's own: tools/, resources/, prompts/, notifications/, completion/ and
## logging/ methods, initialize, ping and any name without a "/" are
## refused. The response, as _stdio_request gives it ({result}
## or {error, rpc_error | local_error}), and an error when the process
## changed while it was outstanding.
func request_method(method: String, params: Dictionary, timeout_sec: float = 120.0) -> Dictionary:
	if transport != TransportType.STDIO or _subprocess == null or not _subprocess.is_running():
		return _conn_error("STDIO transport not connected")
	for mcp_prefix in ["tools/", "resources/", "prompts/", "notifications/", "completion/", "logging/"]:
		if method.begins_with(mcp_prefix):
			return _conn_error("%s is an MCP method" % method)
	if method in ["initialize", "ping"] or not method.contains("/"):
		return _conn_error("%s is not a private method" % method)
	var request := _stdio_method_request(method, params)
	var generation := _process_generation
	var response := await _stdio_request(request, timeout_sec, method, null, generation)
	var wire = _take_completed_wire(request.id)
	if wire != null:
		var numeric: Dictionary = await WireAdapter.validate_for_application(wire)
		if generation == _process_generation:
			response = _stdio_finalize(wire.parsed) if numeric.get("ok", false) \
				else _conn_error(_wire_validation_message(numeric))
	if generation != _process_generation:
		return _conn_error("MCP process changed during %s" % method)
	return response


## Connect to the MCP server
func connect_to_server() -> Error:
	last_failure_reason = ""
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
	SingletonObject.verbose_log("[MCP %s] Disconnecting..." % server_name)
	server_connected = false
	_tools_refresh_epoch += 1
	_stop_tool_catalog_watch(true)
	_catalog_watch_owner = null
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
		SingletonObject.verbose_log("[MCP %s] Stopping subprocess..." % server_name)
		# Just stop the subprocess - don't try to free it.
		# The subprocess destructor will call stop() again (safely, as it checks _running).
		# Godot will clean up the node when the scene tree is destroyed.
		disconnected_process.stop()
		# Note: We intentionally don't queue_free() here because during shutdown,
		# the subprocess read thread may have pending deferred calls that would
		# crash if the object is freed too soon.

	SingletonObject.verbose_log("[MCP %s] Disconnected" % server_name)


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
	if _catalog_refresh_running:
		_catalog_refresh_dirty = true
		var waiting_for := _catalog_refresh_serial
		while _catalog_refresh_running and waiting_for == _catalog_refresh_serial:
			await _catalog_refresh_finished
		return _catalog_refresh_result
	_catalog_refresh_running = true
	var result: Error = OK
	while true:
		_catalog_refresh_dirty = false
		result = await _refresh_tools_once()
		if result == OK:
			# Each atomic success becomes authoritative immediately. A dirty
			# follow-up may fail, but cannot hide the last good committed catalog.
			catalog_committed.emit()
		if not _catalog_refresh_dirty:
			break
	_catalog_refresh_result = result
	_catalog_refresh_running = false
	_catalog_refresh_serial += 1
	_catalog_refresh_finished.emit(_catalog_refresh_serial, result)
	return result


func _refresh_tools_once() -> Error:
	SingletonObject.verbose_log("[MCP] Refreshing tools from %s (connected=%s)..." % [server_name, server_connected])

	# Skip tool discovery for REST APIs that don't support MCP protocol
	if skip_mcp_init:
		SingletonObject.verbose_log("[MCP] Skipping tool discovery (REST API mode)")
		return OK

	_tools_refresh_epoch += 1
	var refresh_epoch := _tools_refresh_epoch
	var owner_generation: int = protocol_profile.generation
	var owner_transport = _http_transport if transport == TransportType.HTTP else (
		_subprocess if transport == TransportType.STDIO else _websocket)
	var candidates: Array = []
	var candidate_names := {}
	var candidate_conformance_errors: Array[String] = []
	var seen_cursors := {}
	var cursor := ""
	for page in range(MAX_TOOL_PAGES):
		var params := {} if cursor.is_empty() else {"cursor": cursor}
		var result: Dictionary = await call_tool("tools/list", params)
		if not _owns_catalog_refresh(refresh_epoch, owner_generation, owner_transport):
			return ERR_BUSY
		if result.get("error"):
			last_failure_reason = ("Tool discovery rejected by peer (%s). "
				+ "Check server compatibility.") % _safe_peer_error_category(result.get("error"))
			push_error(last_failure_reason)
			return ERR_QUERY_FAILED
		if protocol_profile.era == Profile.Era.MODERN_2026_07_28:
			if not result.has("resultType"):
				if "Modern tools/list omitted resultType" not in candidate_conformance_errors:
					candidate_conformance_errors.append("Modern tools/list omitted resultType")
			elif result.get("resultType") != "complete":
				push_error("Modern tools/list resultType must be complete")
				return ERR_INVALID_DATA
			var ttl: Variant = result.get("ttlMs")
			if (not ttl is int and not ttl is float) or not is_finite(float(ttl)) \
					or float(ttl) < 0.0 or float(ttl) > Protocol.MAX_SAFE_INTEGER \
					or result.get("cacheScope") not in ["public", "private"]:
				push_error("Modern tools/list returned invalid cache hints")
				return ERR_INVALID_DATA
		var tools_data: Variant = result.get("tools", [])
		if not tools_data is Array:
			push_error("tools/list tools must be an Array")
			return ERR_INVALID_DATA
		if candidates.size() + tools_data.size() > MAX_DISCOVERED_TOOLS:
			push_error("tools/list exceeded the %d-tool catalog limit" % MAX_DISCOVERED_TOOLS)
			return ERR_OUT_OF_MEMORY
		for tool_data: Variant in tools_data:
			if not tool_data is Dictionary:
				push_warning("Excluded non-object MCP tool definition")
				continue
			var input_root: Variant = tool_data.get("inputSchema")
			if not input_root is Dictionary or input_root.get("type") != "object":
				push_warning("Excluded MCP tool with non-object inputSchema root")
				continue
			if tool_data.has("outputSchema"):
				var output_root: Variant = tool_data.outputSchema
				if not output_root is Dictionary:
					push_warning("Excluded MCP tool with non-object outputSchema root")
					continue
			if transport == TransportType.HTTP \
					and protocol_profile.era == Profile.Era.MODERN_2026_07_28:
				var header_check := HttpHeaders.annotations(tool_data.get("inputSchema", {}))
				if not header_check.error.is_empty():
					push_warning("Excluded MCP tool %s: %s" % [tool_data.get("name", ""), header_check.error])
					continue
			var tool_name_value: Variant = tool_data.get("name")
			if not tool_name_value is String or tool_name_value.is_empty():
				push_warning("Excluded MCP tool with empty name")
				continue
			var tool_name: String = tool_name_value
			if candidate_names.has(tool_name):
				push_error("tools/list returned duplicate tool name: %s" % tool_name)
				return ERR_INVALID_DATA
			var native_input: Variant = tool_data.get("inputSchema", {})
			var schema_check: Dictionary = await ToolSchemaRuntime.check_schema(native_input)
			if not _owns_catalog_refresh(refresh_epoch, owner_generation, owner_transport):
				return ERR_BUSY
			if not schema_check.get("ok", false):
				var schema_code := str(schema_check.get("error", {}).get("code", ""))
				if schema_code in ["validator_unavailable", "process_lost", "deadline_exceeded", "queue_full"]:
					push_error("MCP schema validator unavailable during tools/list")
					return ERR_CANT_ACQUIRE_RESOURCE
				push_warning("Excluded MCP tool %s with invalid inputSchema" % tool_name)
				continue
			if tool_data.has("outputSchema"):
				var output_check: Dictionary = await ToolSchemaRuntime.check_schema(tool_data.outputSchema)
				if not _owns_catalog_refresh(refresh_epoch, owner_generation, owner_transport):
					return ERR_BUSY
				if not output_check.get("ok", false):
					var output_code := str(output_check.get("error", {}).get("code", ""))
					if output_code in ["validator_unavailable", "process_lost", "deadline_exceeded", "queue_full"]:
						return ERR_CANT_ACQUIRE_RESOURCE
					push_warning("Excluded MCP tool %s with invalid outputSchema" % tool_name)
					continue
			candidate_names[tool_name] = true
			candidates.append(MCPToolDefinitionScript.from_dict(tool_data, server_name))
		var next_value: Variant = result.get("nextCursor", "")
		if next_value == null or next_value == "":
			tools = candidates
			catalog_conformance_errors = candidate_conformance_errors
			SingletonObject.verbose_log("[MCP] Found %d tools across %d page(s)" % [tools.size(), page + 1])
			return OK
		if not next_value is String or seen_cursors.has(next_value):
			push_error("tools/list returned an invalid or repeated cursor")
			return ERR_INVALID_DATA
		cursor = next_value
		seen_cursors[cursor] = true
	push_error("tools/list exceeded the %d-page limit" % MAX_TOOL_PAGES)
	return ERR_OUT_OF_MEMORY


func _owns_catalog_refresh(epoch: int, generation: int, transport_owner) -> bool:
	var current_owner = _http_transport if transport == TransportType.HTTP else (
		_subprocess if transport == TransportType.STDIO else _websocket)
	return epoch == _tools_refresh_epoch and generation == protocol_profile.generation \
		and transport_owner != null and transport_owner == current_owner


## Call a tool on the MCP server.
## timeout_sec is the STDIO per-request budget (0 = unbounded); HTTP/WebSocket
## transports use their own timeouts and ignore it.
func call_tool(tool_name: String, arguments: Dictionary, timeout_sec: float = 120.0) -> Dictionary:
	if transport == TransportType.WEBSOCKET:
		return await _call_tool_websocket(tool_name, arguments)
	var outcome = await call_tool_outcome(tool_name, arguments, timeout_sec)
	return outcome.application


func call_tool_outcome(tool_name: String, arguments: Dictionary,
		timeout_sec: float = 120.0):
	match transport:
		TransportType.HTTP:
			return await _call_tool_http_outcome(tool_name, arguments)
		TransportType.WEBSOCKET:
			var websocket_outcome = ToolCallOutcome.new()
			websocket_outcome.application = await _call_tool_websocket(tool_name, arguments)
			return websocket_outcome
		TransportType.STDIO:
			return await _call_tool_stdio_outcome(tool_name, arguments, timeout_sec)

	return ToolCallOutcome.failure("Invalid transport type")


## Explicit native lifetime; the existing call_tool API remains unchanged.
func call_tool_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	return await context.run(_call_with_context.bind(tool_name, arguments, context))


func call_tool_outcome_with_context(tool_name: String, arguments: Dictionary,
		context: ExecutionContext):
	if context.is_stopped():
		var stopped = ToolCallOutcome.new()
		stopped.application = context.stopped_result()
		return stopped
	match transport:
		TransportType.HTTP:
			return await _call_tool_http_outcome(tool_name, arguments, context)
		TransportType.STDIO:
			return await _call_tool_stdio_outcome(tool_name, arguments,
				_stdio_budget(context), context)
		TransportType.WEBSOCKET:
			var websocket_outcome = ToolCallOutcome.new()
			websocket_outcome.application = await _call_tool_websocket(tool_name, arguments, context)
			return websocket_outcome
	return ToolCallOutcome.failure("Result-aware transport is unavailable")


# How long a stdio call in `context` may wait: until the context's own
# deadline when it has one (which may be longer than the usual 120 s, as a
# plugin chat provider's turn is), else 120 s.
static func _stdio_budget(context: ExecutionContext) -> float:
	return context.remaining_seconds(0.0) if context.lifetime.deadline_ms > 0 else 120.0


func _call_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	match transport:
		TransportType.STDIO:
			return await _call_tool_stdio(tool_name, arguments, _stdio_budget(context), context)
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
	SingletonObject.verbose_log("[MCP HTTP] Connecting server=%s transport=http" % server_name)

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
			SingletonObject.verbose_log("[MCP HTTP] Health probe server=%s" % server_name)
			var err := http.request(health_url, [], HTTPClient.METHOD_GET)
			if err != OK:
				continue

			var response: Array = await http.request_completed

			if not is_instance_valid(http):
				return ERR_CANT_CONNECT

			var result_code: int = response[0]
			var response_code: int = response[1]

			if result_code == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300:
				SingletonObject.verbose_log("[MCP HTTP] Health check passed server=%s" % server_name)
				health_ok = true
				break

		http.queue_free()

		if not health_ok:
			SingletonObject.verbose_log("[MCP HTTP] Health check failed")
			server_connected = false
			return ERR_CANT_CONNECT

		SingletonObject.verbose_log("[MCP HTTP] Connected (REST API mode)")
		protocol_profile = Profile.custom(_process_generation)
		if _http_transport == null:
			_http_transport = HttpTransport.new()
			_wire_http_transport(_http_transport)
		_http_transport.configure_custom(_get_mcp_endpoint())
		server_connected = true
		connected.emit()
		return OK

	if _http_transport == null:
		_http_transport = HttpTransport.new()
		_wire_http_transport(_http_transport)
	var transport_owner = _http_transport
	var init_result: Dictionary = await transport_owner.connect_endpoint(_get_mcp_endpoint(), working_directory)
	if transport_owner != _http_transport:
		return ERR_CANT_CONNECT
	if init_result.has("error"):
		if init_result.has("discovery_fallback"):
			var discovery: Dictionary = init_result.discovery_fallback
			var initialize: Dictionary = init_result.get("initialize_failure", {})
			last_failure_reason = ("Legacy MCP initialization failed after discovery "
				+ "HTTP %d RPC %d (initialize HTTP %d, %s).") % [
				int(discovery.get("http_status", 0)), int(discovery.get("rpc_code", 0)),
				int(initialize.get("http_status", 0)),
				str(initialize.get("kind", "RPC %d" % int(initialize.get("rpc_code", 0))))]
		else:
			last_failure_reason = "MCP HTTP discovery failed (%s)." % _safe_peer_error_category(
				init_result.get("rpc_error", init_result.get("error")))
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


func _wire_http_transport(http) -> void:
	http.request_notification.connect(_on_http_notification)
	http.catalog_watch_message.connect(_on_http_catalog_watch_message)
	http.catalog_watch_closed.connect(_on_http_catalog_watch_closed)


func start_tool_catalog_watch() -> void:
	if not server_connected or protocol_profile.era != Profile.Era.MODERN_2026_07_28:
		return
	var tools_capability: Variant = protocol_profile.capabilities.get("tools")
	if not tools_capability is Dictionary \
			or tools_capability.get("listChanged") != true:
		return
	var watch_owner = _http_transport if transport == TransportType.HTTP else _subprocess
	if not is_same(_catalog_watch_owner, watch_owner):
		_catalog_watch.reset(protocol_profile.generation)
		_catalog_watch_owner = watch_owner
	_stop_tool_catalog_watch(true)
	var request_id: String = _next_request_id()
	_catalog_watch.begin(protocol_profile.generation, request_id)
	var deadline_token := _catalog_watch_retry_token
	_watch_catalog_ack_deadline(deadline_token, protocol_profile.generation)
	if transport == TransportType.HTTP:
		if _http_transport == null or not _http_transport.start_tools_watch(request_id):
			_on_catalog_watch_closed(true, protocol_profile.generation)
	elif transport == TransportType.STDIO:
		var request := StdioNegotiation.modern_request("subscriptions/listen", request_id,
			{"notifications": {"toolsListChanged": true}})
		if not _write_stdio_notification(request, _process_generation):
			_on_catalog_watch_closed(true, protocol_profile.generation)


func _stop_tool_catalog_watch(send_cancel: bool) -> void:
	_catalog_watch_retry_token += 1
	if send_cancel and transport == TransportType.STDIO \
			and (_catalog_watch.waiting_ack or _catalog_watch.active):
		_write_modern_cancel(_catalog_watch.request_id, _process_generation)
	if _http_transport != null:
		_http_transport.stop_tools_watch()
	_suppress_watch_stop_callback = true
	_catalog_watch.stop(false)
	_suppress_watch_stop_callback = false
	_stdio_watch_queue.clear()


func _on_http_catalog_watch_message(message: Dictionary, owner: int) -> void:
	_catalog_watch.accepts(message, owner)


func _on_http_catalog_watch_closed(_result: Dictionary, owner: int) -> void:
	_on_catalog_watch_closed(_http_catalog_watch_should_retry(_result), owner)


func _http_catalog_watch_should_retry(result: Dictionary) -> bool:
	# Protocol/HTTP refusals are terminal even if their body resembles a valid
	# completion. Only a clean completion or an explicitly classified transport
	# loss starts a fresh subscription attempt.
	if result.has("error"):
		return result.get("subscription_retryable", false) == true
	if int(result.get("status", 0)) < 200 or int(result.get("status", 0)) >= 300:
		return false
	var terminal_message: Variant = result.get("wire").parsed \
		if result.get("wire") != null else null
	return terminal_message is Dictionary \
		and CatalogWatch.is_valid_completion(terminal_message,
			_catalog_watch.request_id)


func _on_catalog_watch_protocol_stopped(owner: int, retry: bool) -> void:
	if _suppress_watch_stop_callback or owner != protocol_profile.generation:
		return
	_catalog_watch_retry_token += 1
	if retry:
		_schedule_catalog_watch_retry(owner)
		return
	if transport == TransportType.HTTP and _http_transport != null:
		_http_transport.stop_tools_watch("HTTP catalog watch declined")
	elif transport == TransportType.STDIO:
		_write_modern_cancel(_catalog_watch.request_id, _process_generation)


func _on_catalog_watch_closed(transient: bool, owner: int) -> void:
	if owner != protocol_profile.generation:
		return
	_suppress_watch_stop_callback = true
	_catalog_watch.stop(transient)
	_suppress_watch_stop_callback = false
	if not transient or not server_connected:
		return
	_schedule_catalog_watch_retry(owner)


func _schedule_catalog_watch_retry(owner: int) -> void:
	var delay_ms := _catalog_watch.retry_delay_ms()
	if delay_ms < 0:
		return
	_catalog_watch_retry_token += 1
	var token := _catalog_watch_retry_token
	_retry_catalog_watch(token, owner, delay_ms)


func _retry_catalog_watch(token: int, owner: int, delay_ms: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.create_timer(float(delay_ms) / 1000.0).timeout
	if token == _catalog_watch_retry_token and owner == protocol_profile.generation \
			and server_connected:
		start_tool_catalog_watch()


func _watch_catalog_ack_deadline(token: int, owner: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.create_timer(float(CatalogWatch.ACK_DEADLINE_MS) / 1000.0).timeout
	if token != _catalog_watch_retry_token or owner != protocol_profile.generation \
			or not _catalog_watch.ack_expired():
		return
	if transport == TransportType.STDIO:
		_write_modern_cancel(_catalog_watch.request_id, _process_generation)
	elif _http_transport != null:
		_http_transport.stop_tools_watch("HTTP catalog watch acknowledgment timed out")
	_on_catalog_watch_closed(true, owner)


func _on_catalog_watch_refresh(owner: int) -> void:
	if not _catalog_watch.take_dirty(owner):
		return
	await refresh_tools()


## HTTP transport owns profile negotiation, bounded streaming and cancellation.
func _call_tool_http(tool_name: String, arguments: Dictionary, context: ExecutionContext = null) -> Dictionary:
	var outcome = await _call_tool_http_outcome(tool_name, arguments, context)
	return outcome.application


func _call_tool_http_outcome(tool_name: String, arguments: Dictionary,
		context: ExecutionContext = null):
	if _http_transport == null:
		return ToolCallOutcome.failure("HTTP transport is not connected")
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
		return ToolCallOutcome.failure("HTTP connection superseded")
	if response.has("error"):
		return ToolCallOutcome.from_error(response)
	if context != null and context.is_stopped():
		var stopped = ToolCallOutcome.new()
		stopped.application = context.stopped_result()
		return stopped
	var raw_result_value: Variant = response.get("result", {})
	if not raw_result_value is Dictionary:
		return ToolCallOutcome.failure("MCP result was not an object")
	var raw_result: Dictionary = raw_result_value
	if method == "tools/list":
		var list_outcome = ToolCallOutcome.new()
		list_outcome.application = raw_result
		return list_outcome
	var envelope = ToolResultEnvelope.from_mcp(raw_result,
		owner.profile.era == Profile.Era.MODERN_2026_07_28, response.get("wire"))
	var outcome = await ToolResultAdapter.adapt(envelope)
	if owner != _http_transport or owner.generation != owner_generation \
			or (context != null and context.is_stopped()):
		return ToolCallOutcome.failure("HTTP request cancelled during result delivery")
	tool_result_envelope_received.emit(tool_name, envelope)
	if owner != _http_transport or owner.generation != owner_generation \
			or (context != null and context.is_stopped()):
		return ToolCallOutcome.failure("HTTP request cancelled after result envelope delivery")
	tool_result_received.emit(tool_name, outcome.application)
	return outcome


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
	var owner: WebSocketPeer = _websocket
	if context != null and context.is_stopped():
		return context.stopped_result()
	if not _websocket_owner_is_live(owner):
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

	var err := owner.send_text(JSON.stringify(request))
	if err != OK:
		return {"error": "Failed to send WebSocket message"}

	# Wait for response with matching ID
	var timeout := 30.0
	var elapsed := 0.0
	while elapsed < timeout:
		if context != null and context.is_stopped():
			return context.stopped_result()
		if not _websocket_owner_is_live(owner):
			return {"error": "WebSocket disconnected"}
		owner.poll()
		if not _websocket_owner_is_live(owner):
			return {"error": "WebSocket disconnected"}
		while owner.get_available_packet_count() > 0:
			var packet := owner.get_packet().get_string_from_utf8()
			var json := JSON.new()
			if json.parse(packet) == OK and json.data is Dictionary:
				var response: Dictionary = json.data
				if response.get("id") == request_id:
					var response_wire = WireValue.create(packet, response)
					var numeric_check: Dictionary = await WireAdapter.validate_for_application(
						response_wire)
					var interrupted := _websocket_delivery_interruption(owner, context,
						"WebSocket request cancelled during numeric validation")
					if not interrupted.is_empty():
						return interrupted
					if not numeric_check.get("ok", false):
						return {"error": _wire_validation_message(numeric_check)}
					response = response_wire.parsed
					var raw_result: Variant = response.get("result", {})
					var result: Dictionary
					if raw_result is Dictionary:
						var envelope = ToolResultEnvelope.from_mcp(raw_result, false, response_wire)
						var outcome = await ToolResultAdapter.adapt(envelope)
						interrupted = _websocket_delivery_interruption(owner, context,
							"WebSocket request cancelled during result adaptation")
						if not interrupted.is_empty():
							return interrupted
						result = outcome.application
						tool_result_envelope_received.emit(tool_name, envelope)
						interrupted = _websocket_delivery_interruption(owner, context,
							"WebSocket request cancelled after result envelope delivery")
						if not interrupted.is_empty():
							return interrupted
					else:
						result = _normalize_mcp_tool_result(raw_result)
						interrupted = _websocket_delivery_interruption(owner, context,
							"WebSocket request cancelled before result delivery")
						if not interrupted.is_empty():
							return interrupted
					tool_result_received.emit(tool_name, result)
					return result

		await Engine.get_main_loop().process_frame
		var wait_interrupted := _websocket_delivery_interruption(owner, context,
			"WebSocket request cancelled while awaiting a response")
		if not wait_interrupted.is_empty():
			return wait_interrupted
		elapsed += Engine.get_main_loop().root.get_process_delta_time()

	return {"error": "WebSocket request timed out"}


func _websocket_owner_is_live(owner: WebSocketPeer) -> bool:
	return owner != null and is_instance_valid(owner) and owner == _websocket \
		and owner.get_ready_state() == WebSocketPeer.STATE_OPEN


func _websocket_delivery_interruption(owner: WebSocketPeer,
		context: ExecutionContext, message: String) -> Dictionary:
	if context != null and context.is_stopped():
		return context.stopped_result()
	if not _websocket_owner_is_live(owner):
		return {"error": message, "error_code": "cancelled"}
	return {}


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
	SingletonObject.verbose_log("[MCP STDIO] Connecting server=%s" % server_name)
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
		push_error("Cannot spawn MCP subprocess: scene tree rejected the node (shutting down?)")
		_subprocess.free()
		_subprocess = null
		return ERR_CANT_CREATE

	# Start the subprocess, with environment entries of its own when its
	# owner gives some for this generation.
	SingletonObject.verbose_log("[MCP STDIO] Starting subprocess...")
	var extra_env: Dictionary = {}
	if stdio_env_for_generation.is_valid():
		var given = stdio_env_for_generation.call(connection_generation)
		extra_env = given if given is Dictionary else {}
		if extra_env.is_empty():
			push_error("MCP server '%s' needs environment entries for its start, and has none" % server_name)
			_subprocess.queue_free()
			_subprocess = null
			return ERR_CANT_CREATE
	if not extra_env.is_empty() and not created_process.has_method("start_with_env"):
		push_error("MCP server '%s' needs an environment of its own, which this terminal extension cannot give; rebuild it" % server_name)
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CREATE
	var started: bool = created_process.start_with_env(stdio_command, stdio_args, extra_env) \
		if not extra_env.is_empty() else created_process.start(stdio_command, stdio_args)
	if not started:
		push_error("Failed to start MCP server subprocess for '%s'" % server_name)
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CREATE

	# Attach readers as soon as the child starts. A worker may write diagnostics
	# during startup, before it is ready for the protocol handshake.
	var connected_process = created_process
	if connected_process.has_signal("output_ready"):
		connected_process.output_ready.connect(_drain_stdout.bind(connected_process))
	if connected_process.has_signal("stderr_ready"):
		connected_process.stderr_ready.connect(_drain_stderr.bind(connected_process))
	if connected_process.has_signal("io_overflow"):
		connected_process.io_overflow.connect(_on_stdio_io_failure.bind(connected_process))

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
	# Low-frequency backstop: re-drain in case an output signal is ever missed,
	# and fail outstanding requests if the subprocess dies.
	_backstop_tick(connected_process)

	SingletonObject.verbose_log("[MCP STDIO] Subprocess running, performing MCP handshake...")

	# Probe modern MCP first, then use the initialized legacy lane only when the
	# peer gives no recognized modern response. Both phases share one deadline.
	var init_result := await _negotiate_stdio(connection_generation, startup_deadline_ms)
	if connection_generation != _process_generation or connected_process != _subprocess:
		return ERR_CANT_CONNECT
	if init_result.get("error"):
		if init_result.get("local_error", false):
			last_failure_reason = str(init_result.error)
		else:
			last_failure_reason = ("Handshake rejected by peer (%s). "
				+ "Check protocol compatibility.") % _safe_peer_error_category(init_result.get("error"))
		push_error(last_failure_reason)
		var failed_process = _subprocess
		_subprocess = null
		failed_process.stop()
		failed_process.queue_free()
		return ERR_CANT_CONNECT

	SingletonObject.verbose_log("[MCP STDIO] Handshake successful!")
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
		probe = _stdio_finalize(probe_wire.parsed)
	var classified := StdioNegotiation.classify_discovery(probe)
	if classified.modern:
		if classified.has("error"):
			# A specified modern protocol error proves the peer's era. It is not
			# permission to retry the request through legacy initialization.
			protocol_profile = Profile.modern({}, generation)
			if classified.has("error_code"):
				return {"error": {"code": classified.error_code}}
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
		init = _stdio_finalize(init_wire.parsed)
	var validated := StdioNegotiation.validate_legacy_initialize(init, not plugin_id.is_empty())
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


func _write_stdio_notification(message: Dictionary, generation: int) -> bool:
	var process = _subprocess
	if process == null or generation != _process_generation or not process.is_running():
		return false
	var encoded := JsonSerialization.encode(message)
	if not encoded.get("ok", false):
		return false
	if process.write_data(str(encoded.raw) + "\n"):
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
	SingletonObject.verbose_log("[MCP %s] Sending method=%s id_type=%d" % [
		server_name, str(request.get("method", "")), typeof(request.get("id"))])

	if not _subprocess.write_data(request_json):
		_pending.erase(request_key)
		if context != null and context.lifetime.cancelled.is_connected(on_cancel):
			context.lifetime.cancelled.disconnect(on_cancel)
		_on_stdio_io_failure()
		return _conn_error("failed to write request to MCP server '%s'" % server_name)

	if timeout_sec > 0.0 and not pending.done:
		var label: String = tool_name if tool_name != "" else ("id " + str(request_id))
		pending.deadline_error = _conn_error("MCP request (%s) to '%s' timed out after %s"
				% [label, server_name, Diagnostics.timeout_text(timeout_sec)])
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
	return {"error": message, "local_error": true}


## Convert a resolved value into the _stdio_request return contract: success ->
## the full JSON-RPC message (carries "result"); any error -> {"error": <string>}.
func _stdio_finalize(resolved: Dictionary) -> Dictionary:
	if not resolved.has("error"):
		return resolved
	var err = resolved["error"]
	if err is Dictionary:
		return {"error": str(err.get("message", "Unknown error")),
			"rpc_error": err.duplicate(true)}
	return {"error": str(err), "local_error": resolved.get("local_error", false)}


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

	SingletonObject.verbose_log("[MCP STDIO] Capability request plugin=%s name=%s id_type=%d" % [
		plugin_id, capability, typeof(cap_id)])

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
	var encoded_response := JsonSerialization.encode(response)
	if not encoded_response.get("ok", false):
		push_warning("[MCP STDIO] Capability result contains unsupported JSON values")
		_on_stdio_io_failure(origin_process)
		return
	var response_json: String = encoded_response.raw + "\n"
	SingletonObject.verbose_log("[MCP STDIO] Writing capability result server=%s id_type=%d" % [
		server_name, typeof(cap_id)])
	if origin_process == null or origin_process != _subprocess:
		return
	if not origin_process.write_data(response_json):
		push_warning("[MCP STDIO] Failed to write capability result back to plugin '%s'" % plugin_id)
		_on_stdio_io_failure()


## STDIO transport: Call a tool
func _call_tool_stdio(tool_name: String, arguments: Dictionary, timeout_sec: float = 120.0, context: ExecutionContext = null) -> Dictionary:
	var outcome = await _call_tool_stdio_outcome(tool_name, arguments, timeout_sec, context)
	return outcome.application


func _call_tool_stdio_outcome(tool_name: String, arguments: Dictionary,
		timeout_sec: float = 120.0, context: ExecutionContext = null):
	if not _subprocess or not _subprocess.is_running():
		return ToolCallOutcome.failure("STDIO transport not connected")
	if protocol_profile.era == Profile.Era.MODERN_2026_07_28 \
			and not protocol_profile.supports("tools"):
		return ToolCallOutcome.failure("Modern MCP server does not advertise the tools capability")

	# For tools/list, use that method directly. Unwrap the JSON-RPC envelope
	# so callers (refresh_tools) see {tools: [...]} at the top level — matches
	# the post-`rpc_response.get("result")` shape contract used by the other
	# transports and by STDIO profile negotiation.
	if tool_name == "tools/list":
		var list_request := _stdio_method_request("tools/list", arguments)
		var list_generation := _process_generation
		var list_response := await _stdio_request(list_request, timeout_sec,
			"tools/list", context, list_generation)
		var list_wire = _take_completed_wire(list_request.id)
		if list_wire != null:
			var list_numeric: Dictionary = await WireAdapter.validate_for_application(list_wire)
			if list_generation != _process_generation:
				return ToolCallOutcome.failure("MCP process changed while validating tools/list")
			if not list_numeric.get("ok", false):
				return ToolCallOutcome.failure(_wire_validation_message(list_numeric))
			list_response = _stdio_finalize(list_wire.parsed)
		if context != null and context.is_stopped():
			var stopped = ToolCallOutcome.new()
			stopped.application = context.stopped_result()
			return stopped
		if list_response.get("error"):
			return ToolCallOutcome.from_error(list_response)
		var inner = list_response.get("result", {})
		if inner is Dictionary:
			var list_outcome = ToolCallOutcome.new()
			list_outcome.application = inner
			return list_outcome
		return ToolCallOutcome.failure("tools/list response 'result' was not a Dictionary (got type=%d, value=%s)" % [typeof(inner), str(inner).left(120)])

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
			return ToolCallOutcome.failure("MCP process changed while validating tool result")
		if not numeric_check.get("ok", false):
			return ToolCallOutcome.failure(_wire_validation_message(numeric_check))
		response = _stdio_finalize(source_wire.parsed)
	if context != null and context.is_stopped():
		var stopped = ToolCallOutcome.new()
		stopped.application = context.stopped_result()
		return stopped
	if response.get("error"):
		return ToolCallOutcome.from_error(response)

	var raw_result: Variant = response.get("result", {})
	if not raw_result is Dictionary:
		return ToolCallOutcome.failure("MCP tool result must be an object")
	var envelope = ToolResultEnvelope.from_mcp(raw_result,
		protocol_profile.era == Profile.Era.MODERN_2026_07_28, source_wire)
	var outcome = await ToolResultAdapter.adapt(envelope)
	if call_generation != _process_generation or (context != null and context.is_stopped()):
		return ToolCallOutcome.failure("MCP request cancelled during result delivery")
	tool_result_envelope_received.emit(tool_name, envelope)
	if call_generation != _process_generation or (context != null and context.is_stopped()):
		return ToolCallOutcome.failure("MCP request cancelled after result envelope delivery")
	tool_result_received.emit(tool_name, outcome.application)
	return outcome


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

		var json := JSON.new()
		if json.parse(line) != OK or not json.data is Dictionary:
			push_warning("[MCP %s] Plugin '%s' sent an unparseable frame"
					% [server_name, plugin_id])
			continue

		var msg: Dictionary = json.data
		var method: String = str(msg.get("method", ""))
		SingletonObject.verbose_log("[MCP %s] Received kind=%s id_type=%d" % [server_name,
			"request" if not method.is_empty() else "response", typeof(msg.get("id"))])

		if method in ["notifications/subscriptions/acknowledged",
				"notifications/tools/list_changed"]:
			if _matches_stdio_catalog_watch(msg):
				_queue_stdio_catalog_watch_frame(line, msg, _process_generation)
		elif method != "":
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
						SingletonObject.verbose_log("[MCP %s] Ignoring host.notify with unexpected id from plugin '%s'"
								% [server_name, plugin_id])
				"notifications/tools/list_changed":
					if protocol_profile.era == Profile.Era.INITIALIZED_LEGACY:
						tools_list_changed.emit()
				_:
					SingletonObject.verbose_log("[MCP %s] Unrecognized method from plugin '%s': %s"
							% [server_name, plugin_id, method])
		elif msg.has("id") and (_catalog_watch.waiting_ack or _catalog_watch.active) \
				and Protocol.request_id_key(msg.id) \
				== Protocol.request_id_key(_catalog_watch.request_id):
			_queue_stdio_catalog_watch_frame(line, msg, _process_generation)
		elif msg.has("id"):
			# A JSON-RPC response — route it to its waiter by id. An unmatched
			# id (a stray frame, or a response to an already-resolved request)
			# is a harmless no-op inside _resolve_pending.
			_route_stdio_response(line, msg, _process_generation)
		else:
			push_warning("[MCP %s] Discarding frame with neither method nor id from plugin '%s'"
					% [server_name, plugin_id])


## Drain worker diagnostics continuously so a chatty but healthy MCP server
## cannot fill the native bounded stderr queue. Diagnostic content is
## deliberately discarded: peer-controlled stderr may contain tool payloads,
## credentials, or multiline terminal control data. The captured process
## identity prevents a deferred signal from draining a replacement process.
func _drain_stderr(expected_process = null) -> void:
	var process = _subprocess
	if process == null or (expected_process != null and expected_process != process) \
			or not is_instance_valid(process):
		return

	# Match one native queue's line capacity per callback so a continuously
	# refilling peer cannot monopolize the main thread. Ready notifications and
	# the backstop schedule subsequent bounded drains.
	var drained := 0
	while drained < MAX_STDERR_LINES_PER_DRAIN and process == _subprocess \
			and is_instance_valid(process) and process.has_stderr():
		process.read_stderr_line()
		drained += 1


func _matches_stdio_catalog_watch(message: Dictionary) -> bool:
	if not (_catalog_watch.waiting_ack or _catalog_watch.active):
		return false
	var params: Variant = message.get("params")
	if not params is Dictionary:
		return false
	var metadata: Variant = params.get("_meta")
	if not metadata is Dictionary:
		return false
	return Protocol.request_id_key(metadata.get(
		"io.modelcontextprotocol/subscriptionId")) \
		== Protocol.request_id_key(_catalog_watch.request_id)


func _queue_stdio_catalog_watch_frame(raw_line: String, message: Dictionary,
		generation: int) -> void:
	if protocol_profile.era != Profile.Era.MODERN_2026_07_28 \
			or generation != _process_generation:
		return
	if _stdio_watch_queue.size() >= MAX_STDIO_WATCH_QUEUE:
		_stdio_watch_queue.clear()
		_write_modern_cancel(_catalog_watch.request_id, _process_generation)
		_on_catalog_watch_closed(true, protocol_profile.generation)
		return
	_stdio_watch_queue.append({"raw": raw_line, "message": message,
		"generation": generation, "profile_generation": protocol_profile.generation,
		"attempt": _catalog_watch.attempt,
		"request_key": Protocol.request_id_key(_catalog_watch.request_id)})
	if not _stdio_watch_validating:
		_process_stdio_catalog_watch_queue()


func _process_stdio_catalog_watch_queue() -> void:
	if _stdio_watch_validating:
		return
	_stdio_watch_validating = true
	while not _stdio_watch_queue.is_empty():
		var item: Dictionary = _stdio_watch_queue.pop_front()
		var generation := int(item.generation)
		var profile_generation := int(item.profile_generation)
		var attempt := int(item.attempt)
		var request_key := str(item.request_key)
		var wire = WireValue.create(str(item.raw), item.message)
		var checked: Dictionary = await WireAdapter.validate_for_application(wire)
		if generation != _process_generation \
				or profile_generation != protocol_profile.generation \
				or attempt != _catalog_watch.attempt \
				or request_key != Protocol.request_id_key(_catalog_watch.request_id):
			continue
		if not checked.get("ok", false):
			_on_catalog_watch_closed(false, profile_generation)
			continue
		var message: Dictionary = wire.parsed
		if message.has("method") and message.has("id"):
			_on_catalog_watch_closed(false, profile_generation)
			continue
		var shape_error := Protocol.validate_request(message) if message.has("method") \
			else Protocol.validate_response(message, _catalog_watch.request_id)
		if not shape_error.is_empty():
			_on_catalog_watch_closed(false, profile_generation)
			continue
		_catalog_watch.accepts(message, profile_generation)
	_stdio_watch_validating = false


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
		_report_dropped_event(message, "malformed: %s" % shape_error)
		return
	var wire = WireValue.create(raw_line, message)
	var numeric_check: Dictionary = await WireAdapter.validate_for_application(wire)
	if generation != _process_generation or protocol_profile.generation != generation:
		return
	if not numeric_check.get("ok", false):
		push_warning("[MCP STDIO] Rejected legacy callback: %s" %
			_wire_validation_message(numeric_check))
		_report_dropped_event(message, _wire_validation_message(numeric_check))
		return
	message = wire.parsed
	handler.call(message)


# A plugin event rejected before it reached the event broker is reported to
# it (PluginEventBroker.report_dropped_event), so its consumers learn of the
# gap even when no later event shows one. A dropped event of a process that
# has since changed is not reported: the change itself is the interruption.
func _report_dropped_event(message: Dictionary, reason: String) -> void:
	if str(message.get("method", "")) == "minerva/plugin_event" and event_broker != null:
		event_broker.report_dropped_event(plugin_id, reason)


func _reject_modern_server_request(message: Dictionary, generation: int) -> void:
	if protocol_profile.era != Profile.Era.MODERN_2026_07_28 or not message.has("id") \
			or not Protocol.validate_request(message).is_empty():
		return
	_write_stdio_notification({"jsonrpc": Protocol.JSON_RPC_VERSION, "id": message.id,
		"error": {"code": -32601,
			"message": "Proprietary server callbacks are unavailable in modern MCP"}}, generation)


## Low-frequency backstop. Re-drains both output streams in case a ready signal
## is ever missed, and fails all outstanding requests if the subprocess dies.
## Self-rearming while the subprocess runs; stops once it exits / disconnects.
func _backstop_tick(expected_process = null) -> void:
	if not _subprocess or (expected_process != null and expected_process != _subprocess):
		return
	var process = _subprocess
	if not process.is_running():
		_on_stdio_io_failure(expected_process)
		return
	_drain_stdout(process)
	# Dispatching stdout can synchronously disconnect or replace the process.
	# Never let an old timer drain or rearm itself for the replacement owner.
	if process != _subprocess or not is_instance_valid(process):
		return
	_drain_stderr(process)
	if process != _subprocess or not is_instance_valid(process):
		return
	Engine.get_main_loop().create_timer(0.25).timeout.connect(_backstop_tick.bind(process))


func _handle_async_plugin_event(msg: Dictionary) -> void:
	var params: Dictionary = msg.get("params", {})
	var event_name: String = str(params.get("event", ""))
	var payload: Dictionary = params.get("payload", {})

	if event_name.is_empty():
		push_warning("[MCP STDIO Async] Plugin '%s' sent event with empty name" % plugin_id)
		_report_dropped_event(msg, "an event with no name")
		return

	SingletonObject.verbose_log("[MCP STDIO Async] Plugin '%s' event: %s" % [plugin_id, event_name])

	if event_broker != null:
		event_broker.handle_plugin_event(plugin_id, event_name, payload)
	else:
		push_warning("[MCP STDIO Async] No event_broker set — dropping event '%s' from plugin '%s'" % [event_name, plugin_id])


## Handle a host.notify notification from the plugin.
## Delegates to PluginNotifyRouter (no response is sent — this is a one-way channel).
func _handle_host_notify(msg: Dictionary) -> void:
	var params: Dictionary = msg.get("params", {})
	SingletonObject.verbose_log("[MCP STDIO] host.notify plugin=%s level=%s" % [
		plugin_id, str(params.get("level", "?"))])
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

	SingletonObject.verbose_log("[MCP STDIO Async] Plugin '%s' state update key_count=%d" % [plugin_id, state.size()])

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
