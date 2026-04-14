class_name AudioToTexts
extends Node

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
## True if the most recent start_ptt called voice_gateway.ptt_down(). Gates stop_ptt's
## ptt_up() call so stop_ptt is idempotent.
var _ptt_gateway_down: bool = false


func _ready():
	var idx = AudioServer.get_bus_index("Rec")
	effect = AudioServer.get_bus_effect(idx, 0)
	# Create mic player dynamically (not in scene) to avoid Godot 4.6 shutdown crash:
	# AudioStreamPlaybackMicrophone::stop() dereferences freed audio driver in destructor.
	mic_player = AudioStreamPlayer.new()
	mic_player.bus = &"Rec"
	add_child(mic_player)


func _start_mic():
	if not mic_player.playing:
		mic_player.stream = AudioStreamMicrophone.new()
		mic_player.play()


func _stop_mic():
	if mic_player.playing:
		mic_player.stop()
	mic_player.stream = null


func _exit_tree():
	_stop_mic()


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
	if req == null or req.target == null:
		push_warning("AudioToText.start_ptt: req.target is required")
		return ERR_INVALID_PARAMETER

	# Cancel any in-flight TTS before binding the mic. Output stream must end before
	# the driver renegotiates for input, otherwise the mic capture comes up zombied.
	# Non-blocking: cancel_tts() stops playback synchronously and flags in-flight
	# synthesis to bail at its next checkpoint; the flag stays set through the
	# WebSocket round-trip and is cleared by the next _voice_speak_response.
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
		# Stop recording and get WAV data
		recording = effect.get_recording()
		effect.set_recording_active(false)
		_stop_mic()

		# Guard: recording_data can be empty when PTT is tapped faster than the mic
		# takes to prime, or when no samples were captured before stop. In that case
		# get_recording() returns null.
		if recording == null:
			push_warning("AudioToText: no audio captured (PTT tap too fast or mic not primed)")
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "No audio captured"})
			return ERR_INVALID_DATA

		recording.save_to_wav(file_path)

		var wav_bytes := _read_wav_file()
		if wav_bytes.is_empty():
			_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "Audio file unreadable"})
			return ERR_INVALID_DATA

		if stop_signal:
			print("Conversion stopped")
			_set_ptt_state(PTTState.READY, {"mic_button": _btn})
			return ERR_SKIP

		# Route to appropriate STT backend
		var voice_config := SingletonObject.get_voice_config()
		var provider := voice_config.get_effective_stt_provider()

		if provider == VoiceConfig.STTProvider.VOICE_SERVICE:
			# Fire-and-forget: runs async, _StartConverting returns OK immediately
			_start_voice_service_stt(wav_bytes, voice_config)
		else:
			_start_whisper_stt(wav_bytes)
	else:
		_start_mic()
		effect.set_recording_active(true)
		_set_ptt_state(PTTState.LISTENING, {"mic_button": _btn, "target": _field_for_filling})

	return OK


## Read WAV file into PackedByteArray, validating RIFF header.
func _read_wav_file() -> PackedByteArray:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print("Failed to open audio file: ", file_path)
		return PackedByteArray()

	var header = file.get_buffer(4)
	var header_str = header.get_string_from_utf8()

	if header_str != "RIFF":
		print("Invalid file format. Header: ", header_str)
		file.close()
		return PackedByteArray()

	# Read full file (rewind)
	file.seek(0)
	var full_data = file.get_buffer(file.get_length())
	file.close()
	return full_data


## STT via voice-service (Core WebSocket).
func _start_voice_service_stt(wav_bytes: PackedByteArray, voice_config: VoiceConfig) -> void:
	_set_ptt_state(PTTState.TRANSCRIBING, {"mic_button": _btn, "target": _field_for_filling})
	if _btn_stop != null:
		_btn_stop.disabled = false

	var client := SingletonObject.get_voice_client()
	var text := await client.transcribe_auto(wav_bytes, voice_config)

	_finish_transcription(text)


## STT via OpenAI Whisper REST API (original path).
func _start_whisper_stt(wav_bytes: PackedByteArray) -> void:
	if SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI).is_empty():
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

	http_request.request_raw(WHISPER_API_URL, headers, HTTPClient.METHOD_POST, form_data)
	_set_ptt_state(PTTState.TRANSCRIBING, {"mic_button": _btn, "target": _field_for_filling})
	if _btn_stop != null:
		_btn_stop.disabled = false


func _StopConverting():
	stop_signal = true
	if effect.is_recording_active():
		effect.set_recording_active(false)
		print("Recording stopped")
	_stop_mic()

	if http_request:
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
func _finish_transcription(text: String) -> void:
	var active_req := _active_ptt_req

	if text.is_empty():
		_set_ptt_state(PTTState.ERROR, {"mic_button": _btn, "error_message": "Transcription failed"})
		SingletonObject.ErrorDisplay("Transcription Failed", "No text returned from STT provider")
	else:
		_set_ptt_state(PTTState.READY, {"mic_button": _btn})
		print("Transcription:", text)
		var target: Control = null
		if active_req != null:
			target = active_req.target
		else:
			target = _field_for_filling

		if target != null:
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

	SingletonObject.transcription_notification_player.play()
	transcription_completed.emit(text)
	_active_ptt_req = null


func _on_request_completed(_result, response_code, _headers, body):
	if response_code == 200:
		var response_json = JSON.parse_string(body.get_string_from_utf8())
		if response_json and response_json.has("text"):
			_finish_transcription(response_json["text"])
			return

	var err_msg := "Invalid response from Whisper API"
	if response_code != 200:
		var error_json = JSON.parse_string(body.get_string_from_utf8())
		if error_json is Dictionary and error_json.has("error") and error_json["error"].has("message"):
			err_msg = error_json["error"]["message"]
		print("Error:", response_code, "Response:", body.get_string_from_utf8())

	_finish_transcription("")
	SingletonObject.ErrorDisplay("STT Error", err_msg)
