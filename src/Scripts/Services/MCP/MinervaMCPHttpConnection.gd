class_name MinervaMCPHttpConnection
extends RefCounted

## Handles a single HTTP connection for MCP protocol requests.
## Parses HTTP requests and formats HTTP responses.
##
## Uses raw byte buffers for accumulation and compares byte counts against
## Content-Length (which is specified in bytes per HTTP spec). This avoids
## mismatches between UTF-8 byte count and GDScript String character count.

enum ConnectionState {
	READING_HEADERS,
	READING_BODY,
	COMPLETE,
	ERROR
}

var stream_peer: StreamPeerTCP
var session_id: String = ""
var state: ConnectionState = ConnectionState.READING_HEADERS
var last_activity_time: float = 0.0

# Raw byte buffer — accumulates TCP data across frames
var _raw_buffer: PackedByteArray = PackedByteArray()

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
	# poll() is REQUIRED to pull new data from OS TCP buffer into StreamPeerTCP.
	# Without it, multi-segment TCP transfers stall after the first read.
	stream_peer.poll()

	if stream_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		state = ConnectionState.ERROR
		return {}

	var available = stream_peer.get_available_bytes()
	if available <= 0:
		return {}

	last_activity_time = Time.get_unix_time_from_system()

	# Read raw bytes (not decoded strings) to preserve byte-accurate counts
	var result = stream_peer.get_data(available)
	if result[0] != OK:
		state = ConnectionState.ERROR
		return {}

	_raw_buffer.append_array(result[1])

	match state:
		ConnectionState.READING_HEADERS:
			return _try_parse_headers()
		ConnectionState.READING_BODY:
			return _try_parse_body()
		_:
			return {}


func _try_parse_headers() -> Dictionary:
	# HTTP headers are always ASCII, so we can safely convert for parsing.
	# Look for the header/body separator in raw bytes: \r\n\r\n = 0D 0A 0D 0A
	var separator := PackedByteArray([0x0D, 0x0A, 0x0D, 0x0A])
	var header_end := _find_bytes(_raw_buffer, separator)
	if header_end == -1:
		return {}

	# Decode header section as ASCII for parsing
	var header_bytes := _raw_buffer.slice(0, header_end)
	var header_section := header_bytes.get_string_from_ascii()
	var lines := header_section.split("\r\n")

	if lines.size() < 1:
		state = ConnectionState.ERROR
		return {}

	# Parse request line: "POST /mcp HTTP/1.1"
	var request_line := lines[0].split(" ")
	if request_line.size() < 2:
		state = ConnectionState.ERROR
		return {}

	_method = request_line[0]
	_path = request_line[1]

	# Parse headers
	for i in range(1, lines.size()):
		var colon_pos := lines[i].find(":")
		if colon_pos > 0:
			var key := lines[i].substr(0, colon_pos).strip_edges().to_lower()
			var value := lines[i].substr(colon_pos + 1).strip_edges()
			_headers[key] = value

	# Get content length (in bytes, per HTTP spec)
	_content_length = int(_headers.get("content-length", "0"))

	# Get session ID from header if present
	if _headers.has("mcp-session-id"):
		session_id = _headers["mcp-session-id"]

	# Remove header bytes from buffer, keep body bytes
	# +4 for the \r\n\r\n separator itself
	_raw_buffer = _raw_buffer.slice(header_end + 4)

	if _content_length > 0:
		state = ConnectionState.READING_BODY
		return _try_parse_body()
	else:
		state = ConnectionState.COMPLETE
		return _build_request_dict()


func _try_parse_body() -> Dictionary:
	# Compare byte counts (both are in bytes now)
	if _raw_buffer.size() >= _content_length:
		_body = _raw_buffer.slice(0, _content_length).get_string_from_utf8()
		_raw_buffer = _raw_buffer.slice(_content_length)
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
	# Encode body to UTF-8 bytes first so Content-Length is accurate
	var body_bytes := body.to_utf8_buffer()
	var header_str := _format_http_headers(status_code, headers, body_bytes.size())
	var header_bytes := header_str.to_utf8_buffer()

	stream_peer.put_data(header_bytes)
	stream_peer.put_data(body_bytes)


## Format just the HTTP response headers (no body).
func _format_http_headers(status_code: int, headers: Dictionary, body_byte_size: int) -> String:
	var status_text := _get_status_text(status_code)
	var response := "HTTP/1.1 %d %s\r\n" % [status_code, status_text]

	# Add default headers
	if not headers.has("Content-Type"):
		headers["Content-Type"] = "application/json"
	if not headers.has("Content-Length"):
		headers["Content-Length"] = str(body_byte_size)
	if not headers.has("Connection"):
		headers["Connection"] = "close"

	# Add CORS headers for browser clients
	headers["Access-Control-Allow-Origin"] = "*"
	headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
	headers["Access-Control-Allow-Headers"] = "Content-Type, MCP-Session-Id, MCP-Protocol-Version"

	for key in headers:
		response += "%s: %s\r\n" % [key, headers[key]]

	response += "\r\n"
	return response


func _get_status_text(code: int) -> String:
	match code:
		200: return "OK"
		202: return "Accepted"
		400: return "Bad Request"
		404: return "Not Found"
		405: return "Method Not Allowed"
		500: return "Internal Server Error"
		_: return "Unknown"


## Find a byte sequence within a PackedByteArray. Returns index or -1.
func _find_bytes(haystack: PackedByteArray, needle: PackedByteArray) -> int:
	if needle.size() == 0 or haystack.size() < needle.size():
		return -1
	for i in range(haystack.size() - needle.size() + 1):
		var found := true
		for j in range(needle.size()):
			if haystack[i + j] != needle[j]:
				found = false
				break
		if found:
			return i
	return -1


## Check if the connection has timed out (no activity for given seconds).
func is_timed_out(timeout_seconds: float = 30.0) -> bool:
	return Time.get_unix_time_from_system() - last_activity_time > timeout_seconds


## Check if the connection is still valid.
func is_peer_connected() -> bool:
	stream_peer.poll()
	return stream_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


## Close the connection.
func close() -> void:
	stream_peer.disconnect_from_host()
