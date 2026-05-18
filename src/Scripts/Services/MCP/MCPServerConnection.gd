class_name MCPServerConnection
extends RefCounted
## Base class for MCP server connections.
## Handles communication with MCP servers over various transports.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")

signal connected()
signal disconnected()
signal tool_result_received(tool_name: String, result: Dictionary)

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

## Pending requests awaiting responses (for async operations)
var _pending_requests: Dictionary = {}  # request_id -> {callback, tool_name}

## Active HTTP requests that can be cancelled
var _active_http_requests: Array[HTTPRequest] = []

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

## True while _stdio_request is actively polling. When true, the async handler
## defers to the polling loop (which already handles all message types).
var _in_stdio_request: bool = false

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

	# Clear pending requests
	_pending_requests.clear()

	if _websocket:
		_websocket.close()
		_websocket = null
	if _subprocess:
		print("[MCP %s] Stopping subprocess..." % server_name)
		# Just stop the subprocess - don't try to free it.
		# The subprocess destructor will call stop() again (safely, as it checks _running).
		# Godot will clean up the node when the scene tree is destroyed.
		_subprocess.stop()
		# Note: We intentionally don't queue_free() here because during shutdown,
		# the subprocess read thread may have pending deferred calls that would
		# crash if the object is freed too soon.
		_subprocess = null

	print("[MCP %s] Disconnected" % server_name)
	disconnected.emit()


## Cancel all active HTTP requests (called when user presses stop)
func cancel_active_requests() -> void:
	for request in _active_http_requests:
		if is_instance_valid(request):
			if request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
				request.cancel_request()
			request.queue_free()
	_active_http_requests.clear()


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
			var tool = MCPToolDefinitionScript.from_dict(tool_data, server_name)
			tools.append(tool)
	else:
		print("[MCP] WARNING: tools_data is not an Array: %s" % typeof(tools_data))

	return OK


## Call a tool on the MCP server
func call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	match transport:
		TransportType.HTTP:
			return await _call_tool_http(tool_name, arguments)
		TransportType.WEBSOCKET:
			return await _call_tool_websocket(tool_name, arguments)
		TransportType.STDIO:
			return await _call_tool_stdio(tool_name, arguments)

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
		server_connected = true
		connected.emit()
		return OK

	# For MCP servers, the initialize handshake IS the connection verification
	print("[MCP HTTP] Performing MCP initialize handshake...")

	var init_result := await _http_initialize()
	if init_result.get("error"):
		push_error("MCP HTTP initialization failed: %s" % init_result.get("error"))
		server_connected = false
		return ERR_CANT_CONNECT

	print("[MCP HTTP] Connected with session: %s" % _session_id.left(16))
	server_connected = true
	connected.emit()
	return OK


## Get the MCP endpoint URL using configured endpoint path
func _get_mcp_endpoint() -> String:
	var url = base_url.rstrip("/")
	if mcp_endpoint == "/":
		return url
	return url + mcp_endpoint


## HTTP transport: Perform MCP initialize handshake
func _http_initialize() -> Dictionary:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)

	var request_id := _next_request_id()
	var init_params := {
		"protocolVersion": MCP_PROTOCOL_VERSION,
		"clientInfo": {
			"name": "Minerva",
			"version": "1.0.0"
		}
	}
	# Include working directory if set
	if not working_directory.is_empty():
		init_params["workingDirectory"] = working_directory

	var body := JSON.stringify({
		"jsonrpc": "2.0",
		"method": "initialize",
		"params": init_params,
		"id": request_id
	})

	var headers := [
		"Content-Type: application/json",
		"MCP-Protocol-Version: %s" % MCP_PROTOCOL_VERSION
	]

	var mcp_url := _get_mcp_endpoint()
	print("[MCP HTTP] Sending initialize request to %s..." % mcp_url)
	var err := http.request(mcp_url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(err)}

	var response: Array = await http.request_completed

	if not is_instance_valid(http):
		return {"error": "Request was cancelled"}

	http.queue_free()

	var result_code: int = response[0]
	var response_code: int = response[1]
	var response_headers: PackedStringArray = response[2]
	var response_body: PackedByteArray = response[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"error": "HTTP request failed with result: %s" % result_code}

	if response_code < 200 or response_code >= 300:
		return {"error": "HTTP error: %s" % response_code}

	# Extract session ID from headers
	for header in response_headers:
		if header.to_lower().begins_with("mcp-session-id:"):
			_session_id = header.substr(15).strip_edges()
			print("[MCP HTTP] Got session ID: %s" % _session_id.left(16))
			break

	var body_str := response_body.get_string_from_utf8().strip_edges()
	print("[MCP HTTP] Initialize response (%d bytes): %s" % [body_str.length(), body_str.left(300)])

	# Empty response is OK for initialize (session ID in header is what matters)
	if body_str.is_empty() or body_str == "":
		print("[MCP HTTP] Empty body, but got session ID - treating as success")
		return {}

	var json := JSON.new()
	var parse_err := json.parse(body_str)
	if parse_err != OK:
		print("[MCP HTTP] JSON parse error: %s at line %d" % [json.get_error_message(), json.get_error_line()])
		return {"error": "Failed to parse JSON response"}

	var rpc_response: Dictionary = json.data if json.data is Dictionary else {}

	if rpc_response.has("error"):
		var rpc_error = rpc_response.get("error", {})
		if rpc_error is Dictionary:
			return {"error": rpc_error.get("message", "Unknown RPC error")}
		return {"error": str(rpc_error)}

	return rpc_response.get("result", {})


## HTTP transport: Call a tool via HTTP POST (JSON-RPC format)
func _call_tool_http(tool_name: String, arguments: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()

	# Need to add to scene tree for HTTPRequest to work
	if Engine.get_main_loop():
		Engine.get_main_loop().root.add_child(http)
		_active_http_requests.append(http)
	else:
		push_error("Cannot make HTTP request: no scene tree available")
		return {"error": "No scene tree available"}

	# JSON-RPC request to MCP endpoint
	var url := _get_mcp_endpoint()
	var headers := [
		"Content-Type: application/json",
		"MCP-Protocol-Version: %s" % MCP_PROTOCOL_VERSION
	]
	# Include session ID if we have one
	if not _session_id.is_empty():
		headers.append("Mcp-Session-Id: %s" % _session_id)

	var request_id := _next_request_id()

	# For special MCP methods (initialize, tools/list, set_working_directory), use directly
	# For tool calls, wrap in tools/call format per MCP spec
	var method: String
	var params: Dictionary
	if tool_name in ["initialize", "tools/list", "notifications/initialized", "set_working_directory"]:
		method = tool_name
		params = arguments
	else:
		method = "tools/call"
		params = {"name": tool_name, "arguments": arguments}

	var body := JSON.stringify({
		"jsonrpc": "2.0",
		"method": method,
		"params": params,
		"id": request_id
	})

	print("[MCP HTTP] Calling %s with %s" % [tool_name, str(arguments).left(100)])

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_active_http_requests.erase(http)
		http.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(err)}

	# Wait for response
	var response: Array = await http.request_completed

	# Guard against cancelled requests: if cancel_active_requests() queue_free()'d
	# this HTTPRequest during the await, the node is freed and we must bail out.
	if not is_instance_valid(http):
		return {"error": "Request was cancelled"}

	_active_http_requests.erase(http)
	http.queue_free()

	var result_code: int = response[0]
	var response_code: int = response[1]
	var _response_headers: PackedStringArray = response[2]
	var response_body: PackedByteArray = response[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		print("[MCP HTTP] Request failed: result=%d" % result_code)
		return {"error": "HTTP request failed with result: %s" % result_code}

	if response_code < 200 or response_code >= 300:
		print("[MCP HTTP] HTTP error: %d" % response_code)
		return {"error": "HTTP error: %s" % response_code}

	var response_str := response_body.get_string_from_utf8()
	print("[MCP HTTP] Response: %s" % response_str.left(200))

	var json := JSON.new()
	var parse_err := json.parse(response_str)
	if parse_err != OK:
		return {"error": "Failed to parse JSON response"}

	var rpc_response: Dictionary = json.data if json.data is Dictionary else {}

	# Check for JSON-RPC error
	if rpc_response.has("error"):
		var rpc_error = rpc_response.get("error", {})
		if rpc_error is Dictionary:
			return {"error": rpc_error.get("message", "Unknown RPC error")}
		return {"error": str(rpc_error)}

	# Extract result from JSON-RPC response
	var result = rpc_response.get("result", {})

	# MCP tool results are wrapped in content array: {content: [{type, text}]}
	# Extract and parse the actual result from content[0].text
	if result is Dictionary and result.has("content"):
		var content_raw = result.get("content", [])
		# Handle case where content is a string instead of array
		if content_raw is String:
			result = {"text": content_raw, "success": true}
		elif content_raw is Array and content_raw.size() > 0 and content_raw[0] is Dictionary:
			var content: Array = content_raw
			var content_item: Dictionary = content[0]
			if content_item.get("type") == "text":
				var text_content: String = content_item.get("text", "{}")
				var inner_json := JSON.new()
				var inner_err := inner_json.parse(text_content)
				if inner_err == OK and inner_json.data is Dictionary:
					result = inner_json.data
				elif inner_err == OK:
					result = {"result": inner_json.data, "success": true}
				else:
					# If parsing fails, return the raw text
					result = {"text": text_content, "success": true}

	if result is Dictionary:
		tool_result_received.emit(tool_name, result)
		return result
	# Handle non-dict results (wrap them)
	return {"result": result, "success": true}


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

	server_connected = true
	connected.emit()
	return OK


## WebSocket transport: Call a tool
func _call_tool_websocket(tool_name: String, arguments: Dictionary) -> Dictionary:
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
		_websocket.poll()
		while _websocket.get_available_packet_count() > 0:
			var packet := _websocket.get_packet().get_string_from_utf8()
			var json := JSON.new()
			if json.parse(packet) == OK and json.data is Dictionary:
				var response: Dictionary = json.data
				if response.get("id") == request_id:
					var result: Dictionary = response.get("result", {})
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

	if stdio_command.is_empty():
		push_error("STDIO transport requires command to be set")
		return ERR_INVALID_PARAMETER

	# Create SubProcess node (check if GDExtension is available)
	if not ClassDB.class_exists("SubProcess"):
		push_error("SubProcess GDExtension not available - STDIO transport not supported")
		return ERR_UNAVAILABLE
	_subprocess = ClassDB.instantiate("SubProcess")

	if not Engine.get_main_loop():
		push_error("Cannot spawn subprocess: no scene tree available")
		return ERR_CANT_CREATE

	Engine.get_main_loop().root.add_child(_subprocess)

	# Start the subprocess
	print("[MCP STDIO] Starting subprocess...")
	if not _subprocess.start(stdio_command, stdio_args):
		push_error("Failed to start MCP server subprocess: %s" % stdio_command)
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CREATE

	# Give process time to start
	await Engine.get_main_loop().create_timer(0.1).timeout

	if not _subprocess.is_running():
		push_error("MCP server subprocess exited immediately")
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CONNECT

	# Drain plugin-initiated messages (notifications, capability requests
	# arriving outside a tool call) the moment they land. Without this, plugin
	# notifications written AFTER a tool response sit in the pipe until the
	# next tool call's _stdio_request loop happens to read them — which means
	# panel state_changed events would lag by one MCP roundtrip. _on_async_*
	# functions self-gate on _in_stdio_request so this signal is harmless when
	# a tool call is in flight.
	if _subprocess.has_signal("output_ready") and not _subprocess.output_ready.is_connected(_on_async_output_ready):
		_subprocess.output_ready.connect(_on_async_output_ready)

	print("[MCP STDIO] Subprocess running, performing MCP handshake...")

	# Perform MCP initialization handshake
	var init_result := await _mcp_initialize()
	if init_result.get("error"):
		push_error("MCP initialization failed: %s" % init_result.get("error"))
		_subprocess.stop()
		_subprocess.queue_free()
		_subprocess = null
		return ERR_CANT_CONNECT

	print("[MCP STDIO] Handshake successful!")
	server_connected = true
	connected.emit()
	return OK


## Send MCP initialize request
func _mcp_initialize() -> Dictionary:
	var request := {
		"jsonrpc": "2.0",
		"id": _next_request_id(),
		"method": "initialize",
		"params": {
			"protocolVersion": MCP_PROTOCOL_VERSION,
			"capabilities": {},
			"clientInfo": {
				"name": "Minerva",
				"version": "1.0.0"
			}
		}
	}

	var response := await _stdio_request(request)
	if response.get("error"):
		return response

	# Send initialized notification (no response expected)
	var init_notification := {
		"jsonrpc": "2.0",
		"method": "notifications/initialized"
	}
	_subprocess.write_data(JSON.stringify(init_notification) + "\n")

	return response.get("result", {})


## Generate next request ID
func _next_request_id() -> String:
	_request_id_counter += 1
	return str(_request_id_counter)


## Send a JSON-RPC request over STDIO and wait for response.
## Handles interleaved plugin-initiated capability requests (bidirectional channel):
## while waiting for our response, the plugin may send minerva/capability requests
## on stdout. We dispatch them through capability_request_handler and write results
## back on stdin before continuing to poll for our original response.
func _stdio_request(request: Dictionary) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		print("[MCP STDIO] Error: Subprocess not running")
		return {"error": "Subprocess not running"}

	_in_stdio_request = true

	var request_id: String = str(request.get("id", ""))
	var request_json := JSON.stringify(request) + "\n"

	# Debug: Log request (truncated for readability)
	var log_json := request_json.left(200)
	if request_json.length() > 200:
		log_json += "..."
	print("[MCP STDIO] Sending: %s" % log_json)

	# Send request
	if not _subprocess.write_data(request_json):
		print("[MCP STDIO] Error: Failed to write to subprocess")
		_in_stdio_request = false
		return {"error": "Failed to write to subprocess"}

	# Wait for response with matching ID
	var timeout := 30.0
	var elapsed := 0.0
	var poll_interval := 0.01

	while elapsed < timeout:
		if _subprocess.has_output():
			var line: String = _subprocess.read_line()
			if line.is_empty():
				continue

			# Debug: Log response (truncated for readability)
			var log_line: String = line.left(200)
			if line.length() > 200:
				log_line += "..."
			print("[MCP STDIO] Received: %s" % log_line)

			var json := JSON.new()
			if json.parse(line) == OK and json.data is Dictionary:
				var msg: Dictionary = json.data

				# Bidirectional channel: detect plugin-initiated capability requests.
				# A plugin request has a "method" field and is NOT a response to our
				# pending request (i.e., its id doesn't match request_id, or it has
				# no matching id in _pending_requests). We specifically handle
				# "minerva/capability" method.
				if msg.has("method") and msg.get("method") == "minerva/capability":
					await _handle_plugin_capability_request(msg)
					continue

				# Route event/state notifications that arrive during a tool call
				if msg.has("method") and msg.get("method") == "minerva/plugin_event":
					_handle_async_plugin_event(msg)
					continue
				if msg.has("method") and msg.get("method") == "minerva/plugin_state":
					_handle_async_plugin_state(msg)
					continue

				# host.notify: plugin → host notification; no id, no response needed
				if msg.has("method") and msg.get("method") == "host.notify" and not msg.has("id"):
					_handle_host_notify(msg)
					continue

				# Check if this is our response
				if str(msg.get("id", "")) == request_id:
					if msg.has("error"):
						var err = msg.get("error", {})
						if err is Dictionary:
							_in_stdio_request = false
							_drain_pending_async()
							return {"error": err.get("message", "Unknown error")}
						_in_stdio_request = false
						_drain_pending_async()
						return {"error": str(err)}
					_in_stdio_request = false
					# Drain any plugin-initiated notifications that arrived
					# between writing our response and us reading it. Plugins
					# emit `minerva/plugin_event` (e.g. scansort's state_changed)
					# immediately after the tool response; output_ready may have
					# fired while _in_stdio_request was still true, so its
					# handler bailed and the buffered data has no fresh signal
					# to trigger a re-drain. Explicitly poll here.
					_drain_pending_async()
					return msg

		await Engine.get_main_loop().create_timer(poll_interval).timeout
		elapsed += poll_interval

	print("[MCP STDIO] Error: Request timed out after %.1fs" % timeout)
	_in_stdio_request = false
	return {"error": "STDIO request timed out"}


## Handle a plugin-initiated minerva/capability request received mid-execution.
## Dispatches through capability_request_handler (if set), writes the result
## back to the plugin's stdin, and returns.
func _handle_plugin_capability_request(msg: Dictionary) -> void:
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
	if not _subprocess.write_data(response_json):
		push_warning("[MCP STDIO] Failed to write capability result back to plugin '%s'" % plugin_id)


## STDIO transport: Call a tool
func _call_tool_stdio(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		return {"error": "STDIO transport not connected"}

	# For tools/list, use that method directly. Unwrap the JSON-RPC envelope
	# so callers (refresh_tools) see {tools: [...]} at the top level — matches
	# the post-`rpc_response.get("result")` shape contract that _call_tool_http
	# and _mcp_initialize already implement on this connection.
	if tool_name == "tools/list":
		var list_request := {
			"jsonrpc": "2.0",
			"id": _next_request_id(),
			"method": "tools/list",
			"params": {}
		}
		var list_response := await _stdio_request(list_request)
		if list_response.get("error"):
			return list_response
		var inner = list_response.get("result", {})
		if inner is Dictionary:
			return inner
		return {"error": "tools/list response 'result' was not a Dictionary (got type=%d, value=%s)" % [typeof(inner), str(inner).left(120)]}

	# For regular tool calls, use tools/call with wrapped params
	var request := {
		"jsonrpc": "2.0",
		"id": _next_request_id(),
		"method": "tools/call",
		"params": {
			"name": tool_name,
			"arguments": arguments
		}
	}

	var response := await _stdio_request(request)
	if response.get("error"):
		return response

	var result = _normalize_mcp_tool_result(response.get("result", {}))
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
# Async output handling (between tool calls)
# ---------------------------------------------------------------------------

## Synchronously drain any pending plugin-initiated messages (notifications,
## capability requests). Safe to call after _in_stdio_request is cleared.
## Mirrors the routing logic in _on_async_output_ready; factored out so
## _stdio_request can call it explicitly without relying on output_ready
## re-firing for already-buffered data.
func _drain_pending_async() -> void:
	if _in_stdio_request:
		return
	_on_async_output_ready()


## Called when SubProcess emits output_ready outside of a tool call.
## Drains the output queue and routes messages to appropriate handlers.
func _on_async_output_ready() -> void:
	# If we're inside _stdio_request, that loop handles draining — don't double-drain.
	if _in_stdio_request:
		return

	if not _subprocess or not _subprocess.is_running():
		return

	while _subprocess.has_output():
		var line: String = _subprocess.read_line()
		if line.is_empty():
			continue

		var json := JSON.new()
		if json.parse(line) != OK or not json.data is Dictionary:
			push_warning("[MCP STDIO Async] Unparseable line from plugin '%s': %s" % [plugin_id, line.left(200)])
			continue

		var msg: Dictionary = json.data

		# Route based on method
		var method: String = str(msg.get("method", ""))
		match method:
			"minerva/capability":
				# Capability request outside a tool call — still dispatch it
				_handle_plugin_capability_request(msg)
			"minerva/plugin_event":
				_handle_async_plugin_event(msg)
			"minerva/plugin_state":
				_handle_async_plugin_state(msg)
			"host.notify":
				# Plugin → host notification (no id, no response)
				if not msg.has("id"):
					_handle_host_notify(msg)
				else:
					print("[MCP STDIO Async] Ignoring host.notify with unexpected id from plugin '%s'" % plugin_id)
			"notifications/tools/list_changed":
				# go-sdk emits this on startup, safe to ignore
				pass
			_:
				if not method.is_empty():
					print("[MCP STDIO Async] Unrecognized method from plugin '%s': %s" % [plugin_id, method])
				# Messages with an "id" but no "method" are responses to requests
				# we didn't send (or late responses). Log and discard.
				elif msg.has("id"):
					print("[MCP STDIO Async] Unexpected response from plugin '%s' (id=%s)" % [plugin_id, str(msg.get("id", ""))])


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
