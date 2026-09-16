extends RefCounted
## Each POST owns one socket and one terminal result. Cancellation never relies
## on a node signal whose emitter may have been freed by disconnect.
const Decoder = preload("res://Scripts/Services/MCP/MCPSseDecoder.gd")
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const Adapter = preload("res://Scripts/Services/MCP/MCPWireAdapter.gd")
const Deadline = preload("res://Scripts/Services/MCP/MCPMonotonicDeadline.gd")
signal request_notification(message: Dictionary, request_id: Variant)
var done := false
var result: Dictionary = {}
# HTTPClient owns header/trailer parsing. These receive postparse limits below;
# the engine does not expose a preallocation cap for that parsing.
var client := HTTPClient.new()
var deadline = Deadline.new()
var submitted := false
var status := 0
var response_headers := PackedStringArray()
var _context = null

func cancel(reason: String = "cancelled") -> void:
	_finish({"error": reason, "error_code": "cancelled", "outcome_unknown": submitted})

func _finish(value: Dictionary) -> void:
	if done:
		return
	done = true
	result = value
	deadline.cancel()
	client.close()

func execute(url: String, headers: PackedStringArray, request: Dictionary, body: PackedByteArray, timeout: float, context = null) -> Dictionary:
	_context = context
	client.read_chunk_size = 65536
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {"error": "No scene tree available"}
	deadline.expired.connect(_timeout)
	if not deadline.start(timeout):
		return {"error": "Cannot start HTTP deadline"}
	if context != null:
		context.lifetime.cancelled.connect(_cancel_context)
	var regex := RegEx.new()
	regex.compile("^(https?)://(\\[[^]]+\\]|[^/:?#]+)(?::([0-9]+))?([^#]*)$")
	var parsed := regex.search(url)
	if parsed == null or parsed.get_string(2).contains("@"):
		_finish({"error": "Invalid HTTP endpoint"})
	else:
		var secure := parsed.get_string(1) == "https"
		var port := int(parsed.get_string(3)) if not parsed.get_string(3).is_empty() else (443 if secure else 80)
		var host := parsed.get_string(2).trim_prefix("[").trim_suffix("]")
		var path := parsed.get_string(4)
		if path.is_empty():
			path = "/"
		var error := client.connect_to_host(host, port, TLSOptions.client() if secure else null)
		if error != OK:
			_finish({"error": "HTTP connect failed: " + error_string(error)})
		var connecting_until := Time.get_ticks_msec() + 10000
		while not done and client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
			client.poll()
			if Time.get_ticks_msec() >= connecting_until:
				_finish({"error": "HTTP connection timed out"})
			await tree.process_frame
		if not done:
			if body.size() > 32 * 1024 * 1024:
				_finish({"error": "HTTP request exceeds byte budget"})
			elif client.get_status() != HTTPClient.STATUS_CONNECTED:
				_finish({"error": "HTTP connection failed"})
			else:
				error = client.request_raw(HTTPClient.METHOD_POST, path, headers, body)
				submitted = error == OK
				if error != OK:
					_finish({"error": "HTTP request failed: " + error_string(error)})
		while not done and client.get_status() == HTTPClient.STATUS_REQUESTING:
			client.poll()
			await tree.process_frame
		if not done:
			if not client.has_response():
				_finish({"error": "HTTP peer closed before response", "outcome_unknown": submitted})
			else:
				await _receive(tree, request)
	if deadline.expired.is_connected(_timeout):
		deadline.expired.disconnect(_timeout)
	if context != null and context.lifetime.cancelled.is_connected(_cancel_context):
		context.lifetime.cancelled.disconnect(_cancel_context)
	return result

func _timeout() -> void:
	_finish({"error": "HTTP request deadline exceeded", "error_code": "deadline_exceeded", "outcome_unknown": submitted})

func _cancel_context() -> void:
	cancel("HTTP request cancelled")

func _receive(tree: SceneTree, request: Dictionary) -> void:
	status = client.get_response_code()
	response_headers = client.get_response_headers()
	var header_size := 0
	var content_type := ""
	for header: String in response_headers:
		header_size += header.to_utf8_buffer().size()
		if header.to_utf8_buffer().size() > 8192:
			_finish({"error": "Response header exceeds byte budget"})
		if header.to_lower().begins_with("content-type:"):
			content_type = header.substr(13).split(";")[0].strip_edges().to_lower()
	if header_size > 65536:
		_finish({"error": "Response headers exceed byte budget"})
	if not request.has("id") and status == 202:
		_finish({"result": {}, "status": status})
		return
	if content_type not in ["application/json", "text/event-stream"]:
		_finish({"error": "Unsupported HTTP response Content-Type", "status": status})
		return
	var expected_length := client.get_response_body_length()
	var chunked := client.is_response_chunked()
	var decoder = Decoder.new()
	var body := PackedByteArray()
	while not done and client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		var chunk := client.read_response_body_chunk()
		if content_type == "text/event-stream":
			var frames: Array[PackedByteArray] = decoder.feed(chunk)
			if not decoder.error.is_empty():
				_finish({"error": decoder.error, "status": status})
			for frame: PackedByteArray in frames:
				if done:
					break
				await _frame(frame, request, true)
		else:
			body.append_array(chunk)
			if body.size() > 32 * 1024 * 1024:
				_finish({"error": "HTTP response exceeds byte budget", "status": status})
		if not done:
			await tree.process_frame
	if not done and client.get_status() in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
		_finish({"error": "HTTP response body interrupted", "status": status, "outcome_unknown": submitted})
	if not done and content_type == "application/json":
		if (chunked and client.get_status() != HTTPClient.STATUS_CONNECTED) or (not chunked and expected_length >= 0 and body.size() != expected_length):
			_finish({"error": "Incomplete HTTP response framing", "status": status, "outcome_unknown": submitted})
	if not done and content_type == "application/json":
		await _frame(body, request, false)
	if not done:
		_finish({"error": "HTTP stream ended without final response", "status": status, "outcome_unknown": submitted})

func _frame(bytes: PackedByteArray, request: Dictionary, streaming: bool) -> void:
	var raw := bytes.get_string_from_utf8()
	if raw.to_utf8_buffer() != bytes:
		_finish({"error": "Invalid UTF-8 in HTTP response", "status": status})
		return
	var json := JSON.new()
	if json.parse(raw) != OK or not json.data is Dictionary:
		_finish({"error": "Invalid JSON-RPC response", "status": status})
		return
	var message: Dictionary = json.data
	var wire = Wire.create(raw, message)
	var checked: Dictionary = await Adapter.validate_for_application(wire)
	if done:
		return
	if not checked.get("ok", false):
		_finish({"error": "Unsafe MCP numeric representation", "validation": checked, "status": status})
		return
	message = wire.parsed
	if message.has("method"):
		if not streaming or not Protocol.validate_request(message).is_empty() or message.has("id"):
			_finish({"error": "Unexpected server request on HTTP response stream", "status": status})
			return
		if message.method == "notifications/progress":
			var expected: Variant = request.get("params", {}).get("_meta", {}).get("progressToken")
			if expected == null or message.get("params", {}).get("progressToken") != expected:
				_finish({"error": "HTTP progress does not match its originating request", "status": status})
				return
			request_notification.emit(message, request.id)
		elif message.method == "notifications/message" and request.get("params", {}).get("_meta", {}).has("io.modelcontextprotocol/logLevel"):
			request_notification.emit(message, request.id)
		return
	var error := Protocol.validate_response(message, request.get("id"))
	if not error.is_empty():
		_finish({"error": error, "status": status})
	elif message.has("error"):
		_finish({"error": message.error.message, "rpc_error": message.error, "status": status, "wire": wire})
	elif status < 200 or status >= 300:
		_finish({"error": "HTTP error: %d" % status, "status": status, "wire": wire})
	else:
		_finish({"result": message.result, "status": status, "wire": wire, "headers": response_headers})
