extends SceneTree
## Focused producer contract: exact framing, terminal response, and cancellation.

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	var client = load("res://test/fixtures/core_lifecycle_client.gd").new()
	root.add_child(client)
	client.client_id = "client-test"
	await process_frame
	await _successful_stream(client)
	await _failure_and_cancel_contracts(client)
	await _enqueue_and_inline_failures(client)
	print("=== Core mic stream: %d passed, %d failed ===" % [passed, failed])
	client.free()
	quit(1 if failed else 0)

func _check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _request(client: Node, id: String):
	var request = load("res://Scripts/Services/Providers/Core/CoreMicStreamRequest.gd").new(client)
	request.request_id = id
	request.cmd = "response"
	request.topic = "voice/stt/stream"
	request.start()
	return request

func _service() -> Service:
	return Service.new({"client_id": "voice-service", "actions": []})

func _successful_stream(client: Node) -> void:
	client.sent_packets.clear()
	var request = _request(client, "mic-success")
	_check("OPEN is locally enqueued", request.open(_service(), {"language": "en", "backend": "faster-whisper", "model": "small.en"}) == OK)
	var header := _decode_open(client.sent_packets[0])
	_check("OPEN declares strict mono PCM contract and selected settings", header.topic == "voice/stt/stream" and header.binary_framing.stream.format == "pcm_s16le" and header.binary_framing.stream.sample_rate == 16000 and header.binary_framing.stream.direction == "in" and header.params.data.model == "small.en")
	_check("two chunks enqueue in strict sequence", request.append_audio(PackedByteArray([1, 0, 2, 0])) == OK and request.append_audio(PackedByteArray([3, 0])) == OK and client.sent_packets[1].decode_u32(17) == 0 and client.sent_packets[2].decode_u32(17) == 1)
	_check("END is a frame and does not complete before transcript", request.end_stream() == OK and client.sent_packets.back()[0] == 3 and request.result.is_empty())
	client._handle_message({"cmd": "response", "topic": "voice/stt/stream", "params": {"request_id": request.request_id, "result": {"text": "heard", "msg_id": request.stream_id.hex_encode()}}})
	var outcome: Dictionary = await request.receive_result()
	_check("matching response completes after END", outcome.success and outcome.json.params.result.text == "heard")

func _failure_and_cancel_contracts(client: Node) -> void:
	client.sent.clear()
	var request = _request(client, "mic-cancel")
	request.open(_service(), {"language": "en"})
	request.append_audio(PackedByteArray([1, 0]))
	var packets_before_cancel: int = client.sent_packets.size()
	request.cancel()
	var cancelled: Dictionary = await request.receive_result()
	_check("local cancel is immediate and sends one stream/cancel without END", cancelled.error_code == "cancelled" and client.sent_packets.size() == packets_before_cancel and client.sent.size() == 1 and client.sent[0].topic == "stream/cancel" and client.sent[0].params.data.stream_id == request.stream_id.hex_encode())

	request = _request(client, "mic-remote-cancel")
	request.open(_service(), {"language": "en"})
	client._handle_message({"cmd": "notify", "topic": "stream/cancel", "params": {"request_id": request.request_id, "data": {"event": "stream/cancel", "stream_id": request.stream_id.hex_encode(), "reason": "rejected"}}})
	var remote: Dictionary = await request.receive_result()
	_check("correlated Core cancel stops producer promptly", remote.error_code == "stream_cancelled")

	request = _request(client, "mic-unrelated")
	request.open(_service(), {"language": "en"})
	client._handle_message({"cmd": "notify", "topic": "stream/cancel", "params": {"request_id": "other", "data": {"event": "stream/cancel", "stream_id": request.stream_id.hex_encode()}}})
	_check("unrelated cancel is ignored", request.result.is_empty())
	request.cancel()

	request = _request(client, "mic-limit")
	request.open(_service(), {"language": "en"})
	request.audio_bytes = request.MAX_AUDIO_BYTES
	var packets_before_cap: int = client.sent_packets.size()
	_check("cap fails before enqueue and cancels producer", request.append_audio(PackedByteArray([1, 0])) == ERR_OUT_OF_MEMORY and request.result.error_code == "audio_too_large" and client.sent_packets.size() == packets_before_cap)

	request = _request(client, "mic-disconnect")
	request.open(_service(), {"language": "en"})
	client._connection_epoch += 1
	_check("connection epoch prevents stale DATA", request.append_audio(PackedByteArray([1, 0])) == ERR_CONNECTION_ERROR and request.result.error_code == "core_disconnected")

func _enqueue_and_inline_failures(client: Node) -> void:
	client.behavior = "failure"
	var request = _request(client, "mic-open-fail")
	var cancels_before_open: int = client.sent.size()
	_check("OPEN enqueue failure cleans pending owner without producer cancel", request.open(_service(), {}) == ERR_CONNECTION_ERROR and request.result.error_code == "send_failed" and not client._pending_requests.has(request.request_id) and client.sent.size() == cancels_before_open)
	client.behavior = "hold"

	request = _request(client, "mic-inline-cancel")
	client.on_packet = func(packet: PackedByteArray):
		if packet[0] == 0:
			request.cancel()
	client.sent.clear()
	_check("inline local cancellation after OPEN enqueue addresses producer once", request.open(_service(), {}) != OK and client.sent.size() == 1 and client.sent[0].params.data.stream_id == request.stream_id.hex_encode())
	client.on_packet = Callable()

	request = _request(client, "mic-data-fail")
	request.open(_service(), {})
	client.behavior = "failure"
	var packets_before_data: int = client.sent_packets.size()
	var cancels_before_data: int = client.sent.size()
	_check("DATA enqueue failure terminates and cancels without later END", request.append_audio(PackedByteArray([1, 0])) == ERR_CONNECTION_ERROR and request.result.error_code == "send_failed" and client.sent_packets.size() == packets_before_data + 1 and request.end_stream() == ERR_UNCONFIGURED and client.sent.size() == cancels_before_data + 1 and client.sent.back().params.request_id == request.request_id and client.sent.back().params.target_service_id == "voice-service" and client.sent.back().params.data.stream_id == request.stream_id.hex_encode())
	client.behavior = "hold"

	request = _request(client, "mic-end-fail")
	request.open(_service(), {})
	request.append_audio(PackedByteArray([1, 0]))
	client.behavior = "failure"
	var cancels_before_end: int = client.sent.size()
	_check("END enqueue failure cancels the still-open producer", request.end_stream() == ERR_CONNECTION_ERROR and request.result.error_code == "send_failed" and client.sent.size() == cancels_before_end + 1 and client.sent.back().topic == "stream/cancel" and client.sent.back().params.request_id == request.request_id and client.sent.back().params.target_service_id == "voice-service" and client.sent.back().params.data.stream_id == request.stream_id.hex_encode())
	client.behavior = "hold"

	request = _request(client, "mic-request-error")
	request.open(_service(), {})
	client._handle_message({"cmd": "error", "topic": "voice/stt/stream", "params": {"request_id": request.request_id, "error_code": "REJECTED", "error": "rejected"}})
	_check("request-ID-only error terminates capture before END", request.result.error_code == "REJECTED")

	request = _request(client, "mic-conflict")
	request.open(_service(), {})
	client._handle_message({"cmd": "error", "topic": "voice/stt/stream", "params": {"request_id": request.request_id, "msg_id": "wrong", "error_code": "WRONG"}})
	_check("conflicting supplied stream ID is ignored", request.result.is_empty())
	request.cancel()

func _decode_open(packet: PackedByteArray) -> Dictionary:
	var size := packet.decode_u32(17)
	return JSON.parse_string(packet.slice(25, 25 + size).get_string_from_utf8())
