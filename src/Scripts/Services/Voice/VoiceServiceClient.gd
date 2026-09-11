class_name VoiceServiceClient
extends RefCounted
## Wraps Core WebSocket messages for the voice-service (STT, TTS, voice listing, status).
## Uses the standard Core.send_message() / AwaitMessage pattern.

const VOICE_SERVICE_ID := "voice-service"
## Successful discovery is cached per exact backend filter and connection lifetime.
var _voice_inventories: Dictionary = {}
var _inventory_client: CoreClient
var _inventory_epoch := 0
var _query_sequence := 0
var _query_versions: Dictionary = {}
var _inventory_versions: Dictionary = {}

static func failure(code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "error": message}

func _clear_inventory() -> void:
	_inventory_epoch += 1
	_voice_inventories.clear()
	_query_versions.clear()
	_inventory_versions.clear()

func _bind_inventory_connection() -> void:
	if _inventory_client == Core.client:
		return
	if is_instance_valid(_inventory_client) and _inventory_client.connection_closed.is_connected(_clear_inventory):
		_inventory_client.connection_closed.disconnect(_clear_inventory)
	_clear_inventory()
	_inventory_client = Core.client
	if is_instance_valid(_inventory_client):
		_inventory_client.connection_closed.connect(_clear_inventory)

func _call(topic: String, data: Dictionary, mode: String, timeout: float, operation: VoiceOperation = null, service: Service = null) -> Dictionary:
	if operation != null and not operation.can_start():
		return failure("cancelled", "Voice operation cancelled locally.")
	if operation != null and operation.is_busy():
		return failure("operation_busy", "Voice operation already has an active request.")
	if service == null:
		service = _get_voice_service()
	if service == null:
		return failure("core_offline", "Voice service requires a connected Core session.")
	var request := Core.send_message(service, Action.new({"topic": topic}), data, mode, timeout)
	var completed: Dictionary = await operation.receive(request) if operation != null else await request.receive_result()
	if not completed.success:
		completed["error"] = completed.error_message
		return completed
	if completed.kind == "binary":
		return {"success": true, "audio": completed.binary, "request_id": completed.request_id, "transport": "binary"}
	var params: Variant = completed.json.get("params", {})
	var body: Variant = params.get("result") if params is Dictionary else null
	if not body is Dictionary:
		return failure("invalid_voice_response", "Voice service returned a non-object result.")
	return {"success": true, "value": body, "request_id": completed.request_id, "transport": "json"}

func transcribe_result(audio_wav: PackedByteArray, language: String = "en", backend: String = "faster-whisper", model: String = "", operation: VoiceOperation = null) -> Dictionary:
	var data := {"audio_base64": Marshalls.raw_to_base64(audio_wav), "language": language, "backend": backend}
	if not model.is_empty():
		data["model"] = model
	var result := await _call("voice/stt/transcribe", data, "json", 120.0, operation)
	if result.success:
		if not result.value.get("text") is String:
			return failure("invalid_voice_response", "Transcription response is missing text.")
		result["text"] = result.value.text
	return result

func transcribe(audio_wav: PackedByteArray, language: String = "en", backend: String = "faster-whisper", model: String = "") -> String:
	var result := await transcribe_result(audio_wav, language, backend, model)
	return result.get("text", "")

func _inventory_for(backend: String) -> Dictionary:
	_bind_inventory_connection()
	var key := backend
	if _voice_inventories.has("") and int(_inventory_versions.get("", -1)) > int(_inventory_versions.get(key, -1)):
		key = ""
	return {"voices": _voice_inventories[key]} if _voice_inventories.has(key) else {}

func _check_known_voice(voice: String, backend: String) -> Dictionary:
	var inventory := _inventory_for(backend)
	if voice.is_empty() or inventory.is_empty():
		return {"success": true, "metadata_mode": "legacy"}
	var voices: Array = inventory.voices
	var has_name := false
	for entry: Dictionary in voices:
		if entry.get("name") == voice:
			has_name = true
	return VoiceSelection.resolve(voices, voice if has_name else "", "" if has_name else voice, backend)

func synthesize_result(text: String, voice: String = "", backend: String = "kokoro", operation: VoiceOperation = null) -> Dictionary:
	var selection := _check_known_voice(voice, backend)
	if not selection.success:
		return selection
	var data := {"text": text, "backend": backend}
	if not voice.is_empty():
		data["voice_id"] = voice
	var result := await _call("voice/tts/synthesize", data, "either", 120.0, operation)
	if not result.success:
		return result
	if result.transport == "json":
		var encoded: Variant = result.value.get("audio_base64")
		if not encoded is String:
			return failure("invalid_voice_response", "Synthesis response is missing audio.")
		result["audio"] = Marshalls.base64_to_raw(encoded)
	if result.audio.is_empty():
		return failure("empty_audio", "Synthesis returned no audio.")
	if decode_audio(result.audio) == null:
		return failure("invalid_audio", "Synthesis audio could not be decoded.")
	result["metadata_mode"] = selection.get("metadata_mode", "legacy")
	return result

func synthesize(text: String, voice_id: String = "", backend: String = "kokoro") -> PackedByteArray:
	var result := await synthesize_result(text, voice_id, backend)
	return result.get("audio", PackedByteArray())

func list_voices_result(backend: String = "", operation: VoiceOperation = null) -> Dictionary:
	_bind_inventory_connection()
	var connected_client := Core.client
	var epoch := _inventory_epoch
	_query_sequence += 1
	var sequence := _query_sequence
	_query_versions[backend] = sequence
	var data := {} if backend.is_empty() else {"backend": backend}
	var result := await _call("voice/voices/list", data, "json", 30.0, operation)
	if not result.success:
		return result
	var voices: Variant = result.value.get("voices")
	if not voices is Array:
		return failure("invalid_voice_response", "Voice discovery response is missing its voice list.")
	for voice: Variant in voices:
		if not voice is Dictionary or not voice.get("id") is String or not voice.get("name") is String:
			return failure("invalid_voice_response", "Voice discovery contains a malformed identity.")
	if connected_client == Core.client and Core.client._connected and epoch == _inventory_epoch and _query_versions.get(backend) == sequence:
		_voice_inventories[backend] = voices.duplicate(true)
		_inventory_versions[backend] = sequence
	return {"success": true, "voices": voices, "count": voices.size(), "backend_filter": backend}

func list_voices(backend: String = "") -> Array:
	var result := await list_voices_result(backend)
	return result.get("voices", [])

func get_status_result(operation: VoiceOperation = null) -> Dictionary:
	var result := await _call("voice/manage/status", {}, "json", 15.0, operation)
	if result.success:
		result["status"] = result.value
	return result

func get_status() -> Dictionary:
	var result := await get_status_result()
	return result.status if result.success else result


## Transcribe audio using OpenAI Whisper REST API directly (fallback).
## Returns transcribed text, or "" on error.
func transcribe_whisper_result(audio_wav: PackedByteArray) -> Dictionary:
	var api_key := SingletonObject.preferences_popup.get_api_key(SingletonObject.API_PROVIDER.OPENAI)
	if api_key.is_empty():
		push_error("[VoiceServiceClient] No OpenAI API key for Whisper fallback")
		return failure("whisper_failed", "OpenAI Whisper transcription failed.")

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

	var send_error := http.request_raw("https://api.openai.com/v1/audio/transcriptions", headers, HTTPClient.METHOD_POST, form_data)
	if send_error != OK:
		http.queue_free()
		return failure("send_failed", "Could not send Whisper transcription request.")

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if response_code != 200:
		var err_text := body.get_string_from_utf8()
		push_error("[VoiceServiceClient] Whisper API error %d: %s" % [response_code, err_text])
		return failure("whisper_failed", "OpenAI Whisper transcription failed.")

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json is Dictionary and json.get("text") is String:
		return {"success": true, "text": json.text}

	push_error("[VoiceServiceClient] Unexpected Whisper response format")
	return failure("whisper_failed", "OpenAI Whisper transcription failed.")


func transcribe_whisper(audio_wav: PackedByteArray) -> String:
	var result := await transcribe_whisper_result(audio_wav)
	return result.get("text", "")


## Transcribe using the configured provider (with automatic fallback).
func transcribe_auto_result(audio_wav: PackedByteArray, voice_config: VoiceConfig, operation: VoiceOperation = null) -> Dictionary:
	if operation != null and not operation.can_start():
		return failure("cancelled", "Transcription cancelled locally.")
	if operation != null and operation.is_busy():
		return failure("operation_busy", "Voice operation already has an active request.")
	if voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE:
		var result := await transcribe_result(audio_wav, "en", voice_config.stt_backend, voice_config.stt_model, operation)
		if result.success or result.get("error_code") in ["cancelled", "operation_busy"] or not voice_config.whisper_fallback:
			return result
		return await transcribe_whisper_result(audio_wav)
	return await transcribe_whisper_result(audio_wav)

func transcribe_auto(audio_wav: PackedByteArray, voice_config: VoiceConfig) -> String:
	var result := await transcribe_auto_result(audio_wav, voice_config)
	return result.get("text", "")

func synthesize_auto_result(text: String, voice_config: VoiceConfig, operation: VoiceOperation = null) -> Dictionary:
	if voice_config.tts_provider != VoiceConfig.TTSProvider.VOICE_SERVICE:
		return failure("voice_disabled", "Speech synthesis is disabled.")
	var voice: String = voice_config.voice_name if not voice_config.voice_name.is_empty() else voice_config.voice_id
	var inventory := _inventory_for(voice_config.tts_backend)
	if not inventory.is_empty() and (not voice_config.voice_name.is_empty() or not voice_config.voice_id.is_empty()):
		var selection := VoiceSelection.resolve(inventory.voices, voice_config.voice_name, voice_config.voice_id, voice_config.tts_backend)
		if not selection.success:
			return selection
	return await synthesize_result(text, voice, voice_config.tts_backend, operation)

func synthesize_auto(text: String, voice_config: VoiceConfig) -> PackedByteArray:
	var result := await synthesize_auto_result(text, voice_config)
	return result.get("audio", PackedByteArray())


## Summarize a user+response exchange into a single spoken sentence using a fast model via model-chat.
## Returns the summary text, or the original response (truncated) on failure.
func summarize_for_speech_result(user_text: String, response_text: String, model_name: String, timeout: float = 30.0, operation: VoiceOperation = null) -> Dictionary:
	if operation != null and not operation.can_start():
		return failure("cancelled", "Speech summary cancelled locally.")
	if operation != null and operation.is_busy():
		return failure("operation_busy", "Voice operation already has an active request.")
	var matched := CoreModelCatalog.resolve({"kind": "core_action", "service_client_id": "model-chat", "action_name": model_name})
	if not matched.success:
		return _summary_fallback(response_text, matched)
	var model_chat_svc: Service = matched.service
	var model_action: Action = matched.action

	var cfg := SingletonObject.get_voice_config()
	var system_prompt: String = cfg.summary_prompt if not cfg.summary_prompt.is_empty() else VoiceConfig.DEFAULT_SUMMARY_PROMPT
	var messages: Array = [
		{"role": "system", "content": system_prompt},
		{"role": "user", "content": "User said: %s\n\nAssistant replied: %s" % [user_text, response_text]},
	]

	var msg_data: Dictionary = {
		"messages": messages,
		"temperature": 0.7,
		"max_tokens": cfg.summary_max_tokens,
		"options": {"num_ctx": 4000},
	}

	var provider := CoreProvider.new(model_chat_svc, model_action)
	var prepared := provider.build_chat_payload(messages, msg_data)
	provider.free()
	if not prepared.success:
		return _summary_fallback(response_text, prepared)
	var result := await _call(model_action.topic, prepared.payload, "json", timeout, operation, model_chat_svc)
	if not result.success:
		return result if result.get("error_code") in ["cancelled", "operation_busy"] else _summary_fallback(response_text, result)
	var choices: Variant = result.value.get("choices")
	if choices is Array and not choices.is_empty() and choices[0] is Dictionary:
		var message: Variant = choices[0].get("message")
		if message is Dictionary and message.get("content") is String and not message.content.is_empty():
			return {"success": true, "text": message.content}
	return _summary_fallback(response_text, failure("invalid_summary", "Summary model returned no text."))

func _summary_fallback(response_text: String, cause: Dictionary) -> Dictionary:
	return {"success": true, "text": response_text.substr(0, 200), "fallback_reason": cause.get("error_code", "summary_unavailable"), "fallback_message": cause.get("error_message", cause.get("error", "Summary unavailable."))}

func summarize_for_speech(user_text: String, response_text: String, model_name: String, timeout: float = 30.0) -> String:
	var result := await summarize_for_speech_result(user_text, response_text, model_name, timeout)
	return result.get("text", "")


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


## Load audio bytes (WAV or raw PCM) into an AudioStreamWAV.
## Handles both RIFF WAV containers and raw s16le PCM from voice-container.
static func decode_audio(audio_bytes: PackedByteArray) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	load_audio_into_stream(stream, audio_bytes)
	return stream if not stream.data.is_empty() else null

static func load_audio_into_stream(stream: AudioStreamWAV, audio_bytes: PackedByteArray) -> void:
	if audio_bytes.size() < 4:
		return

	var header := audio_bytes.slice(0, 4).get_string_from_ascii()
	if header == "RIFF" and audio_bytes.size() >= 44:
		# Standard WAV: parse header
		var channels := audio_bytes.decode_u16(22)
		var sample_rate := audio_bytes.decode_u32(24)
		var bits_per_sample := audio_bytes.decode_u16(34)

		# Find data chunk
		var data_offset := 12
		while data_offset + 8 < audio_bytes.size():
			var chunk_id := audio_bytes.slice(data_offset, data_offset + 4).get_string_from_ascii()
			var chunk_size := audio_bytes.decode_u32(data_offset + 4)
			if chunk_id == "data":
				data_offset += 8
				stream.data = audio_bytes.slice(data_offset, data_offset + chunk_size)
				break
			data_offset += 8 + chunk_size

		stream.mix_rate = sample_rate
		stream.stereo = channels == 2
		match bits_per_sample:
			8: stream.format = AudioStreamWAV.FORMAT_8_BITS
			16: stream.format = AudioStreamWAV.FORMAT_16_BITS
			_: stream.format = AudioStreamWAV.FORMAT_16_BITS
	else:
		# Raw PCM: assume s16le mono 16kHz (voice-container default output)
		stream.data = audio_bytes
		stream.mix_rate = 16000
		stream.stereo = false
		stream.format = AudioStreamWAV.FORMAT_16_BITS


## Send pre-warm request to gpu-dispatch to load STT/TTS/LLM models.
## Eliminates cold start on first voice interaction.
func pre_warm(keep_warm_seconds: int = 3600) -> bool:
	if not Core.client._connected:
		push_warning("[VoiceServiceClient] Cannot pre-warm: Core not connected")
		return false

	var gpu_dispatch := Service.new({"client_id": "gpu-dispatch", "name": "GPU Dispatch"})
	var action := Action.new({"topic": "gpu-dispatch/session/reserve"})
	var cfg := SingletonObject.get_voice_config()
	var data := {
		"job_types": ["voice", "chat"],
		"containers": ["voice", "ollama"],
		"models": {
			"stt": {"model": cfg.stt_model, "backend": cfg.stt_backend},
			"tts": {"backend": cfg.tts_backend},
			"llm": {},
		},
		"keep_warm_seconds": keep_warm_seconds,
	}

	print("[VoiceServiceClient] Sending pre-warm request to gpu-dispatch...")
	var awaiter := Core.send_message(gpu_dispatch, action, data)
	var response = await awaiter.with_timeout(30.0).receive()

	if response:
		var result: Dictionary = response.get("params", {}).get("result", {})
		var node_id: String = result.get("node_id", "")
		if not node_id.is_empty():
			print("[VoiceServiceClient] Pre-warm reserved node: %s" % node_id)
			return true
		var error: String = result.get("error", response.get("params", {}).get("error", ""))
		if not error.is_empty():
			push_warning("[VoiceServiceClient] Pre-warm failed: %s" % error)
	else:
		push_warning("[VoiceServiceClient] Pre-warm request timed out")

	return false
