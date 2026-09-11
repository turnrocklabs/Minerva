extends RefCounted
## Known-size voice files admitted only while their request owns completion.

var client: Node

func _init(client_: Node) -> void:
	client = client_


func begin(stream_id: String, header: Dictionary, count: int) -> void:
	var request_id: String = header.get("params", {}).get("request_id", "")
	var owner: RefCounted = client._pending_requests.get(request_id)
	if owner == null or not owner.accepts_binary():
		return
	if client._binary_stream_id == stream_id:
		owner.fail("invalid_binary", "Audio stream ID already belongs to a nonvoice transfer.")
		return
	if client._voice_streams.has(stream_id) and client._voice_streams[stream_id].request_id != request_id:
		owner.fail("invalid_binary", "Audio stream ID already belongs to another request.")
		return
	if count != 1:
		owner.fail("invalid_binary", "Voice response must contain one audio file.")
		return
	if header.has("binary_framing") and header.binary_framing != {"data": "raw", "completion": "stream_end"}:
		owner.fail("invalid_binary", "Unsupported voice binary framing.")
		return
	for existing: Dictionary in client._voice_streams.values():
		if existing.request_id == request_id:
			owner.fail("invalid_binary", "Duplicate audio stream for a Core request.")
			return
	client._voice_streams[stream_id] = {"request_id": request_id, "size": -1, "buffer": PackedByteArray(), "header": header}
	client.binary_new_message_received.emit(header, count)


func receive_frame(frame_type: int, stream_id: String, payload: PackedByteArray) -> void:
	var stream: Dictionary = client._voice_streams[stream_id]
	var owner: RefCounted = client._pending_requests.get(stream.request_id)
	if owner == null or not owner.accepts_binary():
		client._voice_streams.erase(stream_id)
		return
	match frame_type:
		1:
			if stream.size != -1 or payload.size() < 8 or payload.size() != 8 + payload.decode_u32(0):
				owner.fail("invalid_binary", "Malformed or duplicate voice file header.")
				return
			stream.size = payload.decode_u32(4)
		2:
			if stream.size < 0 or stream.buffer.size() + payload.size() > stream.size:
				owner.fail("invalid_binary", "Voice DATA does not match its advertised size.")
				return
			var buffer: PackedByteArray = stream.buffer
			buffer.append_array(payload)
			stream.buffer = buffer
		3:
			if not payload.is_empty() or stream.size < 0 or stream.buffer.size() != stream.size:
				owner.fail("invalid_binary", "Incomplete voice file at STREAM_END.")
				return
			var buffer: PackedByteArray = stream.buffer
			client._voice_streams.erase(stream_id)
			owner.accept_binary(buffer, stream.header)
			client.voice_binary_received.emit(stream.request_id, buffer)
		_:
			owner.fail("invalid_binary", "Unknown voice binary frame type.")
