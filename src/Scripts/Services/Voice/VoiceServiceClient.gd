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

	print("[VoiceServiceClient] TTS: sending request (text=%d chars, voice=%s, backend=%s)" % [text.length(), voice_id, backend])

	# Send via standard Core.send_message — also check for binary audio delivery
	var awaiter := Core.send_message(service, action, data)
	var req_id: String = awaiter.request_id

	# Start a background poll for binary audio while awaiter waits for JSON
	# voice-service may send binary frames WITHOUT a JSON response
	var binary_received := false
	var binary_audio := PackedByteArray()

	# Short timeout on JSON response — if binary comes instead, we'll catch it
	var response = await awaiter.with_timeout(30.0).receive()

	# Check if binary audio arrived during the await
	if not req_id.is_empty():
		binary_audio = Core.client.take_voice_binary(req_id)
	if not binary_audio.is_empty():
		print("[VoiceServiceClient] TTS: got %d bytes via binary transfer" % binary_audio.size())
		return binary_audio

	# JSON response path
	if response:
		var result: Dictionary = response.get("params", {}).get("result", {})
		if result.has("error"):
			push_error("[VoiceServiceClient] TTS error: %s" % result.get("error"))
			return PackedByteArray()

		# Check binary again (may have arrived just after JSON)
		if not req_id.is_empty():
			binary_audio = Core.client.take_voice_binary(req_id)
		if not binary_audio.is_empty():
			print("[VoiceServiceClient] TTS: got %d bytes via binary transfer (after JSON)" % binary_audio.size())
			return binary_audio

		var audio_b64: String = result.get("audio_base64", "")
		if not audio_b64.is_empty():
			print("[VoiceServiceClient] TTS: got base64 audio (%d chars)" % audio_b64.length())
			return Marshalls.base64_to_raw(audio_b64)

		# No audio in JSON — binary may still be arriving, poll briefly
		for _i in range(50):  # up to 5 seconds
			binary_audio = Core.client.take_voice_binary(req_id)
			if not binary_audio.is_empty():
				print("[VoiceServiceClient] TTS: got %d bytes via binary (polled)" % binary_audio.size())
				return binary_audio
			await Core.get_tree().create_timer(0.1).timeout

	else:
		# JSON timed out — check if binary arrived instead
		print("[VoiceServiceClient] TTS: JSON timed out, checking binary...")
		if not req_id.is_empty():
			# Poll for binary with remaining patience
			for _i in range(900):  # up to 90 more seconds
				binary_audio = Core.client.take_voice_binary(req_id)
				if not binary_audio.is_empty():
					print("[VoiceServiceClient] TTS: got %d bytes via binary (after JSON timeout)" % binary_audio.size())
					return binary_audio
				await Core.get_tree().create_timer(0.1).timeout

	push_error("[VoiceServiceClient] TTS: no audio received")
	return PackedByteArray()


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


## Summarize a user+response exchange into a single spoken sentence using a fast model via model-chat.
## Returns the summary text, or the original response (truncated) on failure.
func summarize_for_speech(user_text: String, response_text: String, model_name: String, timeout: float = 30.0) -> String:
	if not Core.client._connected:
		return response_text.substr(0, 200)

	# Find model-chat service and the matching action for the requested model
	var model_chat_svc: Service = null
	var model_action: Action = null
	for svc in Core.services:
		if svc.client_id == "model-chat":
			model_chat_svc = svc
			for act in svc.actions:
				if act.name == model_name:
					model_action = act
					break
			break

	if not model_chat_svc or not model_action:
		push_warning("[VoiceServiceClient] model-chat model '%s' not found for summarization" % model_name)
		return response_text.substr(0, 200)

	var messages: Array = [
		{"role": "system", "content": "Summarize this conversation exchange into a single conversational sentence suitable for speaking aloud. Be concise and natural."},
		{"role": "user", "content": "User said: %s\n\nAssistant replied: %s" % [user_text, response_text]},
	]

	var msg_data: Dictionary = {
		"messages": messages,
		"temperature": 0.7,
		"max_tokens": 150,
		"options": {"num_ctx": 4000},
	}

	var awaiter := Core.send_message(model_chat_svc, model_action, msg_data)
	var response = await awaiter.with_timeout(timeout).receive()

	if not response:
		push_warning("[VoiceServiceClient] Summarization timed out")
		return response_text.substr(0, 200)

	var result: Dictionary = response.get("params", {}).get("result", {})
	if result.has("choices"):
		var choices: Array = result.get("choices", [])
		if not choices.is_empty():
			var message: Dictionary = choices[0].get("message", {})
			var content: String = message.get("content", "")
			if not content.is_empty():
				return content

	push_warning("[VoiceServiceClient] Summarization returned unexpected format")
	return response_text.substr(0, 200)


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
