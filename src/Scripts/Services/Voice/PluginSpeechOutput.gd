class_name PluginSpeechOutput
extends SpeechOutput
## Bounded host-to-plugin PCM transport. The endpoint owns resampling/pacing.
## Completion is acknowledged by the endpoint after its speaker drains.

const CHUNK_BYTES: int = 6400
const PENDING_BYTES: int = 2 * 1024 * 1024
const TOTAL_BYTES: int = 20 * 1024 * 1024

var _ready: Callable
var _waiting: bool = false
var _origin: Dictionary
var _send: Callable
var _next_frame: Callable
var _available: Callable
var _stream_id: int
var _queue: Array[PackedByteArray] = []
var _pending: int = 0
var _total: int = 0
var _sequence: int = 0
var _opened: bool = false
var _stopped: bool = false
var _ended: bool = false
var _eos_sent: bool = false
var _wav: PackedByteArray = PackedByteArray()
var _format: String = ""
var _volume: float = 1.0
var _source: PackedByteArray = PackedByteArray()
var _source_offset: int = 0
var _partial_sample: PackedByteArray = PackedByteArray()


func _init(stream_id: int, send: Callable, next_frame: Callable, available: Callable, origin: Dictionary = {}, ready: Callable = Callable()) -> void:
	_ready = ready
	_stream_id = stream_id
	_origin = origin.duplicate(true)
	_send = send
	_next_frame = next_frame
	_available = available


func is_available() -> bool:
	var available: bool = _available.call()
	return not _stopped and available


func play(audio: PackedByteArray, volume: float) -> Dictionary:
	var decoded: AudioStream = VoiceServiceClient.decode_audio(audio)
	if not decoded is AudioStreamWAV:
		return VoiceServiceClient.failure("unsupported_audio_stream", "Plugin output requires PCM WAV audio.")
	var wav: AudioStreamWAV = decoded
	if wav.stereo or wav.format != AudioStreamWAV.FORMAT_16_BITS:
		return VoiceServiceClient.failure("unsupported_audio_stream", "Plugin output requires mono 16-bit PCM.")
	var opened: Dictionary = begin("pcm_s16le", wav.mix_rate, volume)
	if not opened.success:
		return opened
	if wav.data.size() > TOTAL_BYTES or wav.data.size() % 2 != 0:
		_fail("audio_overflow", "Plugin speech exceeds the total PCM limit.")
		return VoiceServiceClient.failure("audio_overflow", "Plugin speech exceeds the total PCM limit.")
	_source = wav.data
	_total = _source.size()
	end()
	return {"success": true}


func begin(format: String, sample_rate: int, volume: float) -> Dictionary:
	if not is_available():
		return VoiceServiceClient.failure("audio_unavailable", "Selected plugin speaker is unreachable.")
	if _opened or _waiting or format not in ["pcm_s16le", "wav"] or sample_rate <= 0:
		return VoiceServiceClient.failure("unsupported_audio_stream", "Plugin output requires PCM or WAV with a sample rate.")
	_format = format
	_volume = volume
	if format == "wav":
		return {"success": true}
	if _ready.is_valid() and not _ready.call():
		_waiting = true
		_begin_after_tone(format, sample_rate, volume)
		return {"success": true}
	if not _emit({"op": "begin", "format": format, "sample_rate": sample_rate, "channels": 1, "volume": volume}):
		return VoiceServiceClient.failure("audio_unavailable", "Plugin speaker refused the stream.")
	_opened = true
	_pump()
	return {"success": true}


func _begin_after_tone(format: String, sample_rate: int, volume: float) -> void:
	while not _stopped and not _ready.call():
		await _next_frame.call()
	_waiting = false
	if not _stopped:
		var result: Dictionary = begin(format, sample_rate, volume)
		if not result.success:
			_fail(str(result.error_code), str(result.error_message))


func append(audio: PackedByteArray) -> bool:
	if _stopped or _ended or audio.is_empty():
		return false
	if _total + audio.size() > TOTAL_BYTES:
		_fail("audio_overflow", "Plugin speech exceeds the total audio limit.")
		return false
	_total += audio.size()
	if _format == "wav":
		_wav.append_array(audio)
		return true
	var aligned: PackedByteArray = _partial_sample + audio
	_partial_sample = PackedByteArray()
	if aligned.size() % 2 != 0:
		_partial_sample = aligned.slice(aligned.size() - 1)
		aligned = aligned.slice(0, aligned.size() - 1)
	if _pending + aligned.size() + _partial_sample.size() > PENDING_BYTES:
		push_warning("[PluginSpeechOutput] Dropped overflowing PCM; terminating stream.")
		_fail("audio_overflow", "Plugin speaker cannot keep up with speech.")
		return false
	for offset in range(0, aligned.size(), CHUNK_BYTES):
		var chunk: PackedByteArray = aligned.slice(offset, mini(offset + CHUNK_BYTES, aligned.size()))
		_queue.append(chunk)
		_pending += chunk.size()
	return true


func end() -> void:
	if _stopped or _ended:
		return
	if _format == "wav":
		var audio: PackedByteArray = _wav
		_wav = PackedByteArray()
		_format = ""
		_total = 0
		var result: Dictionary = play(audio, _volume)
		if not result.success:
			_fail(str(result.error_code), str(result.error_message))
		return
	if not _partial_sample.is_empty():
		_fail("invalid_audio_stream", "Speech ended with an incomplete PCM sample.")
		return
	_ended = true


func stop() -> void:
	if _stopped:
		return
	_discard()
	if _opened:
		_emit({"op": "cancel"})
	# The operation disconnects its own completion before stopping output.
	# The endpoint registry still needs a terminal release with identity guard.
	_report_finished(VoiceServiceClient.failure("cancelled", "Speech stopped."))


func _discard() -> void:
	_stopped = true
	_queue.clear()
	_pending = 0
	_wav = PackedByteArray()
	_source = PackedByteArray()
	_partial_sample = PackedByteArray()


func acknowledge(success: bool, message: String = "") -> void:
	if _stopped:
		return
	if success and not _eos_sent:
		_fail("audio_protocol", "Plugin acknowledged speech before EOS.")
		return
	if success:
		_discard()
		_report_finished({"success": true})
	else:
		_fail("audio_delivery_failed", message)


func _emit(payload: Dictionary) -> bool:
	if payload.get("op") == "begin" and not _origin.is_empty():
		payload["origin"] = _origin
	payload["stream_id"] = _stream_id
	var sent: bool = _send.call(payload)
	return sent


func _fail(code: String, message: String) -> void:
	_emit({"op": "error", "error_code": code, "error_message": message})
	_discard()
	_report_finished(VoiceServiceClient.failure(code, message))


func _pump() -> void:
	# Native STDIO writer admission is already bounded and nonblocking. Bound
	# our producer queue as well, and yield between small groups of chunks.
	while not _stopped:
		await _next_frame.call()
		if _stopped:
			return
		if not is_available():
			_fail("audio_unavailable", "Plugin speaker disconnected during speech.")
			return
		for frame in range(4):
			if _source_offset < _source.size() and _pending + CHUNK_BYTES <= PENDING_BYTES:
				var loaded: PackedByteArray = _source.slice(_source_offset, mini(_source_offset + CHUNK_BYTES, _source.size()))
				_source_offset += loaded.size()
				_queue.append(loaded)
				_pending += loaded.size()

			if _queue.is_empty():
				break
			var chunk: PackedByteArray = _queue.pop_front()
			_pending -= chunk.size()
			if not _emit({"op": "chunk", "sequence": _sequence, "pcm": Marshalls.raw_to_base64(chunk)}):
				_fail("audio_delivery_failed", "Plugin audio writer could not accept PCM.")
				return
			_sequence += 1
			if _sequence == 1:
				_report_started()
		if _ended and _queue.is_empty() and _source_offset >= _source.size():
			if not _emit({"op": "end", "sequence": _sequence}):
				_fail("audio_delivery_failed", "Plugin audio writer could not accept EOS.")
				return
			_eos_sent = true
			var deadline: int = Time.get_ticks_msec() + 300000
			while not _stopped and Time.get_ticks_msec() < deadline:
				await _next_frame.call()
				if not _stopped and not is_available():
					_fail("audio_unavailable", "Plugin speaker disconnected before completion.")
			if not _stopped:
				_fail("audio_timeout", "Plugin speaker did not acknowledge completion.")
			return
