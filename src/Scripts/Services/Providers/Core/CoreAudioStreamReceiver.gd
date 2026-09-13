extends RefCounted
## Strict reading half of Core audio-stream v1.1. Audio stays owned by the
## request; this receiver only validates framing, order, limits and cancellation.

const MAX_STREAM_BYTES := 20 * 1024 * 1024
const IDLE_SECONDS := 60.0
const RECENTLY_CLOSED_LIMIT := 256
const FORMATS := ["pcm_s16le", "wav"]
const META_KEYS := ["conversation_id", "turn_id", "stream_id", "format", "sample_rate", "direction"]

var client: Node
var _recently_closed: Array[String] = []

func _init(client_: Node) -> void:
	client = client_

func begin(header_id: String, envelope: Dictionary, count: int) -> void:
	var framing_hint: Variant = envelope.get("binary_framing", {})
	var meta_hint: Variant = framing_hint.get("stream", {}) if framing_hint is Dictionary else {}
	var declared_hint: String = str(meta_hint.get("stream_id", "")) if meta_hint is Dictionary else ""
	if header_id in _recently_closed or declared_hint in _recently_closed:
		return
	var params: Variant = envelope.get("params", {})
	var framing: Variant = envelope.get("binary_framing", {})
	if not params is Dictionary or not framing is Dictionary:
		return
	var request_id: String = str(params.get("request_id", ""))
	var owner: RefCounted = client._pending_requests.get(request_id)
	if owner == null or not owner.has_method("accept_stream_open"):
		_remember_closed(header_id)
		return
	var error := _validate_open(envelope, count)
	if error.is_empty() and str(params.get("service_id", "")).is_empty():
		error = "Audio stream producer service is missing."
	if not error.is_empty():
		if not declared_hint.is_empty() and not str(params.get("service_id", "")).is_empty() and not _identity_owned(header_id) and not _identity_owned(declared_hint):
			_send_cancel(request_id, str(params.service_id), declared_hint, "contract_violation")
		owner.fail("invalid_audio_stream", error)
		_remember_closed(header_id)
		return
	var meta: Dictionary = framing.stream
	var declared_id: String = meta.stream_id
	if client._voice_streams.has(header_id) or client._voice_streams.has(declared_id) or header_id == client._binary_stream_id or declared_id == client._binary_stream_id:
		owner.fail("invalid_audio_stream", "Audio stream identity belongs to another binary transfer.")
		return
	if client._audio_streams.has(header_id) or client._audio_stream_ids.has(header_id) or client._audio_stream_ids.has(declared_id):
		owner.fail("invalid_audio_stream", "Audio stream ID opened twice.")
		return
	if declared_id in client._audio_streams:
		owner.fail("invalid_audio_stream", "Declared audio stream ID collides with an active header ID.")
		return
	for active: Dictionary in client._audio_streams.values():
		if active.request_id == request_id:
			_send_cancel(request_id, str(params.service_id), declared_id, "duplicate_open")
			owner.fail("invalid_audio_stream", "Core request opened more than one audio stream.")
			return
	var state := {
		"request_id": request_id,
		"declared_id": declared_id,
		"producer_service_id": str(params.get("service_id", "")),
		"expected_seq": 0,
		"bytes_received": 0,
		"timer": _make_idle_timer(header_id),
	}
	client._audio_streams[header_id] = state
	client._audio_stream_ids[declared_id] = header_id
	if not owner.accept_stream_open(header_id, meta, state.producer_service_id):
		_cancel(header_id, "cancelled")
	elif not client._pending_requests.has(request_id) or not client._audio_streams.has(header_id):
		_cancel(header_id, "consumer_rejected")

func receive_frame(frame_type: int, header_id: String, payload: PackedByteArray) -> void:
	var state: Dictionary = client._audio_streams.get(header_id, {})
	if state.is_empty():
		return
	var owner: RefCounted = client._pending_requests.get(state.request_id)
	if owner == null or not owner.has_method("accept_stream_chunk"):
		_close(header_id)
		return
	_reset_idle(state.timer)
	match frame_type:
		2:
			if payload.size() < 4:
				_fail(header_id, owner, "Stream chunk has no sequence number.")
				return
			var sequence := payload.decode_u32(0)
			if sequence != state.expected_seq:
				_fail(header_id, owner, "Audio stream chunk is out of sequence.")
				return
			var audio := payload.slice(4)
			if state.bytes_received + audio.size() > MAX_STREAM_BYTES:
				_fail(header_id, owner, "Audio stream exceeds its byte limit.", "too_large")
				return
			state.expected_seq += 1
			state.bytes_received += audio.size()
			if not owner.accept_stream_chunk(header_id, audio):
				_cancel(header_id, "consumer_rejected")
			elif not client._pending_requests.has(state.request_id):
				_cancel(header_id, "consumer_rejected")
		3:
			if not payload.is_empty():
				_fail(header_id, owner, "Audio stream END payload must be empty.")
				return
			_close(header_id)
			owner.accept_stream_end(header_id)
		_:
			_fail(header_id, owner, "Unsupported audio stream frame type.")

func cancel(header_id: String, reason: String) -> void:
	_cancel(header_id, reason)

func _validate_open(envelope: Dictionary, count: int) -> String:
	if count != 1:
		return "Audio stream OPEN must declare one body."
	var framing: Dictionary = envelope.binary_framing
	if framing.get("data") != "raw" or framing.get("completion") != "stream_end":
		return "Unsupported audio stream framing."
	var meta: Variant = framing.get("stream")
	if not meta is Dictionary or meta.keys().size() != META_KEYS.size():
		return "Audio stream metadata has the wrong shape."
	for key: String in META_KEYS:
		if not meta.has(key):
			return "Audio stream metadata is incomplete."
	for key: String in ["conversation_id", "turn_id", "stream_id"]:
		if not meta.get(key) is String or meta[key].is_empty():
			return "Audio stream identity is invalid."
	if meta.get("format") not in FORMATS or meta.get("direction") != "out":
		return "Audio stream layout is unsupported."
	var rate: Variant = meta.get("sample_rate")
	if not rate is float and not rate is int:
		return "Audio stream sample rate is invalid."
	var rate_float := float(rate)
	if not is_finite(rate_float) or rate_float != floor(rate_float) or rate_float < 8000.0 or rate_float > 384000.0:
		return "Audio stream sample rate is invalid."
	meta["sample_rate"] = int(rate_float)
	return ""

func _fail(header_id: String, owner: RefCounted, message: String, reason := "contract_violation") -> void:
	_cancel(header_id, reason)
	owner.fail("invalid_audio_stream", message)

func _cancel(header_id: String, reason: String) -> void:
	var state: Dictionary = client._audio_streams.get(header_id, {})
	if state.is_empty():
		return
	_send_cancel(state.request_id, state.producer_service_id, state.declared_id, reason)
	_close(header_id)

func _send_cancel(request_id: String, service_id: String, declared_id: String, reason: String) -> void:
	var message := {
		"cmd": "request", "topic": "stream/cancel", "entity_type": "client",
		"params": {"client_id": client.client_id, "request_id": request_id,
			"target_service_id": service_id,
			"data": {"stream_id": declared_id, "reason": reason}}
	}
	client.send_text_message_to_core(message)

func _make_idle_timer(header_id: String) -> Timer:
	var timer := Timer.new()
	timer.one_shot = true
	timer.timeout.connect(func():
		var state: Dictionary = client._audio_streams.get(header_id, {})
		if state.is_empty(): return
		var owner: RefCounted = client._pending_requests.get(state.request_id)
		_cancel(header_id, "idle")
		if owner != null: owner.fail("stream_idle", "Audio stream stopped producing data."))
	client.add_child(timer)
	timer.start(IDLE_SECONDS)
	return timer

func _reset_idle(timer: Timer) -> void:
	if is_instance_valid(timer):
		timer.start(IDLE_SECONDS)

func _close(header_id: String) -> void:
	var state: Dictionary = client._audio_streams.get(header_id, {})
	if state.has("timer") and is_instance_valid(state.timer):
		state.timer.stop()
		state.timer.queue_free()
	client._audio_streams.erase(header_id)
	if state.has("declared_id") and client._audio_stream_ids.get(state.declared_id) == header_id:
		client._audio_stream_ids.erase(state.declared_id)
	_remember_closed(header_id)
	if state.has("declared_id") and state.declared_id != header_id:
		_remember_closed(state.declared_id)

func close_all() -> void:
	for header_id: String in client._audio_streams.keys():
		_close(header_id)

func _remember_closed(header_id: String) -> void:
	_recently_closed.append(header_id)
	if _recently_closed.size() > RECENTLY_CLOSED_LIMIT:
		_recently_closed.pop_front()

func _identity_owned(stream_id: String) -> bool:
	return client._audio_streams.has(stream_id) or client._audio_stream_ids.has(stream_id) \
		or client._voice_streams.has(stream_id) or stream_id == client._binary_stream_id
