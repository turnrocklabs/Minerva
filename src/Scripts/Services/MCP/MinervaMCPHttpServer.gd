class_name MinervaMCPHttpServer
extends Node

## HTTP server that exposes Minerva's MCP tools to external agents.
## Implements the MCP protocol (JSON-RPC 2.0 over HTTP).

signal server_started(port: int)
signal server_stopped()
signal client_connected(session_id: String)
signal tool_executed(tool_name: String, session_id: String)

const DEFAULT_PORT = 9315
const PROTOCOL_VERSION = "2024-11-05"
const CONNECTION_TIMEOUT = 30.0  # seconds

var _tcp_server: TCPServer = null
var _connections: Array = []  # Array of MinervaMCPHttpConnection
var _sessions: Dictionary = {}  # session_id -> {created_at, last_activity}
var _is_running: bool = false
var _port: int = DEFAULT_PORT
var _inflight_connections: Dictionary = {}  # conn -> true (handling) / false (done)

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
	var err = _tcp_server.listen(port)

	if err != OK:
		push_error("[MCP HTTP] Failed to start server on port %d: %s" % [port, error_string(err)])
		_tcp_server = null
		return err

	_port = port
	_is_running = true

	print("[MCP HTTP] Server started on port %d" % _port)
	server_started.emit(_port)
	return OK


## Stop the HTTP server.
func stop_server() -> void:
	if not _is_running:
		return

	# Close all connections
	for conn in _connections:
		conn.close()
	_connections.clear()
	_inflight_connections.clear()
	_sessions.clear()

	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null

	_is_running = false
	print("[MCP HTTP] Server stopped")
	server_stopped.emit()


## Check if server is running.
func is_running() -> bool:
	return _is_running


## Get the port the server is running on.
func get_port() -> int:
	return _port if _is_running else 0


func _accept_new_connections() -> void:
	if not _tcp_server or not _tcp_server.is_connection_available():
		return

	var peer = _tcp_server.take_connection()
	if peer:
		var conn = MinervaMCPHttpConnectionScript.new(peer)
		_connections.append(conn)


func _process_connections() -> void:
	var to_remove: Array[int] = []

	for i in range(_connections.size()):
		var conn = _connections[i]

		# Skip connections being handled asynchronously
		if _inflight_connections.has(conn):
			if not _inflight_connections[conn]:
				# Handler finished — mark for cleanup
				_inflight_connections.erase(conn)
				to_remove.append(i)
			continue

		# Check for timeout or disconnection
		if conn.is_timed_out(CONNECTION_TIMEOUT) or not conn.is_peer_connected():
			conn.close()
			to_remove.append(i)
			continue

		# Try to read and process request
		var request = conn.process_data()
		if request.is_empty():
			continue

		if conn.state == MinervaMCPHttpConnectionScript.ConnectionState.ERROR:
			conn.close()
			to_remove.append(i)
			continue

		if conn.state == MinervaMCPHttpConnectionScript.ConnectionState.COMPLETE:
			# Fire-and-forget: handle asynchronously without blocking the loop.
			# This allows other connections to be processed while a tool executes.
			_inflight_connections[conn] = true
			_handle_connection_async(conn, request)

	# Remove processed connections (in reverse to maintain indices)
	for i in range(to_remove.size() - 1, -1, -1):
		_connections.remove_at(to_remove[i])


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
	conn.close()
	# Signal to _process_connections that this connection is done
	_inflight_connections[conn] = false


func _handle_request(conn, request: Dictionary) -> void:
	var method = request.get("method", "")
	var path = request.get("path", "")
	var body = request.get("body", "")
	var session_id = request.get("session_id", "")

	# Handle CORS preflight
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

	# Handle JSON-RPC request
	await _handle_jsonrpc(conn, json_body, session_id)


func _handle_jsonrpc(conn, request: Dictionary, session_id: String) -> void:
	var jsonrpc_version = request.get("jsonrpc", "")
	var method = request.get("method", "")
	var params = request.get("params", {})
	var request_id = request.get("id")  # Can be null for notifications

	if jsonrpc_version != "2.0":
		_send_jsonrpc_error(conn, request_id, -32600, "Invalid JSON-RPC version")
		return

	# Route to appropriate handler
	match method:
		"initialize":
			_handle_initialize(conn, params, request_id)
		"notifications/initialized":
			# Notifications don't need a JSON-RPC response, but HTTP requires a response
			conn.send_response(202, {}, "")
		"tools/list":
			_handle_tools_list(conn, params, request_id, session_id)
		"tools/call":
			await _handle_tools_call(conn, params, request_id, session_id)
		_:
			_send_jsonrpc_error(conn, request_id, -32601, "Method not found: %s" % method)


func _handle_initialize(conn, params: Dictionary, request_id) -> void:
	# Create a new session
	var new_session_id = SingletonObject.generate_UUID()
	_sessions[new_session_id] = {
		"created_at": Time.get_unix_time_from_system(),
		"last_activity": Time.get_unix_time_from_system(),
		"client_info": params.get("clientInfo", {})
	}

	client_connected.emit(new_session_id)

	var result = {
		"protocolVersion": PROTOCOL_VERSION,
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
		"MCP-Protocol-Version": PROTOCOL_VERSION
	}

	_send_jsonrpc_result(conn, request_id, result, headers)


func _handle_tools_list(conn, _params: Dictionary, request_id, session_id: String) -> void:
	# Update session activity
	if _sessions.has(session_id):
		_sessions[session_id].last_activity = Time.get_unix_time_from_system()

	# Get all minerva tools from the registry
	var tools: Array[Dictionary] = []

	if _mcp_manager:
		for tool_name in _mcp_manager.tool_registry:
			var tool = _mcp_manager.tool_registry[tool_name]
			# Only include minerva tools (not external MCP server tools)
			if tool.server_name == "minerva":
				tools.append({
					"name": tool.name,
					"description": tool.description,
					"inputSchema": tool.input_schema  # MCP uses camelCase
				})

	var result = {
		"tools": tools
	}

	_send_jsonrpc_result(conn, request_id, result)


func _handle_tools_call(conn, params: Dictionary, request_id, session_id: String) -> void:
	# Update session activity
	if _sessions.has(session_id):
		_sessions[session_id].last_activity = Time.get_unix_time_from_system()

	var tool_name = params.get("name", "")
	var arguments = params.get("arguments", {})

	if tool_name.is_empty():
		_send_jsonrpc_error(conn, request_id, -32602, "Missing tool name")
		return

	# Check if it's a minerva tool
	if not tool_name.begins_with("minerva_"):
		_send_jsonrpc_error(conn, request_id, -32602, "Unknown tool: %s" % tool_name)
		return

	# Execute the tool
	if not _mcp_manager or not _mcp_manager.minerva_server:
		var has_manager := _mcp_manager != null
		var has_server := false
		if _mcp_manager:
			has_server = _mcp_manager.minerva_server != null
		var debug_msg := "Minerva server not available (_mcp_manager=%s, minerva_server=%s)" % [has_manager, has_server]
		print("[MCP HTTP] " + debug_msg)
		_send_jsonrpc_error(conn, request_id, -32603, debug_msg)
		return

	tool_executed.emit(tool_name, session_id)

	var tool_result = await _mcp_manager.minerva_server.execute_tool_for_http(tool_name, arguments)

	# Format result according to MCP spec
	var result_text: String
	if tool_result is Dictionary:
		result_text = JSON.stringify(tool_result)
	else:
		result_text = str(tool_result)

	var result = {
		"content": [
			{
				"type": "text",
				"text": result_text
			}
		]
	}

	_send_jsonrpc_result(conn, request_id, result)


func _send_jsonrpc_result(conn, request_id, result: Dictionary, extra_headers: Dictionary = {}) -> void:
	var response = {
		"jsonrpc": "2.0",
		"result": result,
		"id": request_id
	}

	var body = JSON.stringify(response)
	conn.send_response(200, extra_headers, body)


func _send_jsonrpc_error(conn, request_id, code: int, message: String) -> void:
	var response = {
		"jsonrpc": "2.0",
		"error": {
			"code": code,
			"message": message
		},
		"id": request_id
	}

	var body = JSON.stringify(response)
	conn.send_response(200, {}, body)


func _send_error(conn, status_code: int, message: String) -> void:
	conn.send_response(status_code, {}, message)
