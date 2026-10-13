class_name PluginAudioInput
extends RefCounted
## One external PTT session; the normal voice client owns transcription.

const CoreRequestBase = preload("res://Scripts/Services/Providers/Core/CoreRequest.gd")
const AudioConverter = preload("res://Scripts/Services/Voice/AudioInputConverter.gd")

const MAX_CHUNK_BYTES: int = 6400
const MAX_AUDIO_BYTES: int = 16000 * 2 * 300
const MAX_CAPTURE_MS: int = 300000

class Session extends RefCounted:
	var id: int
	var plugin_id: String
	var device_id: String
	var key: String
	var chat_id: String
	var sequence: int = 0
	var bytes: int = 0
	var started_ms: int
	var finishing: bool = false
	var pcm: PackedByteArray = PackedByteArray()
	var stream: Dictionary = {}
	var operation: VoiceOperation = VoiceOperation.new()
	var config: VoiceConfig
	var client: VoiceServiceClient

var _devices: PluginAudioDevices
var _target: PluginHostChatTarget
var _config: VoiceConfig
var _voice: Callable
var _send: Callable
var _notify: Callable
var _next_frame: Callable
var _admit: Callable
var _active: Session
var _next_id: int = 0


func _init(devices: PluginAudioDevices, target: PluginHostChatTarget, config: VoiceConfig,
		voice: Callable, send: Callable, notify: Callable, next_frame: Callable, admit: Callable) -> void:
	_devices = devices
	_target = target
	_config = config
	_voice = voice
	_send = send
	_notify = notify
	_next_frame = next_frame
	_admit = admit
	_devices.changed.connect(_devices_changed)


func handle(plugin_id: String, args: Dictionary) -> Dictionary:
	var device_id: String = str(args.get("device_id", ""))
	var key: String = "plugin:%s:%s" % [plugin_id, device_id]
	var op: String = str(args.get("op", ""))
	if op == "input_begin":
		return _begin(plugin_id, device_id, key, args)
	var session: Session = _active
	if session == null or session.plugin_id != plugin_id or session.key != key or _integer(args.get("session_id")) != session.id:
		return _error(plugin_id, "invalid_audio_session", "No matching microphone session.")
	if op == "input_cancel":
		return _complete(session, VoiceServiceClient.failure("cancelled", "Microphone session cancelled."))
	if session.finishing:
		return _error(plugin_id, "audio_session_finished", "Microphone input has already ended.")
	if _integer(args.get("sequence")) != session.sequence:
		return _complete(session, VoiceServiceClient.failure("invalid_audio_sequence", "Microphone sequence is out of order."))
	if op == "input_chunk":
		return _chunk(session, args)
	if op == "input_end":
		return await _end(session)
	return _error(plugin_id, "invalid_audio_operation", "Unknown microphone operation.")


func _begin(plugin_id: String, device_id: String, key: String, args: Dictionary) -> Dictionary:
	if not _admit.call(plugin_id):
		return _error(plugin_id, "transcript_not_granted", "The plugin must declare and receive voice.transcript.")
	if _active != null:
		return _error(plugin_id, "audio_session_busy", "A microphone session is already active.")
	if args.get("format") != "pcm_s16le" or args.get("sample_rate") != 16000 or args.get("channels") != 1:
		return _error(plugin_id, "invalid_audio_format", "Microphone input requires mono 16 kHz s16le PCM.")
	if not args.get("expected_chat_id") is String or str(args.expected_chat_id).is_empty():
		return _error(plugin_id, "invalid_chat", "Microphone input requires an expected chat.")
	var expected: String = args.expected_chat_id
	if expected != _target.active_chat_id():
		return _error(plugin_id, "chat_changed", "The visible chat changed before microphone input.")
	if _devices.selected_input() != key or not _devices.endpoint_available(key, "input"):
		return _error(plugin_id, "audio_unavailable", "The selected microphone endpoint is unavailable.")
	var state: Dictionary = _target.set_external_state(plugin_id, "recording")
	if not state.get("success", false):
		return state
	_next_id += 1
	var session := Session.new()
	session.operation.voice_owner = VoiceFeatureControl.MANUAL_PTT_OWNER
	session.id = _next_id
	session.plugin_id = plugin_id
	session.device_id = device_id
	session.key = key
	session.chat_id = expected
	session.started_ms = Time.get_ticks_msec()
	session.client = _voice.call()
	session.config = VoiceConfig.new()
	for setting: String in ["stt_provider", "stt_transport", "stt_backend", "stt_model", "whisper_fallback"]:
		session.config.set(setting, _config.get(setting))
	_active = session
	if session.config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE and session.config.stt_transport == VoiceConfig.STTTransport.STREAMED:
		session.stream = session.client.begin_transcription_stream(session.config, session.operation)
		if not session.stream.get("success", false):
			return _complete(session, session.stream)
		var request: CoreRequestBase = session.stream.request
		request.finished.connect(_stream_terminal.bind(session), CONNECT_ONE_SHOT)
	_watch(session)
	return PluginErrors.success({"session_id": session.id})


func _chunk(session: Session, args: Dictionary) -> Dictionary:
	var value: Variant = args.get("pcm")
	if not value is String:
		return _complete(session, VoiceServiceClient.failure("invalid_audio_chunk", "Microphone chunk must be base64 text."))
	var encoded: String = value
	if encoded.is_empty() or encoded.length() > 8536:
		return _complete(session, VoiceServiceClient.failure("invalid_audio_chunk", "Microphone chunk is missing or too large."))
	var pcm: PackedByteArray = Marshalls.base64_to_raw(encoded)
	if pcm.is_empty() or pcm.size() > MAX_CHUNK_BYTES or pcm.size() % 2 != 0 or Marshalls.raw_to_base64(pcm) != encoded:
		return _complete(session, VoiceServiceClient.failure("invalid_audio_chunk", "Microphone chunk is not sample-aligned bounded PCM."))
	if session.bytes + pcm.size() > MAX_AUDIO_BYTES or Time.get_ticks_msec() - session.started_ms > MAX_CAPTURE_MS:
		return _complete(session, VoiceServiceClient.failure("audio_overflow", "Microphone capture exceeded 300 seconds."))
	if session.stream.is_empty():
		session.pcm.append_array(pcm)
	elif session.client.append_transcription_stream(session.stream, pcm) != OK:
		return _complete(session, VoiceServiceClient.failure("audio_stream_failed", "Microphone stream refused audio."))
	session.bytes += pcm.size()
	session.sequence += 1
	return PluginErrors.success({"session_id": session.id})


func _end(session: Session) -> Dictionary:
	if session.bytes == 0:
		return _complete(session, VoiceServiceClient.failure("empty_audio", "No microphone audio was received."))
	session.finishing = true
	var state: Dictionary = _target.set_external_state(session.plugin_id, "transcribing")
	if not state.get("success", false):
		return _complete(session, state)
	var outcome: Dictionary
	if session.stream.is_empty():
		outcome = await session.client.transcribe_auto_result(AudioConverter.pcm16_to_wav(session.pcm), session.config, session.operation)
	else:
		outcome = await session.client.finish_transcription_stream(session.stream, session.operation)
	if _active != session:
		return _error(session.plugin_id, "cancelled", "Microphone session ended before transcription completed.")
	if not _admit.call(session.plugin_id):
		return _complete(session, VoiceServiceClient.failure("transcript_not_granted", "Transcript permission was revoked."))
	if outcome.get("success", false):
		outcome = _target.append_transcript(session.plugin_id, session.chat_id, str(outcome.get("text", "")))
		if outcome.get("success", false):
			var appended: Dictionary = outcome.get("result", {})
			outcome["text"] = str(appended.get("text", ""))
	return _complete(session, outcome)


func _complete(session: Session, outcome: Dictionary) -> Dictionary:
	if _active != session:
		return _error(session.plugin_id, "cancelled", "Microphone session has ended.")
	_active = null
	session.operation.cancel()
	session.pcm.clear()
	_target.set_external_state(session.plugin_id, "idle")
	var success: bool = outcome.get("success", false)
	var payload: Dictionary = {"device_id": session.device_id, "session_id": session.id,
		"chat_id": session.chat_id, "text": str(outcome.get("text", "")) if success else "",
		"state": "idle" if success else "error"}
	if not success:
		payload["error"] = str(outcome.get("error_message", "Microphone input failed."))
	var sent: Error = _send.call(session.plugin_id, "voice.transcript", payload)
	if success and sent != OK:
		outcome = VoiceServiceClient.failure("transcript_delivery_failed", "The plugin could not receive its transcript.")
	if not outcome.get("success", false):
		if str(outcome.get("error_code", "")) != "cancelled":
			_notify.call("Voice input: " + str(outcome.get("error_message", "Transcription failed.")))
		return outcome
	return PluginErrors.success({"session_id": session.id, "state": "idle"})


func _stream_terminal(outcome: Dictionary, session: Session) -> void:
	if _active == session and not session.finishing:
		_complete(session, session.client.normalize_stream_failure(outcome))


func _devices_changed() -> void:
	if _active != null and (_devices.selected_input() != _active.key or not _devices.endpoint_available(_active.key, "input")):
		_complete(_active, VoiceServiceClient.failure("audio_unavailable", "Microphone endpoint disconnected."))


func _watch(session: Session) -> void:
	while _active == session:
		await _next_frame.call()
		if _active != session:
			return
		if not _admit.call(session.plugin_id):
			_complete(session, VoiceServiceClient.failure("transcript_not_granted", "Transcript permission was revoked."))
		elif session.chat_id != _target.active_chat_id():
			_complete(session, VoiceServiceClient.failure("chat_changed", "The visible chat changed during microphone input."))
		elif session.operation.cancelled:
			_complete(session, VoiceServiceClient.failure("cancelled", "Microphone transcription was cancelled."))
		elif not session.finishing and Time.get_ticks_msec() - session.started_ms > MAX_CAPTURE_MS:
			_complete(session, VoiceServiceClient.failure("audio_overflow", "Microphone capture exceeded 300 seconds."))


static func _integer(value: Variant) -> int:
	if not (value is int or value is float):
		return -1
	var number: float = value
	return int(number) if is_finite(number) and number == floor(number) and number >= 0 and number <= 9007199254740991.0 else -1


static func _error(plugin_id: String, code: String, message: String) -> Dictionary:
	return {"success": false, "plugin_id": plugin_id, "error_code": code, "error_message": message}
