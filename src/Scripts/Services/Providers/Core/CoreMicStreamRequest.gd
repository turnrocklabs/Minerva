extends "res://Scripts/Services/Providers/Core/CoreRequest.gd"
## Owns one client-to-Core microphone stream and its final JSON transcript.

const NEW_MESSAGE := 0
const FILE_DATA := 2
const FILE_END := 3
const MAX_AUDIO_BYTES := 16000 * 2 * 300 # Five minutes of mono PCM16.
const MAX_CHUNK_BYTES := 64 * 1024
const CAPTURE_IDLE_SECONDS := 30.0
const CAPTURE_MAX_SECONDS := 300.0
const RESPONSE_SECONDS := 120.0

var stream_id: PackedByteArray = Crypto.new().generate_random_bytes(16)
var service_id := ""
var opened := false
var ended := false
var audio_bytes := 0
var sequence := 0
var connection_epoch := -1
var _cancel_sent := false
var _open_enqueued := false
var _end_enqueued := false
var _capture_timer: Timer


func start() -> void:
	if _started or not result.is_empty():
		return
	connection_epoch = client._connection_epoch if is_instance_valid(client) else -1
	timeout = CAPTURE_IDLE_SECONDS
	super.start()
	if result.is_empty():
		_capture_timer = Timer.new()
		_capture_timer.one_shot = true
		_capture_timer.timeout.connect(_on_capture_timeout)
		client.add_child(_capture_timer)
		_capture_timer.start(CAPTURE_MAX_SECONDS)


func open(service: Service, data: Dictionary) -> Error:
	if opened or ended or not result.is_empty():
		return ERR_ALREADY_IN_USE
	if service == null or stream_id.size() != 16:
		fail("invalid_stream", "Microphone stream identity is unavailable.")
		return ERR_INVALID_PARAMETER
	if connection_epoch != client._connection_epoch or not client._connected:
		fail("core_disconnected", "Core connection changed before microphone capture started.")
		return ERR_CONNECTION_ERROR
	service_id = service.client_id
	var stream_hex := stream_id.hex_encode()
	var envelope := {
		"cmd": "request", "topic": "voice/stt/stream", "entity_type": "client", "msg_id": stream_hex,
		"binary_framing": {"data": "raw", "completion": "stream_end", "mode": "stream", "stream": {
			"conversation_id": request_id, "turn_id": request_id, "stream_id": stream_hex,
			"format": "pcm_s16le", "sample_rate": 16000, "direction": "in"}},
		"params": {"client_id": client.client_id, "request_id": request_id,
			"target_service_id": service_id, "data": data}
	}
	var encoded := JSON.stringify(envelope).to_utf8_buffer()
	var packet := PackedByteArray()
	packet.resize(25 + encoded.size())
	packet[0] = NEW_MESSAGE
	for i in 16:
		packet[1 + i] = stream_id[i]
	packet.encode_u32(17, encoded.size())
	packet.encode_u32(21, 1)
	for i in encoded.size():
		packet[25 + i] = encoded[i]
	opened = true
	var error: Error = client.send_packet(packet)
	_open_enqueued = error == OK
	if error != OK:
		fail("send_failed", "Core could not open the microphone stream.")
		return error
	if not result.is_empty():
		_send_cancel(str(result.get("error_code", "cancelled")))
		return ERR_CONNECTION_ERROR
	reset_timeout()
	return OK


func append_audio(pcm: PackedByteArray) -> Error:
	if not opened or ended or not result.is_empty():
		return ERR_UNCONFIGURED
	if pcm.is_empty() or pcm.size() > MAX_CHUNK_BYTES or pcm.size() % 2 != 0:
		fail("invalid_audio", "Microphone audio chunk is invalid.")
		return ERR_INVALID_DATA
	if connection_epoch != client._connection_epoch or not client._connected:
		fail("core_disconnected", "Core connection changed during microphone capture.")
		return ERR_CONNECTION_ERROR
	if audio_bytes + pcm.size() > MAX_AUDIO_BYTES:
		fail("audio_too_large", "Microphone stream exceeded the five-minute limit.")
		return ERR_OUT_OF_MEMORY
	var packet := PackedByteArray()
	packet.resize(21 + pcm.size())
	packet[0] = FILE_DATA
	for i in 16:
		packet[1 + i] = stream_id[i]
	packet.encode_u32(17, sequence)
	for i in pcm.size():
		packet[21 + i] = pcm[i]
	var next_sequence := sequence + 1
	var next_audio_bytes := audio_bytes + pcm.size()
	var error: Error = client.send_packet(packet)
	if error != OK:
		fail("send_failed", "Core could not enqueue microphone audio.")
		return error
	if not result.is_empty():
		return ERR_CONNECTION_ERROR
	audio_bytes = next_audio_bytes
	sequence = next_sequence
	reset_timeout()
	return OK


func end_stream() -> Error:
	if not opened or ended or not result.is_empty():
		return ERR_UNCONFIGURED
	if connection_epoch != client._connection_epoch or not client._connected:
		fail("core_disconnected", "Core connection changed before microphone capture ended.")
		return ERR_CONNECTION_ERROR
	var packet := PackedByteArray([FILE_END])
	packet.append_array(stream_id)
	ended = true
	var error: Error = client.send_packet(packet)
	_end_enqueued = error == OK
	if error != OK:
		fail("send_failed", "Core could not end the microphone stream.")
		return error
	if is_instance_valid(_capture_timer):
		_capture_timer.stop()
		_capture_timer.queue_free()
		_capture_timer = null
	timeout = RESPONSE_SECONDS
	reset_timeout()
	return OK


func cancel() -> void:
	if not result.is_empty():
		return
	if _open_enqueued:
		_send_cancel("cancelled")
	super.cancel()


func fail(code: String, message: String) -> void:
	if _open_enqueued and not _end_enqueued and code != "cancelled":
		_send_cancel(code)
	super.fail(code, message)


func _send_cancel(reason: String) -> void:
	if _cancel_sent or service_id.is_empty() or connection_epoch != client._connection_epoch:
		return
	_cancel_sent = true
	client.send_text_message_to_core({
		"cmd": "request", "topic": "stream/cancel", "entity_type": "client",
		"params": {"client_id": client.client_id, "request_id": request_id,
			"target_service_id": service_id,
			"data": {"stream_id": stream_id.hex_encode(), "reason": reason}}
	})


func _on_capture_timeout() -> void:
	fail("capture_timeout", "Microphone capture reached the five-minute limit.")


func _finish(value: Dictionary) -> void:
	if is_instance_valid(_capture_timer):
		_capture_timer.stop()
		_capture_timer.queue_free()
		_capture_timer = null
	super._finish(value)


func _on_message(data: Dictionary) -> void:
	var params: Dictionary = data.get("params", {}) if data.get("params") is Dictionary else {}
	var supplied_header_id := str(params.get("msg_id", ""))
	if not supplied_header_id.is_empty() and supplied_header_id != stream_id.hex_encode():
		return
	if data.get("cmd") == "notify" and data.get("topic") == "stream/cancel":
		var control: Dictionary = params.get("data", {}) if params.get("data") is Dictionary else {}
		if params.get("request_id") == request_id and control.get("event") == "stream/cancel" and control.get("stream_id") == stream_id.hex_encode():
			_cancel_sent = true
			fail("stream_cancelled", "Core cancelled the microphone stream.")
		return
	if not _matches(data):
		return
	if data.get("cmd") == "error":
		super._on_message(data)
		return
	if not ended:
		return
	if data.get("cmd") == "response":
		var body: Dictionary = params.get("result", {}) if params.get("result") is Dictionary else {}
		var reply_stream_id := str(body.get("msg_id", ""))
		if not reply_stream_id.is_empty() and reply_stream_id != stream_id.hex_encode():
			return
	super._on_message(data)
