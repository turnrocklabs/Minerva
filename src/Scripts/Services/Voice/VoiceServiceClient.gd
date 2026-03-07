class_name VoiceServiceClient
extends RefCounted
## Wraps Core WebSocket messages for the voice-service (STT, TTS, voice listing, status).
## Uses the standard Core.send_message() / AwaitMessage pattern.

const VOICE_SERVICE_ID := "voice-service"


## Transcribe audio via voice-service STT.
## Returns the transcribed text, or "" on error.
func transcribe(audio_wav: PackedByteArray, language: String = "en", backend: String = "faster-whisper") -> String:
	var service := _get_voice_service()
	if not service:
		push_error("[VoiceServiceClient] voice-service not available")
		return ""

	var action := Action.new({"topic": "voice/stt/transcribe"})
	var data := {
		"audio_base64": Marshalls.raw_to_base64(audio_wav),
		"language": language,
		"backend": backend,
	}

	var awaiter := Core.send_message(service, action, data)
	var response = await awaiter.with_timeout(120.0).receive()

	if not response:
		push_error("[VoiceServiceClient] STT request timed out")
		return ""

	var result: Dictionary = response.get("params", {}).get("result", {})
	if result.has("error"):
		push_error("[VoiceServiceClient] STT error: %s" % result.get("error"))
		return ""

	return result.get("text", "")


## Synthesize text to speech via voice-service TTS.
## Returns WAV audio as PackedByteArray, or empty on error.
func synthesize(text: String, voice_id: String = "", backend: String = "kokoro") -> PackedByteArray:
	var service := _get_voice_service()
	if not service:
		push_error("[VoiceServiceClient] voice-service not available")
		return PackedByteArray()

	var action := Action.new({"topic": "voice/tts/synthesize"})
	var data := {
		"text": text,
		"backend": backend,
	}
	if not voice_id.is_empty():
		data["voice_id"] = voice_id

	var awaiter := Core.send_message(service, action, data)
	var response = await awaiter.with_timeout(120.0).receive()

	if not response:
		push_error("[VoiceServiceClient] TTS request timed out")
		return PackedByteArray()

	var result: Dictionary = response.get("params", {}).get("result", {})
	if result.has("error"):
		push_error("[VoiceServiceClient] TTS error: %s" % result.get("error"))
		return PackedByteArray()

	var audio_b64: String = result.get("audio_base64", "")
	if audio_b64.is_empty():
		push_error("[VoiceServiceClient] TTS returned no audio")
		return PackedByteArray()

	return Marshalls.base64_to_raw(audio_b64)


## List available voices from voice-service.
## Returns array of voice dictionaries [{id, name, backend_family, capabilities}, ...].
func list_voices(backend: String = "") -> Array:
	var service := _get_voice_service()
	if not service:
		push_error("[VoiceServiceClient] voice-service not available")
		return []

	var action := Action.new({"topic": "voice/voices/list"})
	var data := {}
	if not backend.is_empty():
		data["backend"] = backend

	var awaiter := Core.send_message(service, action, data)
	var response = await awaiter.with_timeout(30.0).receive()

	if not response:
		push_error("[VoiceServiceClient] Voice list request timed out")
		return []

	var result: Dictionary = response.get("params", {}).get("result", {})
	return result.get("voices", [])


## Get voice-service health status.
func get_status() -> Dictionary:
	var service := _get_voice_service()
	if not service:
		return {"error": "voice-service not available"}

	var action := Action.new({"topic": "voice/manage/status"})
	var awaiter := Core.send_message(service, action, {})
	var response = await awaiter.with_timeout(15.0).receive()

	if not response:
		return {"error": "status request timed out"}

	return response.get("params", {}).get("result", {})


## Transcribe audio using OpenAI Whisper REST API directly (fallback).
## Returns transcribed text, or "" on error.
func transcribe_whisper(audio_wav: PackedByteArray) -> String:
	var api_key := SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI)
	if api_key.is_empty():
		push_error("[VoiceServiceClient] No OpenAI API key for Whisper fallback")
		return ""

	var http := HTTPRequest.new()
	http.use_threads = true
	Core.add_child(http)  # Need a node in tree for HTTPRequest

	var boundary := "----VoiceBoundary%s" % str(Time.get_ticks_msec())
	var form_data := PackedByteArray()

	# Model field
	form_data.append_array(("--%s\r\n" % boundary).to_ascii_buffer())
	form_data.append_array("Content-Disposition: form-data; name=\"model\"\r\n\r\n".to_ascii_buffer())
	form_data.append_array("whisper-1\r\n".to_ascii_buffer())

	# Audio file field
	form_data.append_array(("--%s\r\n" % boundary).to_ascii_buffer())
	form_data.append_array("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".to_ascii_buffer())
	form_data.append_array("Content-Type: audio/wav\r\n\r\n".to_ascii_buffer())
	form_data.append_array(audio_wav)
	form_data.append_array(("\r\n--%s--\r\n" % boundary).to_ascii_buffer())

	var headers := PackedStringArray([
		"Authorization: Bearer %s" % api_key,
		"Content-Type: multipart/form-data; boundary=%s" % boundary,
	])

	http.request_raw("https://api.openai.com/v1/audio/transcriptions", headers, HTTPClient.METHOD_POST, form_data)

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if response_code != 200:
		var err_text := body.get_string_from_utf8()
		push_error("[VoiceServiceClient] Whisper API error %d: %s" % [response_code, err_text])
		return ""

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json and json.has("text"):
		return json["text"]

	push_error("[VoiceServiceClient] Unexpected Whisper response format")
	return ""


## Transcribe using the configured provider (with automatic fallback).
func transcribe_auto(audio_wav: PackedByteArray, voice_config: VoiceConfig) -> String:
	var provider := voice_config.get_effective_stt_provider()

	if provider == VoiceConfig.STTProvider.VOICE_SERVICE:
		var result := await transcribe(audio_wav, "en", voice_config.stt_backend)
		if result.is_empty() and voice_config.whisper_fallback:
			push_warning("[VoiceServiceClient] Voice-service STT failed, falling back to Whisper")
			return await transcribe_whisper(audio_wav)
		return result
	else:
		return await transcribe_whisper(audio_wav)


## Synthesize using the configured provider. Returns WAV bytes or empty.
func synthesize_auto(text: String, voice_config: VoiceConfig) -> PackedByteArray:
	var provider := voice_config.get_effective_tts_provider()

	if provider == VoiceConfig.TTSProvider.VOICE_SERVICE:
		return await synthesize(text, voice_config.voice_id, voice_config.tts_backend)
	else:
		return PackedByteArray()


## Find or create a Service object for voice-service
func _get_voice_service() -> Service:
	if not Core.client._connected:
		return null

	# Check cached services first
	for svc in Core.services:
		if svc.client_id == VOICE_SERVICE_ID:
			return svc

	# Create a minimal Service object — Core routes by client_id/target_service_id
	return Service.new({"client_id": VOICE_SERVICE_ID, "name": "Voice Service"})
