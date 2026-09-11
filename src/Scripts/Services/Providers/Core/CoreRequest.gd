extends RefCounted
## One owned Core operation or an explicitly long-lived publication subscription.

signal finished(result: Dictionary)
signal message_received(msg: Dictionary)

var client: Node
var topic: String = ""
var cmd: String = ""
var request_id: String = "":
	set(value):
		if _started and value != request_id:
			fail("invalid_request", "An active Core request cannot change identity.")
		else:
			request_id = value
var timeout: float = 10000.0
var completion: String = "json":
	set(value):
		if _started and value != completion:
			fail("invalid_completion", "Choose Core completion mode before sending.")
		else:
			completion = value
var result: Dictionary = {}
var _started := false
var _subscription := false
var _timer: Timer
var _json: Dictionary = {}
var _binary := PackedByteArray()
var _has_json := false
var _has_binary := false
var _remote_error := false


func _init(client_: Node) -> void:
	client = client_


func start() -> void:
	if _started or not result.is_empty():
		return
	_started = true
	if not is_instance_valid(client) or not client.is_inside_tree():
		fail("core_offline", "Core connection is unavailable.")
		return
	if completion not in ["json", "binary", "either", "both"]:
		fail("invalid_completion", "Unknown Core completion mode.")
		return
	if not request_id.is_empty() and not _subscription:
		if client._pending_requests.has(request_id):
			fail("duplicate_request", "Core request ID is already active.")
			return
		client._pending_requests[request_id] = self
	client.message_received.connect(_on_message)
	client.connection_closed.connect(_on_disconnect)
	client.tree_exiting.connect(_on_disconnect)
	if not _subscription:
		reset_timeout()


func reset_timeout() -> void:
	if is_instance_valid(_timer):
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if not _started or _subscription or not result.is_empty():
		return
	if not is_finite(timeout) or timeout <= 0:
		fail("timeout", "Core request timed out.")
		return
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timeout)
	client.add_child(_timer)
	_timer.start(timeout)


func _matches(data: Dictionary) -> bool:
	var params: Variant = data.get("params", {})
	if not request_id.is_empty() and (not params is Dictionary or params.get("request_id") != request_id):
		return false
	# Errors correlated by request ID are terminal even if cmd/topic differs.
	if not _subscription and not request_id.is_empty() and data.get("cmd") == "error":
		return true
	return (topic.is_empty() or data.get("topic") == topic) and (cmd.is_empty() or data.get("cmd") == cmd)


func _on_message(data: Dictionary) -> void:
	if not result.is_empty() or not _matches(data):
		return
	if _subscription:
		message_received.emit(data)
		return
	var params: Dictionary = data.get("params", {}) if data.get("params", {}) is Dictionary else {}
	var body: Dictionary = params.get("result", {}) if params.get("result", {}) is Dictionary else {}
	if data.get("cmd") == "error" or not str(body.get("error", "")).is_empty():
		_json = data
		_remote_error = true
		fail(str(params.get("error_code", body.get("error_code", "core_error"))), str(params.get("error", body.get("error", "Core request failed."))))
		return
	_json = data
	_has_json = true
	if completion == "json" or (completion == "either" and body.get("transfer_mode") != "binary") or (completion == "both" and _has_binary):
		_succeed("both" if completion == "both" else "json")


func accepts_binary() -> bool:
	return _started and result.is_empty() and not _subscription and completion in ["binary", "either", "both"] and not _has_binary


func accept_binary(audio: PackedByteArray, header: Dictionary) -> void:
	if not accepts_binary():
		return
	_binary = audio
	_has_binary = true
	if _json.is_empty():
		_json = header
	if completion != "both" or _has_json:
		_succeed("both" if completion == "both" else "binary")


func _succeed(kind: String) -> void:
	_finish({"success": true, "kind": kind, "request_id": request_id, "json": _json, "binary": _binary})


func fail(code: String, message: String) -> void:
	_finish({"success": false, "request_id": request_id, "error_code": code, "error_message": message, "json": _json, "remote_error": _remote_error})


func cancel() -> void:
	fail("cancelled", "Request cancelled locally; remote execution may continue.")


func _on_timeout() -> void:
	fail("timeout", "Core request timed out after %s seconds." % timeout)


func _on_disconnect() -> void:
	fail("core_disconnected", "Core connection closed before completion.")


func _finish(value: Dictionary) -> void:
	if not result.is_empty():
		return
	result = value
	if is_instance_valid(_timer):
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if is_instance_valid(client):
		for pair in [[client.message_received, _on_message], [client.connection_closed, _on_disconnect], [client.tree_exiting, _on_disconnect]]:
			if pair[0].is_connected(pair[1]):
				pair[0].disconnect(pair[1])
		if client._pending_requests.get(request_id) == self:
			client._pending_requests.erase(request_id)
			client.release_voice_request(request_id)
	_binary = PackedByteArray()
	_json = {}
	finished.emit(result)


func receive_result() -> Dictionary:
	start()
	if result.is_empty():
		await finished
	return result


func receive():
	var completed := await receive_result()
	if not completed.success and not completed.get("remote_error", false):
		return null
	var json: Dictionary = completed.get("json", {})
	return json if not json.is_empty() else null


func receive_all() -> Signal:
	if _started and not _subscription:
		fail("invalid_request", "An active Core request cannot become a subscription.")
		return message_received
	_subscription = true
	start()
	return message_received
