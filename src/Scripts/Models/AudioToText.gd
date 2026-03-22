class_name AudioToTexts
extends Node

var effect
var recording
var file_path = "res://VoiceAudio.wav"

var btn: Button
var btnStop: Button
var is_converting: bool = false
var http_request

const WHISPER_API_URL = "https://api.openai.com/v1/audio/transcriptions"

var FieldForFilling  # TextEdit or LineEdit — untyped for flexibility

var stop_signal: bool = false

var mic_player: AudioStreamPlayer

## Signal emitted when transcription completes (for push-to-talk and other consumers).
## text is the transcribed string, empty on error.
signal transcription_completed(text: String)


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


## Start/stop recording toggle. Routes STT based on VoiceConfig provider selection.
func _StartConverting():
	stop_signal = false
	if effect.is_recording_active():
		# Stop recording and get WAV data
		if btn:
			btn.modulate = Color.WHITE
		recording = effect.get_recording()
		effect.set_recording_active(false)
		_stop_mic()
		recording.save_to_wav(file_path)

		var wav_bytes := _read_wav_file()
		if wav_bytes.is_empty():
			return ERR_INVALID_DATA

		if stop_signal:
			print("Conversion stopped")
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
	if btn:
		btn.disabled = true
		btn.icon = ResourceLoader.load("res://assets/icons/loading_white-16-16.png")
	if btnStop != null:
		btnStop.disabled = false

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
	if btn:
		btn.disabled = true
		btn.icon = ResourceLoader.load("res://assets/icons/loading_white-16-16.png")
	if btnStop != null:
		btnStop.disabled = false


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

	if btn:
		btn.disabled = false
		btn.modulate = Color.WHITE
		btn.icon = ResourceLoader.load("res://assets/icons/mic_icons/microphone_24.png")
	if btnStop != null:
		btnStop.disabled = true


## Shared completion handler — fills text field and emits signal.
func _finish_transcription(text: String) -> void:
	if btn:
		btn.disabled = false
		btn.modulate = Color.WHITE
		btn.icon = ResourceLoader.load("res://assets/icons/mic_icons/microphone_24.png")

	if text.is_empty():
		SingletonObject.ErrorDisplay("Transcription Failed", "No text returned from STT provider")
	else:
		print("Transcription:", text)
		if FieldForFilling:
			FieldForFilling.text += " " + text

	SingletonObject.transcription_notification_player.play()
	transcription_completed.emit(text)


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
