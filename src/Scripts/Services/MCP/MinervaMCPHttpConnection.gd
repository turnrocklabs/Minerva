class_name MinervaMCPHttpConnection
extends RefCounted

## Handles a single HTTP connection for MCP protocol requests.
## Parses HTTP requests and formats HTTP responses.

enum ConnectionState {
	READING_HEADERS,
	READING_BODY,
	COMPLETE,
	ERROR
}

var stream_peer: StreamPeerTCP
var session_id: String = ""
var request_buffer: String = ""
var state: ConnectionState = ConnectionState.READING_HEADERS
var last_activity_time: float = 0.0

# Parsed request data
var _method: String = ""
var _path: String = ""
var _headers: Dictionary = {}
var _content_length: int = 0
var _body: String = ""


func _init(peer: StreamPeerTCP) -> void:
	stream_peer = peer
	last_activity_time = Time.get_unix_time_from_system()


## Process incoming data from the connection.
## Returns a Dictionary with the parsed request if complete, or empty dict if still reading.
func process_data() -> Dictionary:
	if stream_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		state = ConnectionState.ERROR
		return {}

	var available = stream_peer.get_available_bytes()
	if available <= 0:
		return {}

	last_activity_time = Time.get_unix_time_from_system()
	var data = stream_peer.get_utf8_string(available)
	request_buffer += data

	match state:
		ConnectionState.READING_HEADERS:
			return _try_parse_headers()
		ConnectionState.READING_BODY:
			return _try_parse_body()
		_:
			return {}


func _try_parse_headers() -> Dictionary:
	var header_end = request_buffer.find("\r\n\r\n")
	if header_end == -1:
		return {}

	var header_section = request_buffer.substr(0, header_end)
	var lines = header_section.split("\r\n")

	if lines.size() < 1:
		state = ConnectionState.ERROR
		return {}

	# Parse request line: "POST /mcp HTTP/1.1"
	var request_line = lines[0].split(" ")
	if request_line.size() < 2:
		state = ConnectionState.ERROR
		return {}

	_method = request_line[0]
	_path = request_line[1]

	# Parse headers
	for i in range(1, lines.size()):
		var colon_pos = lines[i].find(":")
		if colon_pos > 0:
			var key = lines[i].substr(0, colon_pos).strip_edges().to_lower()
			var value = lines[i].substr(colon_pos + 1).strip_edges()
			_headers[key] = value

	# Get content length
	_content_length = int(_headers.get("content-length", "0"))

	# Get session ID from header if present
	if _headers.has("mcp-session-id"):
		session_id = _headers["mcp-session-id"]

	# Remove headers from buffer, keep body part
	request_buffer = request_buffer.substr(header_end + 4)

	if _content_length > 0:
		state = ConnectionState.READING_BODY
		return _try_parse_body()
	else:
		state = ConnectionState.COMPLETE
		return _build_request_dict()


func _try_parse_body() -> Dictionary:
	if request_buffer.length() >= _content_length:
		_body = request_buffer.substr(0, _content_length)
		request_buffer = request_buffer.substr(_content_length)
		state = ConnectionState.COMPLETE
		return _build_request_dict()
	return {}


func _build_request_dict() -> Dictionary:
	return {
		"method": _method,
		"path": _path,
		"headers": _headers,
		"body": _body,
		"session_id": session_id
	}


## Send an HTTP response back to the client.
func send_response(status_code: int, headers: Dictionary, body: String) -> void:
	var response = _format_http_response(status_code, headers, body)
	stream_peer.put_data(response.to_utf8_buffer())


func _format_http_response(status_code: int, headers: Dictionary, body: String) -> String:
	var status_text = _get_status_text(status_code)
	var response = "HTTP/1.1 %d %s\r\n" % [status_code, status_text]

	# Add default headers
	if not headers.has("Content-Type"):
		headers["Content-Type"] = "application/json"
	if not headers.has("Content-Length"):
		headers["Content-Length"] = str(body.length())
	if not headers.has("Connection"):
		headers["Connection"] = "close"

	# Add CORS headers for browser clients
	headers["Access-Control-Allow-Origin"] = "*"
	headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
	headers["Access-Control-Allow-Headers"] = "Content-Type, MCP-Session-Id, MCP-Protocol-Version"

	for key in headers:
		response += "%s: %s\r\n" % [key, headers[key]]

	response += "\r\n"
	response += body

	return response


func _get_status_text(code: int) -> String:
	match code:
		200: return "OK"
		400: return "Bad Request"
		404: return "Not Found"
		405: return "Method Not Allowed"
		500: return "Internal Server Error"
		_: return "Unknown"


## Check if the connection has timed out (no activity for given seconds).
func is_timed_out(timeout_seconds: float = 30.0) -> bool:
	return Time.get_unix_time_from_system() - last_activity_time > timeout_seconds


## Check if the connection is still valid.
func is_peer_connected() -> bool:
	return stream_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


## Close the connection.
func close() -> void:
	stream_peer.disconnect_from_host()
