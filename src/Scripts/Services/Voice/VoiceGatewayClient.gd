class_name VoiceGatewayClient
extends Node
## Owns local voice detection, microphone capture, and hands-free speech state.
## Streams mic audio, receives wake word + VAD events.
## Manages STANDBY/ENGAGED state machine.

signal engagement_changed(state: String)  # "STANDBY" or "ENGAGED"
signal vad_started()
signal vad_ended()
signal wake_word_detected(confidence: float)
signal transcription_ready(audio_wav: PackedByteArray)
signal transcription_stream_started(operation: VoiceOperation)
signal transcription_stream_finished(operation: VoiceOperation, outcome: Dictionary)
signal connected_to_gateway()
signal disconnected_from_gateway()
signal gateway_start_failed(reason: String)

const ENGAGEMENT_IDLE_TIMEOUT := 20.0
const PRE_VAD_BUFFER_MAX_BYTES := 32000  # ~1 second at 16kHz s16le
const CAPTURE_POLL_HZ := 30  # how often we grab mic audio
const TARGET_SAMPLE_RATE := 16000  # Detector input is 16 kHz mono PCM.
const CAPTURE_DIAGNOSTIC_INTERVAL_MSEC := 2000
const MAX_UTTERANCE_BYTES := 16000 * 2 * 300
const AudioConverter = preload("res://Scripts/Services/Voice/AudioInputConverter.gd")
const DetectorAdapter = preload("res://Scripts/Services/Voice/BundledVoiceDetectorAdapter.gd")
const VoiceFeature = preload("res://Scripts/Services/Voice/VoiceFeatureControl.gd")

var engagement_state: String = "STANDBY"

var _detector: Node
var _connected := false

# Mic capture: separate AudioStreamPlayer + AudioEffectCapture (no conflict with AudioToText)
var _mic_player: AudioStreamPlayer = null
var _capture_effect: AudioEffectCapture = null
var _capture_bus_idx: int = -1
var _capture_timer: Timer = null
var _input_converter: AudioConverter.StreamResampler = null

# Recording state
var _recording := false
var _audio_buffer: PackedByteArray = PackedByteArray()
var _pre_vad_buffer: Array[PackedByteArray] = []
var _vad_active := false
var _recording_conversion_usec := 0
var _stt_stream_session: Dictionary = {}
var _stt_stream_operation: VoiceOperation
var _pending_stt_streams: Dictionary = {} # VoiceOperation -> immutable session snapshot
var _recording_discarded_start := 0

# TTS playback tracking
var _tts_playing := false

# Idle timer
var _idle_timer: Timer = null

# PTT state
var _ptt_active := false
var _ptt_saved_engagement: String = ""

# Reconnection
var _should_connect := false
var _session_generation := 0
var _diagnostic_started_msec := 0
var _diagnostic_input_frames := 0
var _diagnostic_output_frames := 0
var _diagnostic_peak := 0.0
var _diagnostic_send_failures := 0
var _diagnostic_discarded_start := 0


func _ready() -> void:
	_capture_timer = Timer.new()
	_capture_timer.wait_time = 1.0 / CAPTURE_POLL_HZ
	_capture_timer.timeout.connect(_on_capture_tick)
	add_child(_capture_timer)

	_idle_timer = Timer.new()
	_idle_timer.one_shot = true
	_idle_timer.wait_time = ENGAGEMENT_IDLE_TIMEOUT
	_idle_timer.timeout.connect(_on_idle_timeout)
	add_child(_idle_timer)

	_setup_detector()

	# Create a dedicated audio bus for local voice capture.
	_setup_capture_bus()


func _setup_detector() -> void:
	_detector = _create_detector_adapter()
	add_child(_detector)
	_detector.connected.connect(_on_detector_connected)
	_detector.disconnected.connect(_on_detector_disconnected)
	_detector.event_received.connect(_on_detector_event)
	_detector.start_failed.connect(_on_detector_start_failed)

func _create_detector_adapter() -> Node:
	return DetectorAdapter.new()


# ── Audio Bus Setup ─────────────────────────────────────────────────────

func _setup_capture_bus() -> void:
	# Add a new bus "VoiceCapture" with AudioEffectCapture for streaming
	var bus_name := "VoiceCapture"
	_capture_bus_idx = AudioServer.get_bus_index(bus_name)
	if _capture_bus_idx < 0:
		AudioServer.add_bus()
		_capture_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_capture_bus_idx, bus_name)
		AudioServer.set_bus_mute(_capture_bus_idx, true)  # don't output to speakers
		AudioServer.set_bus_send(_capture_bus_idx, "Master")

	# Add or get AudioEffectCapture on this bus
	var has_capture := false
	for i in range(AudioServer.get_bus_effect_count(_capture_bus_idx)):
		if AudioServer.get_bus_effect(_capture_bus_idx, i) is AudioEffectCapture:
			_capture_effect = AudioServer.get_bus_effect(_capture_bus_idx, i) as AudioEffectCapture
			has_capture = true
			break

	if not has_capture:
		_capture_effect = AudioEffectCapture.new()
		AudioServer.add_bus_effect(_capture_bus_idx, _capture_effect)


# ── Connection ──────────────────────────────────────────────────────────

func start() -> void:
	if not VoiceFeature.is_enabled():
		gateway_start_failed.emit("Voice Support is disabled in Preferences")
		return
	_session_generation += 1
	_should_connect = true
	_reset_capture_diagnostics()
	_start_mic_capture()
	_capture_timer.start()
	_detector.start(_detector_configuration())
	print("[VoiceSupport] Started (waiting for detector readiness)")


func _detector_configuration() -> Dictionary:
	var cfg: RefCounted = SingletonObject.get_voice_config()
	return {"vad_silence_ms": int(cfg.vad_silence_duration * 1000)}


func update_detector_configuration() -> void:
	if is_instance_valid(_detector):
		_detector.update_config(_detector_configuration())


func stop() -> void:
	_session_generation += 1
	_should_connect = false
	_capture_timer.stop()
	_stop_mic_capture()
	if is_instance_valid(_detector):
		_detector.stop()
	_connected = false
	_reset_capture_session("voice support stopped")
	print("[VoiceSupport] Stopped")


func cancel_active_transcription() -> void:
	var operations: Array = _pending_stt_streams.keys()
	if _stt_stream_operation != null:
		operations.append(_stt_stream_operation)
	_stt_stream_operation = null
	_stt_stream_session = {}
	_recording = false
	_audio_buffer.clear()
	_pending_stt_streams.clear()
	for operation: VoiceOperation in operations:
		operation.cancel()
		transcription_stream_finished.emit(operation, {"success": false, "error_code": "cancelled", "error_message": "Voice transcription cancelled locally."})


func _reset_capture_session(reason: String) -> void:
	cancel_active_transcription()
	_recording = false
	_vad_active = false
	_ptt_active = false
	_ptt_saved_engagement = ""
	_audio_buffer.clear()
	_pre_vad_buffer.clear()
	_input_converter = null
	_cancel_idle_timer()
	_reset_capture_diagnostics()
	_set_engagement("STANDBY", reason)


func _reset_capture_diagnostics() -> void:
	_diagnostic_started_msec = Time.get_ticks_msec()
	_diagnostic_input_frames = 0
	_diagnostic_output_frames = 0
	_diagnostic_peak = 0.0
	_diagnostic_send_failures = 0
	_diagnostic_discarded_start = _capture_effect.get_discarded_frames() if _capture_effect != null else 0


# ── Mic Capture ─────────────────────────────────────────────────────────

func _start_mic_capture() -> void:
	if _mic_player:
		return
	_mic_player = AudioStreamPlayer.new()
	_mic_player.bus = &"VoiceCapture"
	_mic_player.stream = AudioStreamMicrophone.new()
	add_child(_mic_player)
	_mic_player.play()
	print("[VoiceSupport] Mic capture started on VoiceCapture bus")


func _stop_mic_capture() -> void:
	if _mic_player:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	# Drain any remaining captured audio
	if _capture_effect:
		_capture_effect.clear_buffer()
	_input_converter = null


func _on_capture_tick() -> void:
	if not _connected or not _capture_effect:
		return

	var frames_available: int = _capture_effect.get_frames_available()
	if frames_available < 256:
		_log_capture_diagnostics()
		return

	# Keep one converter across ticks so rational resampling phase and FIR history survive.
	var frames: PackedVector2Array = _capture_effect.get_buffer(frames_available)
	if frames.size() != frames_available:
		if not _stt_stream_session.is_empty():
			_fail_active_stt_stream("capture_read_failed", "Voice capture could not read buffered audio.")
		return
	_process_captured_frames(frames, int(AudioServer.get_mix_rate()), _capture_effect.get_discarded_frames())


func _process_captured_frames(frames: PackedVector2Array, native_rate: int, discarded_frames: int) -> void:
	if not _stt_stream_session.is_empty() and discarded_frames != _recording_discarded_start:
		_fail_active_stt_stream("capture_overflow", "Voice capture lost audio before transcription.")
		return
	_diagnostic_input_frames += frames.size()
	for index in range(0, frames.size(), 16):
		_diagnostic_peak = maxf(_diagnostic_peak, maxf(absf(frames[index].x), absf(frames[index].y)))
	if not _stt_stream_session.is_empty() and _input_converter != null and _input_converter.source_rate != native_rate:
		_fail_active_stt_stream("capture_rate_changed", "Audio input rate changed during voice capture.")
		return
	if _input_converter == null or _input_converter.source_rate != native_rate:
		_input_converter = AudioConverter.StreamResampler.new(native_rate)
	var conversion_started_usec := Time.get_ticks_usec()
	var pcm: PackedByteArray = _input_converter.append_frames(frames)
	if _recording:
		_recording_conversion_usec += Time.get_ticks_usec() - conversion_started_usec
	if pcm.is_empty():
		_log_capture_diagnostics()
		return
	_diagnostic_output_frames += floori(float(pcm.size()) / 2.0)

	# Send to the active local detector.
	if not is_instance_valid(_detector) or _detector.send_audio(pcm) != OK:
		_diagnostic_send_failures += 1
	_log_capture_diagnostics()

	# Manage pre-VAD buffer
	_pre_vad_buffer.append(pcm)
	var total_size: int = 0
	for chunk in _pre_vad_buffer:
		total_size += chunk.size()
	while total_size > PRE_VAD_BUFFER_MAX_BYTES and _pre_vad_buffer.size() > 1:
		total_size -= _pre_vad_buffer[0].size()
		_pre_vad_buffer.remove_at(0)

	# Accumulate if recording
	if _recording:
		if _audio_buffer.size() + pcm.size() > MAX_UTTERANCE_BYTES:
			_fail_active_stt_stream("audio_too_large", "Voice utterance exceeded the five-minute limit.")
			return
		_audio_buffer.append_array(pcm)
		if not _stt_stream_session.is_empty():
			if SingletonObject.get_voice_client().append_transcription_stream(_stt_stream_session, pcm) != OK:
				_fail_active_stt_stream("stream_send_failed", "Microphone streaming stopped. Select Buffered transport and retry.")


func _log_capture_diagnostics() -> void:
	var now := Time.get_ticks_msec()
	var window_msec := now - _diagnostic_started_msec
	if window_msec < CAPTURE_DIAGNOSTIC_INTERVAL_MSEC:
		return
	var discarded := _capture_effect.get_discarded_frames() - _diagnostic_discarded_start
	# This sampled peak separates capture/send stalls; detector endpointing remains server-owned.
	print("[VoiceSupport] stage=capture_health window_ms=%d source_rate=%d input_frames=%d output_frames=%d sampled_peak=%.4f discarded_frames=%d send_failures=%d connected=%s engagement=%s vad_active=%s recording=%s" % [
		window_msec, int(AudioServer.get_mix_rate()), _diagnostic_input_frames, _diagnostic_output_frames, _diagnostic_peak, discarded,
		_diagnostic_send_failures, _connected, engagement_state, _vad_active, _recording])
	_reset_capture_diagnostics()


# ── Detector Events ─────────────────────────────────────────────────────

func _on_detector_connected() -> void:
	if not _should_connect:
		return
	var generation := _session_generation
	# Drop audio accumulated during startup/reconnect before this detector owns capture.
	if _capture_effect != null:
		_capture_effect.clear_buffer()
	_input_converter = null
	_pre_vad_buffer.clear()
	_reset_capture_diagnostics()
	_connected = true
	connected_to_gateway.emit()
	if generation != _session_generation or not _should_connect:
		return
	print("[VoiceSupport] Detector connected")


func _on_detector_disconnected() -> void:
	var generation := _session_generation
	_connected = false
	_reset_capture_session("detector disconnected")
	if generation != _session_generation:
		return
	disconnected_from_gateway.emit()
	print("[VoiceSupport] Detector disconnected")


func _on_detector_start_failed(reason: String) -> void:
	if not _should_connect:
		return
	_should_connect = false
	_capture_timer.stop()
	_stop_mic_capture()
	_reset_capture_session("voice support unavailable")
	push_warning("[VoiceSupport] %s" % reason)
	gateway_start_failed.emit(reason)


func _on_detector_event(parsed: Dictionary) -> void:
	if not _should_connect or not _connected:
		return

	var event_type: String = parsed.get("type", "")
	match event_type:
		"wake_word":
			var confidence: float = parsed.get("confidence", 0.0)
			var generation := _session_generation
			wake_word_detected.emit(confidence)
			if generation != _session_generation or not _should_connect:
				return
			_handle_wake_word(confidence)
		"vad_start":
			_handle_vad_start()
		"vad_end":
			_handle_vad_end()


func _handle_wake_word(confidence: float) -> void:
	if _tts_playing:
		print("[VoiceSupport] Wake word during playback (%.3f) — barge-in" % confidence)
		_set_engagement("ENGAGED", "wake word barge-in")
		_cancel_idle_timer()
		_pre_vad_buffer.clear()
	elif engagement_state == "STANDBY":
		print("[VoiceSupport] Wake word in STANDBY (%.3f) — engaging" % confidence)
		_set_engagement("ENGAGED", "wake word")
		_cancel_idle_timer()
		_pre_vad_buffer.clear()
	# VAD can lead wake-word classification from the same audio. Admit recording
	# here because the detector will not emit a second vad_start edge.
	if _vad_active:
		_begin_recording_if_admitted()


func _handle_vad_start() -> void:
	_vad_active = true
	vad_started.emit()
	_begin_recording_if_admitted()


func _begin_recording_if_admitted() -> void:
	if _ptt_active:
		return  # PTT: AudioToText owns recording.
	if engagement_state != "ENGAGED":
		return  # STANDBY: ignore speech
	if _tts_playing:
		return

	if not _recording:
		_recording = true
		_recording_conversion_usec = 0
		_recording_discarded_start = _capture_effect.get_discarded_frames() if _capture_effect != null else 0
		_audio_buffer = PackedByteArray()
		var recording_prefix: Array[PackedByteArray] = []
		recording_prefix.assign(_pre_vad_buffer)
		for chunk in _pre_vad_buffer:
			_audio_buffer.append_array(chunk)
		_pre_vad_buffer.clear()
		var cfg: VoiceConfig = SingletonObject.get_voice_config()
		if cfg.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE and cfg.stt_transport == VoiceConfig.STTTransport.STREAMED:
			_stt_stream_operation = VoiceOperation.new()
			transcription_stream_started.emit(_stt_stream_operation)
			_stt_stream_session = SingletonObject.get_voice_client().begin_transcription_stream(cfg, _stt_stream_operation)
			if not _stt_stream_session.success:
				var failed_operation := _stt_stream_operation
				var failed_outcome := _stt_stream_session
				_stt_stream_operation = null
				_stt_stream_session = {}
				_recording = false
				_audio_buffer.clear()
				transcription_stream_finished.emit(failed_operation, failed_outcome)
				return
			var stream_request = _stt_stream_session.request
			stream_request.finished.connect(_on_gateway_stream_terminal.bind(stream_request), CONNECT_ONE_SHOT)
			for chunk in recording_prefix:
				if SingletonObject.get_voice_client().append_transcription_stream(_stt_stream_session, chunk) != OK:
					_fail_active_stt_stream("stream_send_failed", "Microphone streaming stopped. Select Buffered transport and retry.")
					return
		_cancel_idle_timer()
		print("[VoiceSupport] Recording started (with %d bytes pre-VAD)" % _audio_buffer.size())


func _handle_vad_end() -> void:
	_vad_active = false
	vad_ended.emit()

	if _recording:
		if not _stt_stream_session.is_empty() and _capture_effect != null and _capture_effect.get_discarded_frames() != _recording_discarded_start:
			_fail_active_stt_stream("capture_overflow", "Voice capture lost audio before transcription.")
			return
		var current_rate := int(AudioServer.get_mix_rate())
		if not _stt_stream_session.is_empty() and _input_converter != null and _input_converter.source_rate != current_rate:
			_fail_active_stt_stream("capture_rate_changed", "Audio input rate changed during voice capture.")
			return
		_recording = false
		# This boundary is local; streamed captures already have an operation ID in adapter logs.
		print("[VoiceSupport] stage=vad_boundary audio_bytes=%d sample_rate=%d channels=1 conversion_ms=%.3f" % [
			_audio_buffer.size(), TARGET_SAMPLE_RATE, _recording_conversion_usec / 1000.0])
		# Minimum 0.5s at 16kHz s16le = 16000 bytes
		if _audio_buffer.size() > 16000 and _has_speech_energy(_audio_buffer):
			if not _stt_stream_session.is_empty():
				_finish_active_stt_stream()
			else:
				var wav: PackedByteArray = _pcm_to_wav(_audio_buffer)
				transcription_ready.emit(wav)
		else:
			print("[VoiceSupport] Discarded recording (too short or below energy threshold)")
			if _stt_stream_operation != null:
				var rejected := _stt_stream_operation
				_stt_stream_operation = null
				_stt_stream_session = {}
				rejected.cancel()
				transcription_stream_finished.emit(rejected, {"success": false, "error_code": "not_speech", "error_message": "Voice capture was too short or quiet."})
		_audio_buffer = PackedByteArray()


func _finish_active_stt_stream() -> void:
	var operation := _stt_stream_operation
	var session := _stt_stream_session
	if operation == null:
		return
	_stt_stream_operation = null
	_stt_stream_session = {}
	_pending_stt_streams[operation] = session
	var outcome: Dictionary = await SingletonObject.get_voice_client().finish_transcription_stream(session, operation)
	if _pending_stt_streams.get(operation) != session:
		return
	_pending_stt_streams.erase(operation)
	transcription_stream_finished.emit(operation, outcome)


func _on_gateway_stream_terminal(outcome: Dictionary, request) -> void:
	if _stt_stream_session.get("request") != request or not _recording:
		return
	var visible: Dictionary = SingletonObject.get_voice_client().normalize_stream_failure(outcome)
	_fail_active_stt_stream(str(visible.get("error_code", "stream_failed")), str(visible.get("error_message", "Microphone streaming stopped.")))


func _fail_active_stt_stream(code: String, message: String) -> void:
	var operation := _stt_stream_operation
	_stt_stream_operation = null
	_stt_stream_session = {}
	_recording = false
	_audio_buffer.clear()
	if operation != null:
		operation.cancel()
		transcription_stream_finished.emit(operation, {"success": false, "error_code": code, "error_message": message})


# ── Engagement State Machine ────────────────────────────────────────────

func is_engaged_or_ptt() -> bool:
	return engagement_state == "ENGAGED" or _ptt_active


func _set_engagement(new_state: String, reason: String = "") -> void:
	if engagement_state == new_state:
		return
	var old: String = engagement_state
	engagement_state = new_state
	print("[VoiceSupport] %s → %s (%s)" % [old, new_state, reason])
	engagement_changed.emit(new_state)


func check_dismiss_phrase(text: String) -> bool:
	var clean: String = text.strip_edges().to_lower().rstrip(".!,")
	if clean in ["stop listening", "stop listen"]:
		_set_engagement("STANDBY", "user said 'stop listening'")
		_cancel_idle_timer()
		return true
	return false


func notify_tts_started() -> void:
	_tts_playing = true
	_cancel_idle_timer()


func notify_tts_finished() -> void:
	_tts_playing = false
	if engagement_state == "ENGAGED":
		_start_idle_timer()


func ptt_down() -> void:
	_ptt_active = true
	_ptt_saved_engagement = engagement_state
	_cancel_idle_timer()


func ptt_up() -> void:
	_ptt_active = false
	var saved: String = _ptt_saved_engagement
	_ptt_saved_engagement = ""
	if saved != "" and saved != engagement_state:
		_set_engagement(saved, "PTT released")


# ── Idle Timer ──────────────────────────────────────────────────────────

func _start_idle_timer() -> void:
	_idle_timer.start(ENGAGEMENT_IDLE_TIMEOUT)

func _cancel_idle_timer() -> void:
	_idle_timer.stop()

func _on_idle_timeout() -> void:
	if engagement_state == "ENGAGED" and not _ptt_active:
		_set_engagement("STANDBY", "%.0fs idle timeout" % ENGAGEMENT_IDLE_TIMEOUT)


# ── Audio Utilities ─────────────────────────────────────────────────────

func _has_speech_energy(pcm: PackedByteArray) -> bool:
	"""Check if PCM audio has enough energy to be speech (not just noise)."""
	if pcm.size() < 4:
		return false
	var sum_sq: float = 0.0
	var n_samples: int = pcm.size() >> 1
	for i in range(n_samples):
		var sample: float = float(pcm.decode_s16(i * 2))
		sum_sq += sample * sample
	var rms: float = sqrt(sum_sq / float(n_samples))
	# RMS threshold: ~100 for quiet speech after resampling, ambient noise <50
	return rms > 80.0


func _pcm_to_wav(pcm: PackedByteArray) -> PackedByteArray:
	return AudioConverter.pcm16_to_wav(pcm)
