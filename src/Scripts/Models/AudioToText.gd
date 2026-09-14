class_name AudioToTexts
extends Node

const AudioConverter = preload("res://Scripts/Services/Voice/AudioInputConverter.gd")
const VoiceFeature = preload("res://Scripts/Services/Voice/VoiceFeatureControl.gd")

var effect
var recording
var file_path = "res://VoiceAudio.wav"

var _btn: Button
var _btn_stop: Button
var is_converting: bool = false
var http_request

const WHISPER_API_URL = "https://api.openai.com/v1/audio/transcriptions"

var _field_for_filling  # TextEdit or LineEdit — untyped for flexibility

var stop_signal: bool = false

var mic_player: AudioStreamPlayer
const MAX_NORMALIZED_CAPTURE_BYTES := 16000 * 2 * 300 # Five minutes of mono PCM16.
var _normalization_capture
var _normalization_converter
var _normalized_pcm := PackedByteArray()
var _normalization_rate := 0
var _normalization_discarded_start := 0
var _normalization_error := ""
var _owns_normalization_capture := false

## Signal emitted when transcription completes (for push-to-talk and other consumers).
## text is the transcribed string, empty on error.
signal transcription_completed(text: String)

## Explicit PTT state machine. Consumed by MicButtonBinding (UI visuals) and
## StreamDeckServer (WebSocket broadcasts). Every visual transition goes
## through _set_ptt_state — no direct .modulate / .icon writes on _btn.
enum PTTState { READY, LISTENING, TRANSCRIBING, ERROR }
var ptt_state: int = PTTState.READY
## info dict carries: mic_button (BaseButton), target (Control), error_message (String)
signal ptt_state_changed(new_state: int, info: Dictionary)

const ERROR_AUTO_CLEAR_SECONDS := 1.5


## How transcript text should be inserted into the target control.
enum InsertMode { APPEND, REPLACE, AT_CARET }


## Bundle of PTT parameters. Callers set fields directly then pass to start_ptt().
class PTTRequest:
	var target: Control                # required — TextEdit/LineEdit/CodeEdit where transcript lands
	var mic_button: BaseButton = null  # optional — drives LIME_GREEN → loading → mic icon cycle
	var stop_button: BaseButton = null # optional — for UIs with a separate stop control
	var voice_gateway = null           # optional — object with ptt_down()/ptt_up() methods
	var clear_before: bool = false     # pre-clear target before recording (AISettings pattern)
	var insert_mode: int = InsertMode.APPEND


## The currently active PTT request, if start_ptt initiated the recording. Consulted by
## _finish_transcription to choose insertion behaviour. Null for legacy call sites.
var _active_ptt_req: PTTRequest = null
var _voice_operation: VoiceOperation
var _stt_stream_session: Dictionary = {}
var _voice_generation := 0
var _ptt_capture_started_msec := 0
var _ptt_submit_started_msec := 0
var _ptt_sequence := 0
var _ptt_diagnostic_id := ""
var _whisper_started_msec := 0
var _whisper_audio_bytes := 0
var _whisper_fallback_from := "none"
## True if the most recent start_ptt called voice_gateway.ptt_down(). Gates stop_ptt's
## ptt_up() call so stop_ptt is idempotent.
var _ptt_gateway_down: bool = false
var _ptt_turnrock_owned := false


func _ready():
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)
	_normalization_capture = AudioEffectCapture.new()
	_normalization_capture.buffer_length = 1.0
	AudioServer.add_bus_effect(idx, _normalization_capture)
	_owns_normalization_capture = true
	# Create mic player dynamically (not in scene) to avoid Godot 4.6 shutdown crash:
	# AudioStreamPlaybackMicrophone::stop() dereferences freed audio driver in destructor.
	mic_player = AudioStreamPlayer.new()
	mic_player.bus = &"Rec"
	add_child(mic_player)


func _process(_delta: float) -> void:
	_drain_normalization_capture()


func _start_mic():
	if not mic_player.playing:
		mic_player.stream = AudioStreamMicrophone.new()
		mic_player.play()


func _stop_mic():
	if not is_instance_valid(mic_player):
		return
	if mic_player.playing:
		mic_player.stop()
	mic_player.stream = null


func _exit_tree():
	_cancel_voice_transcription()
	_remove_normalization_capture()
	_stop_mic()


func _cancel_voice_transcription(discard_capture: bool = true) -> void:
	_voice_generation += 1
	var operation := _voice_operation
	_voice_operation = null
	if operation != null:
		operation.cancel()
	if discard_capture:
		_ptt_turnrock_owned = false
		_reset_normalization_capture()


## Stop only capture/request work that was admitted through Voice Support.
func deactivate_turnrock_voice() -> void:
	if _ptt_turnrock_owned or (_voice_operation != null and _voice_operation.voice_owner == "turnrock"):
		_StopConverting()


func _begin_normalization_capture() -> bool:
	_reset_normalization_capture()
	if _normalization_capture == null:
		return false
	_normalization_rate = int(AudioServer.get_mix_rate())
	_normalization_converter = AudioConverter.StreamResampler.new(_normalization_rate)
	if not _normalization_converter.valid:
		_normalization_converter = null
		return false
	_normalization_capture.clear_buffer()
	_normalization_discarded_start = _normalization_capture.get_discarded_frames()
	return true


func _drain_normalization_capture() -> void:
	if _normalization_capture == null or _normalization_converter == null or not _normalization_error.is_empty():
		return
	if not _stt_stream_session.is_empty() and _normalization_capture.get_discarded_frames() != _normalization_discarded_start:
		_abort_streaming_capture("Voice capture overflowed before transcription.")
		return
	if int(AudioServer.get_mix_rate()) != _normalization_rate:
		_abort_streaming_capture("Audio input rate changed during capture.")
		return
	var available: int = _normalization_capture.get_frames_available()
	if available <= 0:
		return
	var frames: PackedVector2Array = _normalization_capture.get_buffer(available)
	if frames.size() != available:
		_abort_streaming_capture("Voice capture could not read buffered audio.")
		return
	var chunk: PackedByteArray = _normalization_converter.append_frames(frames)
	if not _stt_stream_session.is_empty() and not chunk.is_empty():
		if SingletonObject.get_voice_client().append_transcription_stream(_stt_stream_session, chunk) != OK:
			_abort_streaming_capture("Microphone streaming stopped before transcription. Select Buffered transport and retry.")
		return
	if _normalized_pcm.size() + chunk.size() > MAX_NORMALIZED_CAPTURE_BYTES:
		_normalization_error = "Voice capture exceeded the five-minute limit."
		return
	_normalized_pcm.append_array(chunk)


func _abort_streaming_capture(message: String) -> void:
	_normalization_error = message
	if _stt_stream_session.is_empty():
		return
	if effect != null and effect.is_recording_active():
		effect.set_recording_active(false)
	_stop_mic()
	var operation := _voice_operation
	_voice_operation = null
	if operation != null:
		operation.cancel()
	_reset_normalization_capture()
	_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": message})


func _finish_normalization_capture() -> Dictionary:
	_drain_normalization_capture()
	if _normalization_capture == null or _normalization_converter == null:
		return {"success": false, "error_message": "Audio normalization is unavailable."}
	if _normalization_capture.get_discarded_frames() != _normalization_discarded_start:
		_normalization_error = "Voice capture overflowed before transcription."
	if _normalization_error.is_empty():
		var tail: PackedByteArray = _normalization_converter.flush()
		if not _stt_stream_session.is_empty() and not tail.is_empty():
			if SingletonObject.get_voice_client().append_transcription_stream(_stt_stream_session, tail) != OK:
				_normalization_error = "Microphone streaming stopped before transcription. Select Buffered transport and retry."
		elif _normalized_pcm.size() + tail.size() > MAX_NORMALIZED_CAPTURE_BYTES:
			_normalization_error = "Voice capture exceeded the five-minute limit."
		else:
			_normalized_pcm.append_array(tail)
	if not _normalization_error.is_empty():
		return {"success": false, "error_message": _normalization_error}
	if not _stt_stream_session.is_empty():
		var request = _stt_stream_session.get("request")
		if request == null or request.audio_bytes <= 0:
			return {"success": false, "error_message": "No audio was captured for transcription."}
		return {"success": true, "streaming": true, "audio_bytes": request.audio_bytes}
	if _normalized_pcm.is_empty():
		return {"success": false, "error_message": "No audio was captured for transcription."}
	return {"success": true, "wav": AudioConverter.pcm16_to_wav(_normalized_pcm)}


func _reset_normalization_capture() -> void:
	_normalization_converter = null
	_normalized_pcm.clear()
	_normalization_rate = 0
	_normalization_error = ""
	if _normalization_capture != null:
		_normalization_capture.clear_buffer()
	_stt_stream_session = {}


func _remove_normalization_capture() -> void:
	if not _owns_normalization_capture or _normalization_capture == null:
		return
	var bus := AudioServer.get_bus_index("Rec")
	for index in range(AudioServer.get_bus_effect_count(bus)):
		if AudioServer.get_bus_effect(bus, index) == _normalization_capture:
			AudioServer.remove_bus_effect(bus, index)
			break
	_normalization_capture = null
	_owns_normalization_capture = false


## Canonical PTT state transition. All visual updates flow from ptt_state_changed;
## callers must not write to mic buttons directly. ERROR auto-clears back to READY
## after a short hold so transient failures don't leave the button stuck red.
func _set_ptt_state(new_state: int, info: Dictionary = {}) -> void:
	ptt_state = new_state
	ptt_state_changed.emit(new_state, info)
	if new_state == PTTState.ERROR:
		var tree := get_tree()
		if tree == null:
			return
		var stored_btn: BaseButton = info.get("mic_button")
		var t := tree.create_timer(ERROR_AUTO_CLEAR_SECONDS)
		var cb := func() -> void:
			if ptt_state == PTTState.ERROR:
				_set_ptt_state(PTTState.READY, {"mic_button": stored_btn})
		t.timeout.connect(cb, CONNECT_ONE_SHOT)


## Unified PTT entry point. Owns legacy-field assignment, gateway sequencing, button
## state, and recording start. Returns OK on success, or an error code on failure.
func start_ptt(req: PTTRequest) -> int:
	if req == null or not is_instance_valid(req.target):
		push_warning("AudioToText.start_ptt: req.target is required")
		return ERR_INVALID_PARAMETER
	# A second press ends the active recording; keep its locally normalized PCM
	# until _StartConverting performs the final drain and buffered dispatch or stream END.
	var stopping_recording: bool = effect != null and effect.is_recording_active()
	if not stopping_recording:
		_cancel_voice_transcription()

	# Cancel any in-flight TTS before binding the mic. Output stream must end before
	# the driver renegotiates for input, otherwise the mic capture comes up zombied.
	# Non-blocking: cancel_tts() stops playback and its owned local Core await.
	# Future speech operations are independent of this cancellation.
	var chats := SingletonObject.Chats
	if chats != null and chats.has_method("cancel_tts"):
		chats.cancel_tts()

	# Populate internal fields so existing _finish_transcription / _StartConverting paths work.
	_field_for_filling = req.target
	_btn = req.mic_button
	_btn_stop = req.stop_button
	_active_ptt_req = req
	_ptt_gateway_down = false

	# Auto-attach visual binding. Idempotent via meta marker.
	if req.mic_button != null:
		MicButtonBinding.attach(req.mic_button)

	if req.clear_before:
		req.target.text = ""

	if req.voice_gateway != null and req.voice_gateway.has_method("ptt_down"):
		req.voice_gateway.ptt_down()
		_ptt_gateway_down = true

	var err: int = _StartConverting()
	if err != OK:
		# Roll back gateway state if we engaged it, so the gateway doesn't stay suppressed.
		if _ptt_gateway_down and req.voice_gateway != null and req.voice_gateway.has_method("ptt_up"):
			req.voice_gateway.ptt_up()
		_ptt_gateway_down = false
		_active_ptt_req = null
		return err

	# LISTENING is emitted inside _StartConverting's start-recording branch, so
	# toggle-press-twice flows end in TRANSCRIBING without being overwritten here.
	return OK


## Tear down the gateway side of PTT. Idempotent — safe to call when no PTT is active.
## Does NOT stop recording (that's owned by _StartConverting toggle / btnStop press).
func stop_ptt() -> void:
	# ptt_up gated on ptt_down having fired, to keep stop_ptt idempotent.
	if not _ptt_gateway_down:
		return
	var req := _active_ptt_req
	if req != null and req.voice_gateway != null and req.voice_gateway.has_method("ptt_up"):
		req.voice_gateway.ptt_up()
	_ptt_gateway_down = false


## Start/stop recording toggle. Routes STT based on VoiceConfig provider selection.
func _StartConverting():
	stop_signal = false
	if effect.is_recording_active():
		var prepare_started_msec := Time.get_ticks_msec()
		_ptt_submit_started_msec = prepare_started_msec
		if _ptt_diagnostic_id.is_empty():
			_ptt_sequence += 1
			_ptt_diagnostic_id = "ptt-%d" % _ptt_sequence
		# Stop recording and get the in-memory PCM captured by AudioEffectRecord.
		recording = effect.get_recording()
		effect.set_recording_active(false)
		_stop_mic()

		# Guard: recording_data can be empty when PTT is tapped faster than the mic
		# takes to prime, or when no samples were captured before stop. In that case
		# get_recording() returns null.
		if recording == null:
			push_warning("AudioToText: no audio captured (PTT tap too fast or mic not primed)")
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "No audio captured"})
			_reset_normalization_capture()
			_cancel_voice_transcription()
			return ERR_INVALID_DATA

		# Freeze the upload payload before artifact I/O can allow unrelated capture frames in.
		var conversion_started_msec := Time.get_ticks_msec()
		var converted := _finish_normalization_capture()
		var completed_stream_session := _stt_stream_session
		var conversion_msec := Time.get_ticks_msec() - conversion_started_msec
		_reset_normalization_capture()

		# Preserve the existing user-visible capture artifact independently of upload preparation.
		var file_save_started_msec := Time.get_ticks_msec()
		recording.save_to_wav(file_path)
		var file_save_msec := Time.get_ticks_msec() - file_save_started_msec
		var source_bytes: int = recording.data.size()
		var source_rate: int = recording.mix_rate
		var source_channels := 2 if recording.stereo else 1
		print("[VoiceSTT] operation=%s stage=captured capture_ms=%d file_save_ms=%d audio_bytes=%d sample_rate=%d channels=%d" % [
			_ptt_diagnostic_id, prepare_started_msec - _ptt_capture_started_msec if _ptt_capture_started_msec > 0 else 0,
			file_save_msec, source_bytes, source_rate, source_channels])
		if not converted.success:
			push_warning("[VoiceSTT] operation=%s stage=conversion elapsed_ms=%d status=invalid_capture" % [_ptt_diagnostic_id, conversion_msec])
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": converted.error_message})
			_cancel_voice_transcription()
			return ERR_INVALID_DATA
		if converted.get("streaming", false):
			print("[VoiceSTT] operation=%s stage=stream_prepared elapsed_ms=%d audio_bytes=%d sample_rate=%d channels=1" % [
				_ptt_diagnostic_id, conversion_msec, int(converted.audio_bytes), AudioConverter.TARGET_RATE])
			_finish_voice_service_stream(completed_stream_session)
			return OK
		var wav_bytes: PackedByteArray = converted.wav
		print("[VoiceSTT] operation=%s stage=converted elapsed_ms=%d audio_bytes=%d sample_rate=%d channels=1 status=success" % [
			_ptt_diagnostic_id, conversion_msec, wav_bytes.size(), AudioConverter.TARGET_RATE])

		if stop_signal:
			print("Conversion stopped")
			_set_ptt_state(PTTState.READY, {"mic_button": _btn})
			return ERR_SKIP

		# Route to appropriate STT backend
		var voice_config := SingletonObject.get_voice_config()
		var provider := voice_config.get_effective_stt_provider()
		_ptt_turnrock_owned = provider == VoiceConfig.STTProvider.VOICE_SERVICE
		var capture_msec := prepare_started_msec - _ptt_capture_started_msec if _ptt_capture_started_msec > 0 else 0
		_whisper_fallback_from = "core_disconnected" if voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE and provider == VoiceConfig.STTProvider.OPENAI_WHISPER else "none"
		print("[VoiceSTT] operation=%s stage=prepared prepare_ms=%d capture_ms=%d audio_bytes=%d sample_rate=%d channels=%d backend=%s model=%s fallback_from=%s" % [
			_ptt_diagnostic_id, Time.get_ticks_msec() - prepare_started_msec, capture_msec, wav_bytes.size(), AudioConverter.TARGET_RATE, 1,
			voice_config.stt_backend if provider == VoiceConfig.STTProvider.VOICE_SERVICE else "openai",
			voice_config.stt_model if provider == VoiceConfig.STTProvider.VOICE_SERVICE else "whisper-1", _whisper_fallback_from])

		if provider == VoiceConfig.STTProvider.VOICE_SERVICE:
			# Fire-and-forget: runs async, _StartConverting returns OK immediately
			_start_voice_service_stt(wav_bytes, voice_config)
		else:
			_start_whisper_stt(wav_bytes)
	else:
		_ptt_capture_started_msec = Time.get_ticks_msec()
		_ptt_diagnostic_id = ""
		var voice_config: VoiceConfig = SingletonObject.get_voice_config()
		if voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE and not VoiceFeature.is_enabled():
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "Voice Support is disabled in Preferences"})
			return ERR_UNAVAILABLE
		if not _begin_normalization_capture():
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "Audio normalization is unavailable"})
			return ERR_CANT_CREATE
		_start_mic()
		effect.set_recording_active(true)
		_ptt_turnrock_owned = voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE
		if voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE and voice_config.stt_transport == VoiceConfig.STTTransport.STREAMED:
			_ptt_sequence += 1
			_ptt_diagnostic_id = "ptt-%d" % _ptt_sequence
			var operation := VoiceOperation.new()
			operation.diagnostic_id = _ptt_diagnostic_id
			var session: Dictionary = SingletonObject.get_voice_client().begin_transcription_stream(voice_config, operation, _ptt_diagnostic_id)
			if not session.success:
				effect.set_recording_active(false)
				_stop_mic()
				_reset_normalization_capture()
				_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": session.error_message})
				return ERR_CANT_CONNECT
			_voice_operation = operation
			_stt_stream_session = session
			var stream_request = session.request
			stream_request.finished.connect(_on_ptt_stream_terminal.bind(stream_request), CONNECT_ONE_SHOT)
		_set_ptt_state(PTTState.LISTENING, {"mic_button": _btn, "target": _field_for_filling})

	return OK


func _finish_voice_service_stream(session: Dictionary) -> void:
	var operation := _voice_operation
	if operation == null:
		return
	var generation := _voice_generation
	_set_ptt_state(PTTState.TRANSCRIBING, {"mic_button": _btn, "target": _field_for_filling})
	if _btn_stop != null:
		_btn_stop.disabled = false
	var outcome: Dictionary = await SingletonObject.get_voice_client().finish_transcription_stream(session, operation)
	if generation != _voice_generation or _voice_operation != operation:
		return
	_voice_operation = null
	if _ptt_submit_started_msec > 0:
		print("[VoiceSTT] operation=%s stage=ptt_total elapsed_ms=%d status=%s fallback_from=none" % [
			operation.diagnostic_id, Time.get_ticks_msec() - _ptt_submit_started_msec,
			"success" if outcome.get("success", false) else str(outcome.get("error_code", "error"))])
	_finish_transcription(outcome.get("text", ""), outcome.success, outcome.get("error_message", ""))


func _on_ptt_stream_terminal(outcome: Dictionary, request) -> void:
	if _stt_stream_session.get("request") != request or effect == null or not effect.is_recording_active():
		return
	effect.set_recording_active(false)
	_stop_mic()
	_reset_normalization_capture()
	var operation := _voice_operation
	_voice_operation = null
	if operation != null:
		operation.cancel()
	var visible: Dictionary = SingletonObject.get_voice_client().normalize_stream_failure(outcome)
	_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": visible.get("error_message", "Microphone streaming stopped.")})


## STT via voice-service (Core WebSocket).
func _start_voice_service_stt(wav_bytes: PackedByteArray, voice_config: VoiceConfig) -> void:
	_cancel_voice_transcription()
	var generation := _voice_generation
	var operation := VoiceOperation.new()
	operation.diagnostic_id = _ptt_diagnostic_id
	_voice_operation = operation
	_set_ptt_state(PTTState.TRANSCRIBING, {"mic_button": _btn, "target": _field_for_filling})
	if _btn_stop != null:
		_btn_stop.disabled = false

	var client := SingletonObject.get_voice_client()
	var outcome := await client.transcribe_auto_result(wav_bytes, voice_config, operation)
	if generation != _voice_generation or _voice_operation != operation:
		return
	_voice_operation = null
	if _ptt_submit_started_msec > 0:
		var status := "success" if outcome.get("success", false) else str(outcome.get("error_code", "error"))
		print("[VoiceSTT] operation=%s stage=ptt_total elapsed_ms=%d status=%s fallback_from=%s" % [
			operation.diagnostic_id, Time.get_ticks_msec() - _ptt_submit_started_msec, status,
			str(outcome.get("fallback_from", "none"))])
	_finish_transcription(outcome.get("text", ""), outcome.success, outcome.get("error_message", ""))


## STT via OpenAI Whisper REST API (original path).
func _start_whisper_stt(wav_bytes: PackedByteArray) -> void:
	_whisper_started_msec = Time.get_ticks_msec()
	_whisper_audio_bytes = wav_bytes.size()
	if SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI).is_empty():
		_log_whisper_terminal("missing_api_key")
		SingletonObject.ErrorDisplay("No API Key", "Missing OpenAI API key for Whisper service")
		return

	http_request = HTTPRequest.new()
	http_request.use_threads = true
	add_child(http_request)
	http_request.connect("request_completed", self._on_request_completed)

	var boundary = "--------------------------" + str(Time.get_ticks_msec())
	var form_data = PackedByteArray()

	form_data.append_array(("--%s\r\n" % boundary).to_ascii_buffer())
	form_data.append_array("Content-Disposition: form-data; name=\"model\"\r\n\r\n".to_ascii_buffer())
	form_data.append_array("whisper-1\r\n".to_ascii_buffer())

	form_data.append_array(("--%s\r\n" % boundary).to_ascii_buffer())
	form_data.append_array("Content-Disposition: form-data; name=\"file\"; filename=\"VoiceAudio.wav\"\r\n".to_ascii_buffer())
	form_data.append_array("Content-Type: audio/wav\r\n\r\n".to_ascii_buffer())
	form_data.append_array(wav_bytes)
	form_data.append_array(("\r\n--%s--\r\n" % boundary).to_ascii_buffer())

	var headers = [
		"Authorization: Bearer " + SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI),
		"Content-Type: multipart/form-data; boundary=" + boundary,
	]

	print("[VoiceSTT] operation=%s stage=dispatch audio_bytes=%d backend=openai model=whisper-1" % [
		_ptt_diagnostic_id, wav_bytes.size()])
	http_request.request_raw(WHISPER_API_URL, headers, HTTPClient.METHOD_POST, form_data)
	_set_ptt_state(PTTState.TRANSCRIBING, {"mic_button": _btn, "target": _field_for_filling})
	if _btn_stop != null:
		_btn_stop.disabled = false


func _StopConverting():
	_cancel_voice_transcription()
	stop_signal = true
	if effect != null and effect.is_recording_active():
		effect.set_recording_active(false)
		print("Recording stopped")
	_stop_mic()

	if http_request:
		_log_whisper_terminal("cancelled")
		http_request.disconnect("request_completed", self._on_request_completed)
		remove_child(http_request)
		http_request.queue_free()
		http_request = null
		print("HTTP request stopped")

	_set_ptt_state(PTTState.READY, {"mic_button": _btn})
	if _btn_stop != null:
		_btn_stop.disabled = true


## Move caret to the end of the control's text, handling TextEdit/CodeEdit vs LineEdit.
func _move_caret_to_end(ctrl: Control) -> void:
	if ctrl == null:
		return
	if ctrl is TextEdit:
		var te: TextEdit = ctrl
		var last_line: int = te.get_line_count() - 1
		if last_line < 0:
			last_line = 0
		te.set_caret_line(last_line)
		te.set_caret_column(te.get_line(last_line).length())
	elif ctrl is LineEdit:
		var le: LineEdit = ctrl
		le.caret_column = le.text.length()


## Shared completion handler — fills text field and emits signal.
func _finish_transcription(text: String, successful_empty: bool = false, error_message: String = "") -> void:
	_ptt_turnrock_owned = false
	var active_req := _active_ptt_req
	var insertion_status := "empty"

	if text.is_empty() and not successful_empty:
		insertion_status = "error"
		var reason := error_message if not error_message.is_empty() else "No text returned from STT provider"
		_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": reason})
		SingletonObject.ErrorDisplay("Transcription Failed", reason)
	else:
		_set_ptt_state(PTTState.READY, {"mic_button": _btn})
		print("Transcription:", text)
		var target: Control = null
		if active_req != null:
			if is_instance_valid(active_req.target):
				target = active_req.target
		elif is_instance_valid(_field_for_filling):
			target = _field_for_filling

		if is_instance_valid(target) and not text.is_empty():
			var mode: int = active_req.insert_mode if active_req != null else InsertMode.APPEND
			if active_req != null and mode == InsertMode.REPLACE:
				target.text = text
			elif active_req != null and mode == InsertMode.AT_CARET and target.has_method("insert_text_at_caret"):
				target.insert_text_at_caret(text)
			else:
				# APPEND (or legacy). Drop the leading space when target is empty.
				var prefix := "" if target.text.is_empty() else " "
				target.text += prefix + text

			_move_caret_to_end(target)
			if target.has_method("grab_focus"):
				target.grab_focus()
			insertion_status = "success"
		elif not text.is_empty():
			insertion_status = "target_unavailable"
	if _ptt_submit_started_msec > 0:
		print("[VoiceSTT] operation=%s stage=ui_insert elapsed_ms=%d status=%s characters=%d" % [
			_ptt_diagnostic_id, Time.get_ticks_msec() - _ptt_submit_started_msec, insertion_status, text.length()])
		_ptt_submit_started_msec = 0

	if is_instance_valid(SingletonObject.transcription_notification_player):
		SingletonObject.transcription_notification_player.play()
	transcription_completed.emit(text)
	_active_ptt_req = null


func _on_request_completed(_result, response_code, _headers, body):
	if response_code == 200:
		var response_json = JSON.parse_string(body.get_string_from_utf8())
		if response_json and response_json.has("text"):
			_log_whisper_terminal("success")
			_finish_transcription(response_json["text"])
			return

	var err_msg := "Invalid response from Whisper API"
	if response_code != 200:
		var error_json = JSON.parse_string(body.get_string_from_utf8())
		if error_json is Dictionary and error_json.has("error") and error_json["error"].has("message"):
			err_msg = error_json["error"]["message"]
		print("Error:", response_code, "Response:", body.get_string_from_utf8())

	_log_whisper_terminal("http_error" if response_code != 200 else "invalid_response")
	_finish_transcription("")
	SingletonObject.ErrorDisplay("STT Error", err_msg)


func _log_whisper_terminal(status: String) -> void:
	if _whisper_started_msec <= 0:
		return
	var total_started_msec := _ptt_submit_started_msec if _ptt_submit_started_msec > 0 else _whisper_started_msec
	print("[VoiceSTT] operation=%s stage=ptt_total elapsed_ms=%d audio_bytes=%d backend=openai model=whisper-1 status=%s fallback_from=%s" % [
		_ptt_diagnostic_id, Time.get_ticks_msec() - total_started_msec, _whisper_audio_bytes, status, _whisper_fallback_from])
	_whisper_started_msec = 0
