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
var _stt_sequence := 0
var _tts_sequence := 0

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

func transcribe_result(audio_wav: PackedByteArray, language: String = "en", backend: String = "faster-whisper", model: String = "", operation: VoiceOperation = null, diagnostic_id: String = "") -> Dictionary:
	var started_msec := Time.get_ticks_msec()
	diagnostic_id = _ensure_stt_diagnostic_id(operation, diagnostic_id)
	var data := {"audio_base64": Marshalls.raw_to_base64(audio_wav), "language": language, "backend": backend}
	if not model.is_empty():
		data["model"] = model
	var result := await _call("voice/stt/transcribe", data, "json", 120.0, operation)
	if result.success:
		if not result.value.get("text") is String:
			result = failure("invalid_voice_response", "Transcription response is missing text.")
			_log_stt_result(diagnostic_id, "core", started_msec, audio_wav.size(), backend, model, result)
			return result
		result["text"] = result.value.text
	_log_stt_result(diagnostic_id, "core", started_msec, audio_wav.size(), backend, model, result)
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
	var started_msec := Time.get_ticks_msec()
	var diagnostic_id := _ensure_stt_diagnostic_id(operation)
	if operation != null and not operation.can_start():
		var cancelled := failure("cancelled", "Transcription cancelled locally.")
		_log_stt_result(diagnostic_id, "total", started_msec, audio_wav.size(), voice_config.stt_backend, voice_config.stt_model, cancelled)
		return cancelled
	if operation != null and operation.is_busy():
		var busy := failure("operation_busy", "Voice operation already has an active request.")
		_log_stt_result(diagnostic_id, "total", started_msec, audio_wav.size(), voice_config.stt_backend, voice_config.stt_model, busy)
		return busy
	if voice_config.stt_provider == VoiceConfig.STTProvider.VOICE_SERVICE:
		var result := await transcribe_result(audio_wav, "en", voice_config.stt_backend, voice_config.stt_model, operation, diagnostic_id)
		if result.success or result.get("error_code") in ["cancelled", "operation_busy"] or not voice_config.whisper_fallback:
			_log_stt_result(diagnostic_id, "total", started_msec, audio_wav.size(), voice_config.stt_backend, voice_config.stt_model, result)
			return result
		var fallback := await transcribe_whisper_result(audio_wav)
		fallback["fallback_from"] = result.get("error_code", "core_stt_failed")
		_log_stt_result(diagnostic_id, "total_after_fallback", started_msec, audio_wav.size(), "openai", "whisper-1", fallback)
		return fallback
	var whisper := await transcribe_whisper_result(audio_wav)
	_log_stt_result(diagnostic_id, "whisper", started_msec, audio_wav.size(), "openai", "whisper-1", whisper)
	return whisper


func _ensure_stt_diagnostic_id(operation: VoiceOperation, existing: String = "") -> String:
	if not existing.is_empty():
		return existing
	if operation != null and not operation.diagnostic_id.is_empty():
		return operation.diagnostic_id
	_stt_sequence += 1
	var assigned := "stt-%d" % _stt_sequence
	if operation != null:
		operation.diagnostic_id = assigned
	return assigned


## Content-free timing landmark for diagnosing capture-to-transcript latency.
func _log_stt_result(diagnostic_id: String, stage: String, started_msec: int, audio_bytes: int, backend: String, model: String, outcome: Dictionary) -> void:
	var elapsed_msec := Time.get_ticks_msec() - started_msec
	var status := "success" if outcome.get("success", false) else str(outcome.get("error_code", "error"))
	print("[VoiceSTT] operation=%s stage=%s elapsed_ms=%d audio_bytes=%d backend=%s model=%s status=%s fallback_from=%s" % [
		diagnostic_id, stage, elapsed_msec, audio_bytes, backend, model if not model.is_empty() else "default", status,
		str(outcome.get("fallback_from", "none"))])

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

func synthesize_auto_playback_result(text: String, voice_config: VoiceConfig, operation: SpeechOperation, player: AudioStreamPlayer) -> Dictionary:
	if voice_config.tts_provider != VoiceConfig.TTSProvider.VOICE_SERVICE:
		return failure("voice_disabled", "Speech synthesis is disabled.")
	if not operation.can_start():
		return failure("cancelled", "Speech operation is already cancelled.")
	if operation.is_busy():
		return failure("operation_busy", "Speech operation already owns a request.")
	if not is_instance_valid(player):
		return failure("no_audio_player", "Speech player is unavailable.")
	var voice: String = voice_config.voice_name if not voice_config.voice_name.is_empty() else voice_config.voice_id
	var inventory := _inventory_for(voice_config.tts_backend)
	if not inventory.is_empty() and not voice.is_empty():
		var selection := VoiceSelection.resolve(inventory.voices, voice_config.voice_name, voice_config.voice_id, voice_config.tts_backend)
		if not selection.success:
			return selection
	# The streaming backend requires an explicit voice. Preserve the legacy
	# server-default path through the existing one-shot request when it is empty.
	if voice.is_empty():
		return await _play_one_shot(text, voice, voice_config.tts_backend, operation, player, voice_config.tts_volume)
	var service := _get_voice_service()
	if service == null:
		return failure("core_offline", "Voice service requires a connected Core session.")
	var action: Action
	for candidate: Action in service.actions:
		if candidate.topic == "voice/tts/stream":
			action = candidate
			break
	if action == null:
		_tts_sequence += 1
		_log_tts("tts-%d" % _tts_sequence, "not_advertised", Time.get_ticks_msec(), voice_config.tts_backend, "oneshot")
		return await _play_one_shot(text, voice, voice_config.tts_backend, operation, player, voice_config.tts_volume)
	var data := {"text": text, "voice_id": voice, "backend": voice_config.tts_backend}
	var request = Core.prepare_audio_stream(service, action, 120.0)
	_tts_sequence += 1
	var diagnostic_id := "tts-%d" % _tts_sequence
	var started_msec := Time.get_ticks_msec()
	var metrics := {"first": false, "bytes": 0, "rate": 0, "format": "unknown"}
	_log_tts(diagnostic_id, "request", started_msec, voice_config.tts_backend, "pending")
	var prepared: Dictionary = operation.prepare_stream(request, player, voice_config.tts_volume)
	if not prepared.success:
		request.fail(str(prepared.get("error_code", "operation_rejected")), str(prepared.get("error_message", "Speech operation rejected streaming.")))
		return prepared
	var on_open := func(meta: Dictionary):
		metrics.rate = int(meta.sample_rate)
		metrics.format = str(meta.format)
		_log_tts(diagnostic_id, "open", started_msec, voice_config.tts_backend, "success", metrics.bytes, metrics.rate, metrics.format)
	var on_chunk := func(audio: PackedByteArray):
		metrics.bytes += audio.size()
		if not metrics.first:
			metrics.first = true
			_log_tts(diagnostic_id, "first_chunk", started_msec, voice_config.tts_backend, "success", metrics.bytes, metrics.rate, metrics.format)
	var on_end := func(): _log_tts(diagnostic_id, "input_end", started_msec, voice_config.tts_backend, "success", metrics.bytes, metrics.rate, metrics.format)
	var on_playback := func(): _log_tts(diagnostic_id, "playback", started_msec, voice_config.tts_backend, "success", metrics.bytes, metrics.rate, metrics.format)
	request.stream_opened.connect(on_open, CONNECT_ONE_SHOT)
	request.stream_chunk.connect(on_chunk)
	request.stream_ended.connect(on_end, CONNECT_ONE_SHOT)
	operation.playback_began.connect(on_playback, CONNECT_ONE_SHOT)
	operation.finished.connect(func(outcome: Dictionary): _log_tts(diagnostic_id, "done", started_msec, voice_config.tts_backend, "success" if outcome.get("success", false) else str(outcome.get("error_code", "error")), metrics.bytes, metrics.rate, metrics.format), CONNECT_ONE_SHOT)
	# Every consumer is attached before send; local transports may reply inline.
	Core.send_prepared_audio_stream(request, service, action, data)
	var result: Dictionary = await operation.receive_prepared_stream(request)
	for pair in [[request.stream_opened, on_open], [request.stream_chunk, on_chunk], [request.stream_ended, on_end], [operation.playback_began, on_playback]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	if result.success:
		return {"success": true, "streaming": true}
	if request.header_id.is_empty() and not operation.playback_started and result.get("error_code") in ["UNKNOWN_TOPIC", "UNKNOWN_ACTION"] and operation.can_start():
		_log_tts(diagnostic_id, "fallback_unsupported", started_msec, voice_config.tts_backend, str(result.error_code))
		return await _play_one_shot(text, voice, voice_config.tts_backend, operation, player, voice_config.tts_volume)
	return result

func _play_one_shot(text: String, voice: String, backend: String, operation: SpeechOperation, player: AudioStreamPlayer, volume: float) -> Dictionary:
	var synthesized := await synthesize_result(text, voice, backend, operation)
	if not synthesized.success:
		return synthesized
	if not operation.play(player, synthesized.audio, volume):
		return failure("playback_failed", "Speech playback could not start.")
	return {"success": true, "streaming": false}

func _log_tts(diagnostic_id: String, stage: String, started_msec: int, backend: String, status: String, audio_bytes := 0, sample_rate := 0, audio_format := "unknown") -> void:
	print("[VoiceTTS] operation=%s stage=%s elapsed_ms=%d audio_bytes=%d sample_rate=%d format=%s backend=%s status=%s" % [diagnostic_id, stage, Time.get_ticks_msec() - started_msec, audio_bytes, sample_rate, audio_format, backend, status])

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
