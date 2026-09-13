extends SceneTree
## Focused v1.1 transport scenarios using the real Core binary dispatcher.

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	var client = load("res://test/fixtures/core_lifecycle_client.gd").new()
	root.add_child(client)
	await process_frame
	await _valid_stream(client)
	await _contract_failures(client)
	await _cancel_before_open(client)
	await _cancel_across_disconnect(client)
	print("=== Core audio stream: %d passed, %d failed ===" % [passed, failed])
	client.free()
	quit(1 if failed else 0)

func _check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _valid_stream(client: Node) -> void:
	var request = load("res://Scripts/Services/Providers/Core/CoreAudioStreamRequest.gd").new(client)
	request.request_id = "stream-valid"
	request.timeout = 5.0
	var chunks: Array[PackedByteArray] = []
	request.stream_chunk.connect(func(bytes: PackedByteArray): chunks.append(bytes))
	request.start()
	client._binary_stream_id = "ordinary-artifact"
	var header_id := _id_bytes(41)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000.0))
	client._handle_binary_frame(_legacy_open(header_id, request.request_id))
	_check("legacy OPEN cannot claim an active stream header", client._audio_streams.has(header_id.hex_encode()) and not client._voice_streams.has(header_id.hex_encode()))
	client._handle_binary_frame(_data(header_id, 0, PackedByteArray([1, 2, 3])))
	client._handle_binary_frame(_data(header_id, 1, PackedByteArray([4, 5])))
	client._handle_binary_frame(PackedByteArray([3]) + header_id)
	var outcome: Dictionary = await request.receive_result()
	_check("integral JSON float rate and sequenced chunks complete", outcome.success and chunks.size() == 2 and chunks[0] == PackedByteArray([1, 2, 3]))
	_check("END releases stream transport state", client._audio_streams.is_empty())
	_check("stream transport does not disturb ordinary artifact identity", client._binary_stream_id == "ordinary-artifact")
	client._binary_stream_id = ""

func _cancel_before_open(client: Node) -> void:
	var request = load("res://Scripts/Services/Providers/Core/CoreAudioStreamRequest.gd").new(client)
	request.request_id = "stream-cancelled"
	request.timeout = 5.0
	var observed := {"chunks": 0}
	request.stream_chunk.connect(func(_bytes: PackedByteArray): observed.chunks += 1)
	request.start()
	request.cancel()
	var header_id := _id_bytes(73)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_binary_frame(_data(header_id, 0, PackedByteArray([8, 9])))
	var outcome: Dictionary = await request.receive_result()
	var cancel: Dictionary = client.sent.back()
	_check("pre-OPEN cancellation remains correlated and sends one producer cancel", not outcome.success and outcome.error_code == "cancelled" and cancel.topic == "stream/cancel" and cancel.params.request_id == request.request_id and cancel.params.target_service_id == "voice-service" and cancel.params.data.stream_id == header_id.hex_encode())
	_check("cancelled stream discards late audio and closes state", observed.chunks == 0 and client._audio_streams.is_empty())

func _contract_failures(client: Node) -> void:
	var request = _request(client, "stream-sequence")
	var header_id := _id_bytes(51)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_binary_frame(_data(header_id, 1, PackedByteArray([1, 2])))
	var outcome: Dictionary = await request.receive_result()
	_check("sequence gap fails and cancels producer", outcome.error_code == "invalid_audio_stream" and client.sent.back().topic == "stream/cancel")

	request = _request(client, "stream-meta")
	header_id = _id_bytes(52)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000.5))
	outcome = await request.receive_result()
	_check("fractional JSON sample rate is rejected", outcome.error_code == "invalid_audio_stream")

	request = _request(client, "stream-duplicate")
	header_id = _id_bytes(53)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	var sends_before_duplicate: int = client.sent.size()
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	outcome = await request.receive_result()
	_check("same-owner duplicate cancels its owned stream exactly once", outcome.error_code == "invalid_audio_stream" and client.sent.size() == sends_before_duplicate + 1 and client.sent.back().params.data.stream_id == header_id.hex_encode() and client._audio_streams.is_empty() and client._audio_stream_ids.is_empty())

	var first = _request(client, "stream-map-first")
	var second = _request(client, "stream-map-second")
	var shared_declared := "shared-declared-id"
	client._handle_binary_frame(_open(_id_bytes(61), first.request_id, 24000, shared_declared))
	var sends_before_collision: int = client.sent.size()
	client._handle_binary_frame(_open(_id_bytes(62), second.request_id, 24000.5, shared_declared))
	var second_outcome: Dictionary = await second.receive_result()
	_check("malformed newcomer cannot cancel incumbent through an ambiguous declared ID", second_outcome.error_code == "invalid_audio_stream" and client.sent.size() == sends_before_collision and client._audio_stream_ids.get(shared_declared) == _id_bytes(61).hex_encode())
	first.cancel()

	request = _request(client, "stream-request-duplicate")
	var original_id := _id_bytes(63)
	var incoming_id := _id_bytes(64)
	client._handle_binary_frame(_open(original_id, request.request_id, 24000))
	var sends_before_distinct: int = client.sent.size()
	client._handle_binary_frame(_open(incoming_id, request.request_id, 24000))
	outcome = await request.receive_result()
	var cancel_targets := []
	if client.sent.size() >= sends_before_distinct + 2:
		cancel_targets = [client.sent[sends_before_distinct].params.data.stream_id, client.sent[sends_before_distinct + 1].params.data.stream_id]
	_check("one request with distinct IDs cancels incoming and original once each", outcome.error_code == "invalid_audio_stream" and client.sent.size() == sends_before_distinct + 2 and original_id.hex_encode() in cancel_targets and incoming_id.hex_encode() in cancel_targets)

	request = _request(client, "stream-cross-map")
	header_id = _id_bytes(65)
	client._voice_streams[header_id.hex_encode()] = {"request_id": "legacy"}
	var sends_before_cross_map: int = client.sent.size()
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	outcome = await request.receive_result()
	_check("stream OPEN cannot claim or cancel a legacy voice identity", outcome.error_code == "invalid_audio_stream" and client.sent.size() == sends_before_cross_map and not client._audio_streams.has(header_id.hex_encode()))
	client._voice_streams.erase(header_id.hex_encode())

	request = _request(client, "stream-open-callback-cancel")
	request.stream_opened.connect(func(_meta: Dictionary): request.cancel())
	header_id = _id_bytes(66)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	outcome = await request.receive_result()
	_check("synchronous OPEN callback cancellation closes stream once", outcome.error_code == "cancelled" and not client._audio_streams.has(header_id.hex_encode()))

	request = _request(client, "stream-chunk-callback-cancel")
	request.stream_chunk.connect(func(_audio: PackedByteArray): request.cancel())
	header_id = _id_bytes(67)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_binary_frame(_data(header_id, 0, PackedByteArray([1, 2])))
	outcome = await request.receive_result()
	_check("synchronous chunk callback cancellation prevents retained state", outcome.error_code == "cancelled" and not client._audio_streams.has(header_id.hex_encode()))

	request = _request(client, "stream-json")
	header_id = _id_bytes(54)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client.reply(request.request_id, {"complete": true})
	_check("JSON success before END is informational", request.result.is_empty() and client._audio_streams.has(header_id.hex_encode()))
	client._handle_binary_frame(_data(header_id, 0, PackedByteArray([1, 2])))
	client._handle_binary_frame(PackedByteArray([3]) + header_id)
	outcome = await request.receive_result()
	_check("END alone completes streaming request", outcome.success)

	request = _request(client, "stream-error-id")
	header_id = _id_bytes(56)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_message({"cmd": "error", "topic": "voice/tts/stream", "params": {"request_id": request.request_id, "msg_id": "wrong", "error_code": "STREAM_CANCELLED"}})
	_check("stream error with wrong header ID is ignored", request.result.is_empty())
	client._handle_message({"cmd": "error", "topic": "voice/tts/stream", "params": {"request_id": request.request_id, "msg_id": header_id.hex_encode(), "error_code": "STREAM_CANCELLED"}})
	outcome = await request.receive_result()
	_check("matching stream error is terminal", outcome.error_code == "STREAM_CANCELLED")

	request = _request(client, "stream-error-request")
	header_id = _id_bytes(57)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_message({"cmd": "error", "topic": "voice/tts/stream", "params": {"request_id": request.request_id, "error_code": "REQUEST_ERROR"}})
	outcome = await request.receive_result()
	_check("request-ID-only stream error remains terminal after OPEN", outcome.error_code == "REQUEST_ERROR")

	request = _request(client, "stream-error-header")
	header_id = _id_bytes(58)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	client._handle_message({"cmd": "error", "topic": "voice/tts/stream", "params": {"msg_id": header_id.hex_encode(), "error_code": "HEADER_ERROR"}})
	outcome = await request.receive_result()
	_check("header-ID-only stream error is correlated", outcome.error_code == "HEADER_ERROR")

	request = _request(client, "stream-cap")
	header_id = _id_bytes(55)
	client._handle_binary_frame(_open(header_id, request.request_id, 24000))
	var state: Dictionary = client._audio_streams[header_id.hex_encode()]
	state.bytes_received = 20 * 1024 * 1024
	client._handle_binary_frame(_data(header_id, 0, PackedByteArray([1, 2])))
	outcome = await request.receive_result()
	_check("total cap is checked before accepting chunk", outcome.error_code == "invalid_audio_stream" and client._audio_streams.is_empty())

func _cancel_across_disconnect(client: Node) -> void:
	var expiring = _request(client, "stream-expiry")
	expiring.cancel()
	expiring._on_timeout()
	var expired: Dictionary = await expiring.receive_result()
	_check("cancel-before-OPEN tombstone expires at bounded overall deadline", expired.error_code == "timeout" and not client._stream_cancel_tombstones.has(expiring.request_id))

	var request = _request(client, "stream-old-connection")
	request.cancel()
	client._drop_connection_state()
	var outcome: Dictionary = await request.receive_result()
	var sends_before: int = client.sent.size()
	client._connection_epoch += 1
	client._handle_binary_frame(_open(_id_bytes(81), request.request_id, 24000))
	_check("disconnect clears pre-OPEN tombstone and late OPEN cannot resurrect", outcome.error_code == "core_disconnected" and client.sent.size() == sends_before and client._stream_cancel_tombstones.is_empty())
	client._connected = true

func _request(client: Node, request_id: String):
	var request = load("res://Scripts/Services/Providers/Core/CoreAudioStreamRequest.gd").new(client)
	request.request_id = request_id
	request.timeout = 5.0
	request.start()
	return request

func _open(header_id: PackedByteArray, request_id: String, sample_rate: Variant, declared_id := "") -> PackedByteArray:
	var stream_id := str(declared_id) if not str(declared_id).is_empty() else header_id.hex_encode()
	var envelope := {"cmd": "response", "topic": "voice/tts/stream", "entity_type": "service",
		"params": {"request_id": request_id, "client_id": "minerva", "service_id": "voice-service"},
		"binary_framing": {"data": "raw", "completion": "stream_end", "mode": "stream",
			"stream": {"conversation_id": request_id, "turn_id": request_id, "stream_id": stream_id,
				"format": "pcm_s16le", "sample_rate": sample_rate, "direction": "out"}}}
	var json := JSON.stringify(envelope).to_utf8_buffer()
	var sizes := PackedByteArray()
	sizes.resize(8)
	sizes.encode_u32(0, json.size())
	sizes.encode_u32(4, 1)
	return PackedByteArray([0]) + header_id + sizes + json

func _data(header_id: PackedByteArray, sequence: int, audio: PackedByteArray) -> PackedByteArray:
	var seq := PackedByteArray()
	seq.resize(4)
	seq.encode_u32(0, sequence)
	return PackedByteArray([2]) + header_id + seq + audio

func _legacy_open(header_id: PackedByteArray, request_id: String) -> PackedByteArray:
	var envelope := {"cmd": "response", "topic": "voice/tts/synthesize", "params": {"request_id": request_id},
		"binary_framing": {"data": "raw", "completion": "stream_end"}}
	var json := JSON.stringify(envelope).to_utf8_buffer()
	var sizes := PackedByteArray()
	sizes.resize(8)
	sizes.encode_u32(0, json.size())
	sizes.encode_u32(4, 1)
	return PackedByteArray([0]) + header_id + sizes + json

func _id_bytes(seed: int) -> PackedByteArray:
	var value := PackedByteArray()
	value.resize(16)
	value.encode_u32(0, seed)
	return value
