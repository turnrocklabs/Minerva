class_name MCPServerConnection
extends RefCounted
## Base class for MCP server connections.
## Handles communication with MCP servers over various transports.

const MCPToolDefinitionScript := preload("res://Scripts/Services/MCP/MCPToolDefinition.gd")

signal connected()
signal disconnected()
signal error_occurred(message: String)
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
var is_connected: bool = false

## Available tools from this server
var tools: Array = []

## HTTP client for making requests
var _http_client: HTTPRequest = null

## WebSocket client for persistent connections
var _websocket: WebSocketPeer = null

## SubProcess for STDIO transport
var _subprocess: SubProcess = null

## Pending requests awaiting responses (for async operations)
var _pending_requests: Dictionary = {}  # request_id -> {callback, tool_name}

## MCP protocol version
const MCP_PROTOCOL_VERSION := "2025-06-18"

## Request ID counter
var _request_id_counter: int = 0

## MCP session ID (for HTTP transport)
var _session_id: String = ""


func _init(name: String = "", url: String = "", type: TransportType = TransportType.HTTP) -> void:
	server_name = name
	base_url = url
	transport = type


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
	is_connected = false

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


## List available tools from the server
func list_tools() -> Array:
	if tools.is_empty():
		await refresh_tools()
	return tools


## Refresh the list of available tools from the server
func refresh_tools() -> Error:
	print("[MCP] Refreshing tools from %s (connected=%s)..." % [server_name, is_connected])
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


## HTTP transport: Verify connection and perform MCP initialization
func _verify_http_connection() -> Error:
	print("[MCP HTTP] Connecting to %s..." % base_url)

	var http := HTTPRequest.new()

	if Engine.get_main_loop():
		Engine.get_main_loop().root.add_child(http)
	else:
		push_error("Cannot make HTTP request: no scene tree available")
		return ERR_CANT_CONNECT

	# Try health endpoint first (Nudge-specific)
	var health_url := "%s/health" % base_url
	print("[MCP HTTP] Health check: %s" % health_url)
	var err := http.request(health_url, [], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		is_connected = false
		return err

	var response: Array = await http.request_completed
	http.queue_free()

	var result_code: int = response[0]
	var response_code: int = response[1]

	if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		print("[MCP HTTP] Health check failed: result=%d, status=%d" % [result_code, response_code])
		is_connected = false
		return ERR_CANT_CONNECT

	print("[MCP HTTP] Health check OK, performing MCP initialize...")

	# Now perform MCP initialize to get session ID
	var init_result := await _http_initialize()
	if init_result.get("error"):
		push_error("MCP HTTP initialization failed: %s" % init_result.get("error"))
		is_connected = false
		return ERR_CANT_CONNECT

	print("[MCP HTTP] Connected with session: %s" % _session_id.left(16))
	is_connected = true
	connected.emit()
	return OK


## HTTP transport: Perform MCP initialize handshake
func _http_initialize() -> Dictionary:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)

	var request_id := _next_request_id()
	var body := JSON.stringify({
		"jsonrpc": "2.0",
		"method": "initialize",
		"params": {
			"protocolVersion": MCP_PROTOCOL_VERSION,
			"clientInfo": {
				"name": "Minerva",
				"version": "1.0.0"
			}
		},
		"id": request_id
	})

	var headers := [
		"Content-Type: application/json",
		"MCP-Protocol-Version: %s" % MCP_PROTOCOL_VERSION
	]

	print("[MCP HTTP] Sending initialize request...")
	var err := http.request(base_url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(err)}

	var response: Array = await http.request_completed
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
	else:
		push_error("Cannot make HTTP request: no scene tree available")
		return {"error": "No scene tree available"}

	# JSON-RPC request to root endpoint
	var url := base_url
	var headers := [
		"Content-Type: application/json",
		"MCP-Protocol-Version: %s" % MCP_PROTOCOL_VERSION
	]
	# Include session ID if we have one
	if not _session_id.is_empty():
		headers.append("Mcp-Session-Id: %s" % _session_id)

	var request_id := _next_request_id()
	var body := JSON.stringify({
		"jsonrpc": "2.0",
		"method": tool_name,
		"params": arguments,
		"id": request_id
	})

	print("[MCP HTTP] Calling %s with %s" % [tool_name, str(arguments).left(100)])

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(err)}

	# Wait for response
	var response: Array = await http.request_completed
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
		var content: Array = result.get("content", [])
		if content.size() > 0 and content[0] is Dictionary:
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

	is_connected = true
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

	# Create SubProcess node
	_subprocess = SubProcess.new()

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
	is_connected = true
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
	var notification := {
		"jsonrpc": "2.0",
		"method": "notifications/initialized"
	}
	_subprocess.write_data(JSON.stringify(notification) + "\n")

	return response.get("result", {})


## Generate next request ID
func _next_request_id() -> String:
	_request_id_counter += 1
	return str(_request_id_counter)


## Send a JSON-RPC request over STDIO and wait for response
func _stdio_request(request: Dictionary) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		print("[MCP STDIO] Error: Subprocess not running")
		return {"error": "Subprocess not running"}

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
		return {"error": "Failed to write to subprocess"}

	# Wait for response with matching ID
	var timeout := 30.0
	var elapsed := 0.0
	var poll_interval := 0.01

	while elapsed < timeout:
		if _subprocess.has_output():
			var line := _subprocess.read_line()
			if line.is_empty():
				continue

			# Debug: Log response (truncated for readability)
			var log_line := line.left(200)
			if line.length() > 200:
				log_line += "..."
			print("[MCP STDIO] Received: %s" % log_line)

			var json := JSON.new()
			if json.parse(line) == OK and json.data is Dictionary:
				var response: Dictionary = json.data

				# Check if this is our response
				if str(response.get("id", "")) == request_id:
					if response.has("error"):
						var err = response.get("error", {})
						if err is Dictionary:
							return {"error": err.get("message", "Unknown error")}
						return {"error": str(err)}
					return response

		await Engine.get_main_loop().create_timer(poll_interval).timeout
		elapsed += poll_interval

	print("[MCP STDIO] Error: Request timed out after %.1fs" % timeout)
	return {"error": "STDIO request timed out"}


## STDIO transport: Call a tool
func _call_tool_stdio(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not _subprocess or not _subprocess.is_running():
		return {"error": "STDIO transport not connected"}

	# For tools/list, use that method directly
	if tool_name == "tools/list":
		var request := {
			"jsonrpc": "2.0",
			"id": _next_request_id(),
			"method": "tools/list",
			"params": {}
		}
		return await _stdio_request(request)

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

	var result = response.get("result", {})
	tool_result_received.emit(tool_name, result)
	return result
