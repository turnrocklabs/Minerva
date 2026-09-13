extends "res://Scripts/Services/Providers/Core/CoreRequest.gd"
## A streaming request separates immediate caller cancellation from transport
## cleanup so an OPEN arriving just afterward can still cancel its producer.

signal stream_opened(meta: Dictionary)
signal stream_chunk(audio: PackedByteArray)
signal stream_ended
signal caller_finished(outcome: Dictionary)

var caller_stopped := false
var header_id := ""
var declared_id := ""
var producer_service_id := ""
var connection_epoch := -1
var caller_result: Dictionary = {}

const MAX_PREOPEN_CANCELS := 64

func start() -> void:
	connection_epoch = client._connection_epoch if is_instance_valid(client) else -1
	super.start()

func cancel() -> void:
	if caller_stopped or not result.is_empty():
		return
	caller_stopped = true
	if not header_id.is_empty() and client._audio_stream_receiver != null:
		client._audio_stream_receiver.cancel(header_id, "cancelled")
		fail("cancelled", "Audio stream cancelled locally.")
	else:
		client._stream_cancel_tombstones[request_id] = connection_epoch
		while client._stream_cancel_tombstones.size() > MAX_PREOPEN_CANCELS:
			var oldest: String = client._stream_cancel_tombstones.keys()[0]
			client._stream_cancel_tombstones.erase(oldest)
			var evicted: RefCounted = client._pending_requests.get(oldest)
			if evicted != null:
				evicted.fail("cancelled", "Cancelled audio stream expired before OPEN.")
		_set_caller_result({"success": false, "error_code": "cancelled", "error_message": "Audio stream cancelled locally."})

func accept_stream_open(header_id_: String, meta: Dictionary, service_id: String) -> bool:
	if connection_epoch != client._connection_epoch:
		fail("core_disconnected", "Audio stream belongs to an expired Core connection.")
		return false
	header_id = header_id_
	client._stream_cancel_tombstones.erase(request_id)
	declared_id = str(meta.get("stream_id", ""))
	producer_service_id = service_id
	if caller_stopped:
		# fail() sends the deferred pre-OPEN cancellation while ownership is known.
		fail("cancelled", "Audio stream cancelled locally.")
		return false
	stream_opened.emit(meta)
	return not caller_stopped and result.is_empty() and header_id == header_id_

func accept_stream_chunk(header_id_: String, audio: PackedByteArray) -> bool:
	if caller_stopped or header_id_ != header_id or not result.is_empty():
		return false
	stream_chunk.emit(audio)
	return not caller_stopped and result.is_empty() and header_id == header_id_

func accept_stream_end(header_id_: String) -> void:
	if caller_stopped or header_id_ != header_id or not result.is_empty():
		return
	stream_ended.emit()
	_succeed("stream")

func fail(code: String, message: String) -> void:
	if is_instance_valid(client):
		client._stream_cancel_tombstones.erase(request_id)
		if not header_id.is_empty() and client._audio_stream_receiver != null and client._audio_streams.has(header_id):
			client._audio_stream_receiver.cancel(header_id, code)
	super.fail(code, message)

func _finish(value: Dictionary) -> void:
	super._finish(value)
	_set_caller_result(result)

func receive_caller_result() -> Dictionary:
	if caller_result.is_empty():
		await caller_finished
	return caller_result

func _set_caller_result(value: Dictionary) -> void:
	if caller_result.is_empty():
		caller_result = value
		caller_finished.emit(caller_result)

func _on_message(data: Dictionary) -> void:
	if not result.is_empty():
		return
	var params: Dictionary = data.get("params", {}) if data.get("params") is Dictionary else {}
	var message_request_id := str(params.get("request_id", ""))
	var message_header_id := str(params.get("msg_id", ""))
	var request_matches := not message_request_id.is_empty() and message_request_id == request_id
	var header_matches := not header_id.is_empty() and not message_header_id.is_empty() and message_header_id == header_id
	# Supplying either identity incorrectly makes the message ambiguous; a
	# producer may otherwise correlate an error by request ID or frame header ID.
	if (not message_request_id.is_empty() and not request_matches) or (not message_header_id.is_empty() and not header_matches):
		return
	if not request_matches and not header_matches:
		return
	# Stream success is informational after END. It must never complete playback.
	if data.get("cmd") != "error":
		return
	fail(str(params.get("error_code", "core_error")), str(params.get("error", "Audio stream failed.")))
