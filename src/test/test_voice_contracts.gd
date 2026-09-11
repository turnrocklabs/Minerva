extends SceneTree
## Adapter outcomes, actual speech controller cancellation and durable voice selection.
var _passed := 0
var _failed := 0
var _completed := false

func _init() -> void:
	await process_frame
	await process_frame
	await _run()
	check("whole voice scenario completed", _completed)
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)

func _capture(client, method: String, args: Array, output: Dictionary) -> void:
	output.result = await client.callv(method, args)

func _last_id(client) -> String:
	return client.sent.back().params.request_id

func _deliver_binary(client, request_id: String, audio: PackedByteArray) -> void:
	var stream := PackedByteArray()
	stream.resize(16)
	stream.encode_u32(0, 777)
	var json := JSON.stringify({"cmd": "response", "topic": "voice/tts/synthesize", "params": {"request_id": request_id}}).to_utf8_buffer()
	var sizes := PackedByteArray()
	sizes.resize(8)
	sizes.encode_u32(0, json.size())
	sizes.encode_u32(4, 1)
	client._handle_binary_frame(PackedByteArray([0]) + stream + sizes + json)
	var path := "voice.wav".to_utf8_buffer()
	sizes.encode_u32(0, path.size())
	sizes.encode_u32(4, audio.size())
	client._handle_binary_frame(PackedByteArray([1]) + stream + sizes + path)
	client._handle_binary_frame(PackedByteArray([2]) + stream + audio)
	client._handle_binary_frame(PackedByteArray([3]) + stream)

func _run() -> void:
	var core = root.get_node("Core")
	var so = root.get_node("SingletonObject")
	var saved := {"client": core.client, "registered": core.registered, "services": core.services.duplicate(), "voice": so.voice_client, "config": so.voice_config, "enabled": so._enabled_providers.duplicate(), "file": so.config_file, "path": so._config_file_name, "chats": so.Chats, "verbose": so.verbose_logging}
	so.verbose_logging = false
	so.config_file = ConfigFile.new()
	so._config_file_name = "/tmp/minerva-t8-voice.cfg"
	var transport = load("res://test/fixtures/core_lifecycle_client.gd").new()
	root.add_child(transport)
	core.client = transport
	core.registered = true
	var voice = load("res://test/fixtures/voice_outcome_client.gd").new()
	so.voice_client = voice
	var config = load("res://Scripts/Services/Voice/VoiceConfig.gd").new()
	so.voice_config = config
	var scope_script = load("res://Scripts/Services/Voice/VoiceOperation.gd")
	var selection = load("res://Scripts/Services/Voice/VoiceSelection.gd")
	var bytes := PackedByteArray([0, 1, 2, 3])
	var output := {}
	_capture(voice, "transcribe_auto_result", [bytes, config], output)
	transport.reply(_last_id(transport), {"text": ""})
	check("successful STT silence stays successful without paid fallback", output.result.success and output.result.text == "" and voice.whisper_calls == 0)
	var ptt = load("res://test/fixtures/voice_ptt.gd").new()
	root.add_child(ptt)
	var target := LineEdit.new()
	ptt.add_child(target)
	target.text = "keep existing text"
	ptt._field_for_filling = target
	ptt._start_voice_service_stt(bytes, config)
	transport.reply(_last_id(transport), {"text": ""})
	check("PTT silence returns READY without changing target text", ptt.ptt_state == ptt.PTTState.READY and target.text == "keep existing text" and voice.whisper_calls == 0)
	var completed_text: Array[String] = []
	ptt.transcription_completed.connect(func(text: String): completed_text.append(text))
	ptt._start_voice_service_stt(bytes, config)
	var stopped_ptt_id := _last_id(transport)
	ptt._StopConverting()
	var next_target := LineEdit.new()
	ptt.add_child(next_target)
	var req = ptt.PTTRequest.new()
	req.target = next_target
	ptt.start_ptt(req)
	ptt._start_voice_service_stt(bytes, config)
	var current_ptt_id := _last_id(transport)
	transport.reply(stopped_ptt_id, {"text": "stale words"})
	check("stopped PTT cannot insert into a replacement target or complete it", next_target.text.is_empty() and completed_text.is_empty() and ptt.ptt_state == ptt.PTTState.TRANSCRIBING and not transport._pending_requests.has(stopped_ptt_id))
	transport.reply(current_ptt_id, {"text": "current words"})
	check("replacement PTT completes only its own target", next_target.text == "current words" and completed_text == ["current words"] and target.text == "keep existing text")
	ptt._start_voice_service_stt(bytes, config)
	next_target.free()
	transport.reply(_last_id(transport), {"text": "no live target"})
	check("freed PTT target does not prevent terminal cleanup", ptt._voice_operation == null and ptt.ptt_state == ptt.PTTState.READY and completed_text == ["current words", "no live target"])
	ptt._start_voice_service_stt(bytes, config)
	ptt.free()
	check("PTT teardown cancels its pending Core request", transport._pending_requests.is_empty())
	output.clear()
	_capture(voice, "transcribe_auto_result", [bytes, config], output)
	transport.reply(_last_id(transport), {"error": "backend failed"})
	check("configured Whisper fallback still handles actual STT failure", output.result.success and output.result.text == "fallback" and voice.whisper_calls == 1)
	output.clear()
	var stt_scope = scope_script.new()
	_capture(voice, "transcribe_auto_result", [bytes, config, stt_scope], output)
	stt_scope.cancel()
	check("cancelled STT never invokes fallback", output.result.error_code == "cancelled" and voice.whisper_calls == 1)
	output.clear()
	_capture(voice, "get_status_result", [], output)
	transport.reply(_last_id(transport), {})
	check("empty status object is a valid result", output.result.success and output.result.status.is_empty())
	output.clear()
	_capture(voice, "synthesize_result", ["binary only"], output)
	_deliver_binary(transport, _last_id(transport), bytes)
	check("binary-only TTS returns immediately with owned audio", output.result.success and output.result.audio == bytes and transport._pending_requests.is_empty() and transport._voice_streams.is_empty())
	var busy_scope = scope_script.new()
	output.clear()
	_capture(voice, "synthesize_result", ["pending", "", "kokoro", busy_scope], output)
	var sends_before: int = transport.sent.size()
	var busy_result: Dictionary = await voice.transcribe_auto_result(bytes, config, busy_scope)
	check("busy operation cannot send or trigger paid fallback", busy_result.error_code == "operation_busy" and transport.sent.size() == sends_before and voice.whisper_calls == 1)
	busy_scope.cancel()

	var server = so.get_mcp_manager().minerva_server
	output.clear()
	_capture(server, "execute_tool_for_http", ["minerva_speak", {"text": "bad audio"}], output)
	transport.reply(_last_id(transport), {"audio_base64": Marshalls.raw_to_base64(PackedByteArray([1, 2]))})
	check("MCP refuses undecodable audio before starting playback", output.result.error_code == "invalid_audio")
	output.clear()
	_capture(server, "execute_tool_for_http", ["minerva_list_voices", {"backend": "kokoro"}], output)
	transport.reply(_last_id(transport), {"voices": []})
	check("production MCP preserves successful empty inventory", output.result.success and output.result.count == 0)
	output.clear()
	_capture(server, "execute_tool_for_http", ["minerva_list_voices", {"backend": "kokoro"}], output)
	transport.reply(_last_id(transport), {"error": "inventory offline"})
	check("production MCP preserves discovery failure", not output.result.success and output.result.has("error_code"))
	check("failed refresh does not replace successful inventory cache", voice._voice_inventories.has("kokoro") and voice._voice_inventories.kokoro.is_empty())
	config.voice_name = "Stable Voice"
	config.voice_id = "old-id"
	config.tts_backend = "qwen3-base"
	output.clear()
	_capture(voice, "synthesize_auto_result", ["test", config], output)
	check("different filtered inventory does not declare a saved voice missing", transport.sent.back().params.data.voice_id == "Stable Voice" and output.is_empty())
	transport.reply(_last_id(transport), {"audio_base64": Marshalls.raw_to_base64(bytes)})
	check("legacy synthesis preserves exact name/backend without extra discovery", output.result.success and output.result.metadata_mode == "legacy")
	var advertised := {"id": "new-id", "name": "Stable Voice", "backend_family": "qwen", "available_backends": ["qwen3-base"], "voice_type": "cloned", "latency_class": "quality", "quality_class": "high", "capabilities": ["clone"]}
	output.clear()
	_capture(voice, "list_voices_result", ["qwen3-base"], output)
	transport.reply(_last_id(transport), {"voices": [advertised]})
	check("metadata remains discoverable without guessed backend names", output.result.voices[0] == advertised and selection.describe(advertised).contains("quality_class"))
	check("saved stable name matches changed ephemeral ID", selection.resolve([advertised], config.voice_name, config.voice_id, config.tts_backend).success)
	check("duplicate saved names refuse ambiguous selection", selection.resolve([advertised, advertised.duplicate()], config.voice_name, config.voice_id, config.tts_backend).error_code == "voice_ambiguous")
	check("known unsupported backend refuses instead of substitution", selection.resolve([advertised], config.voice_name, config.voice_id, "kokoro").error_code == "voice_backend_unavailable")
	output.clear()
	_capture(voice, "list_voices_result", [""], output)
	transport.reply(_last_id(transport), {"voices": [advertised]})
	check("unfiltered inventory validates explicit backend calls", voice._check_known_voice("Stable Voice", "kokoro").error_code == "voice_backend_unavailable")
	var stale := {}
	var fresh := {}
	_capture(voice, "list_voices_result", ["qwen3-base"], stale)
	var stale_id := _last_id(transport)
	_capture(voice, "list_voices_result", ["qwen3-base"], fresh)
	transport.reply(_last_id(transport), {"voices": []})
	transport.reply(stale_id, {"voices": [advertised]})
	check("older same-filter reply cannot overwrite a newer cache", voice._voice_inventories["qwen3-base"].is_empty() and voice._inventory_for("qwen3-base").voices.is_empty())
	var option := OptionButton.new()
	var original_name: String = config.voice_name
	selection.populate(option, [{"id": "other", "name": "Other"}], config)
	check("missing saved voice is an unavailable placeholder without config writes", option.get_item_text(option.selected).contains("Unavailable") and config.voice_name == original_name and not so.config_file.has_section("Voice"))
	selection.populate(option, [], config)
	check("valid empty list retains saved identity", option.disabled and config.voice_name == original_name)
	selection.populate(option, [advertised], config)
	check("unambiguous identity refresh selects without rewriting ID", option.selected == 0 and config.voice_id == "old-id")
	option.clear()
	option.add_item("known")
	selection.show_saved_option(option, "custom-backend", {"known": 0})
	check("unknown legacy backend remains visible", option.get_item_text(option.selected).contains("custom-backend"))
	option.free()

	var prefs = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	prefs._voice_selector = OptionButton.new()
	prefs._voice_status_label = Label.new()
	prefs._voice_refresh_btn = Button.new()
	prefs._on_voice_refresh_pressed()
	var older_id := _last_id(transport)
	config.tts_backend = "kokoro"
	prefs._on_voice_refresh_pressed()
	var newer_id := _last_id(transport)
	transport.reply(newer_id, {"voices": []})
	transport.reply(older_id, {"voices": [advertised]})
	check("stale refresh cannot repaint a newer backend selection", prefs._voices_cache.is_empty() and prefs._voice_selector.disabled and config.voice_name == original_name)
	config.tts_backend = "qwen3-base"
	prefs._voices_cache = [advertised]
	selection.populate(prefs._voice_selector, [advertised], config)
	prefs._on_voice_selected(0)
	check("deliberate user voice selection saves exact intended identity", config.voice_id == "new-id" and so.config_file.get_value("Voice", "voice_name") == original_name)
	prefs._voice_selector.free()
	prefs._voice_status_label.free()
	prefs._voice_refresh_btn.free()
	prefs.free()
	transport.close_connection("inventory reset")
	check("inventory cache is invalidated by connection lifetime", voice._voice_inventories.is_empty())
	transport._connected = true
	core.registered = true

	var model_fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var model_service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new(model_fixture.params)
	core.services.assign([model_service])
	so._enabled_providers[so.API_PROVIDER.TURNROCK] = false
	var summary: Dictionary = await voice.summarize_for_speech_result("user", "answer".repeat(100), model_service.actions[0].name)
	check("disabled chat summaries fall back with per-call reason", summary.success and summary.text.length() == 200 and summary.fallback_reason == "provider_disabled")
	output.clear()
	_capture(voice, "synthesize_result", ["voice stays enabled", "", "kokoro"], output)
	transport.reply(_last_id(transport), {"audio_base64": Marshalls.raw_to_base64(bytes)})
	check("disabled chat provider does not disable TTS", output.result.success)
	so._enabled_providers[so.API_PROVIDER.TURNROCK] = true
	config.summary_model = model_service.actions[0].name
	config.speak_mode = config.SpeakMode.SUMMARIZE
	var pane = load("res://test/fixtures/voice_speech_pane.gd").new()
	root.add_child(pane)
	var player := AudioStreamPlayer.new()
	pane.add_child(player)
	pane._tts_player = player
	var gateway = load("res://test/fixtures/voice_gateway_capture.gd").new()
	pane.add_child(gateway)
	pane._voice_gateway = gateway
	pane._on_gateway_transcription_ready(bytes)
	var stopped_gateway_id := _last_id(transport)
	pane._on_gateway_transcription_ready(bytes)
	var second_gateway_id := _last_id(transport)
	pane._voice_utterance_queue.append("old queued utterance")
	output.clear()
	_capture(voice, "synthesize_result", ["independent"], output)
	var independent_id := _last_id(transport)
	pane.stop_voice_gateway()
	transport.reply(stopped_gateway_id, {"text": "stale gateway"})
	transport.reply(second_gateway_id, {"text": "another stale gateway"})
	check("gateway stop cancels all owned transcripts and queued effects only", pane._gateway_transcriptions.is_empty() and pane._voice_utterance_queue.is_empty() and pane.sent_utterances.is_empty() and transport._pending_requests.size() == 1 and transport._pending_requests.has(independent_id))
	transport.reply(independent_id, {"audio_base64": Marshalls.raw_to_base64(bytes)})
	pane.start_voice_gateway()
	pane._on_gateway_transcription_ready(bytes)
	transport.reply(_last_id(transport), {"text": "fresh gateway"})
	check("gateway restart admits a fresh transcript", pane.sent_utterances == ["fresh gateway"] and output.result.success)
	pane._voice_llm_busy = false
	pane._voice_speak_response("first speech", "user")
	var initial_operation = pane._speech_operation
	check("summary uses shared options and explicit output/context limits", transport.sent.back().params.data.max_tokens == config.summary_max_tokens and transport.sent.back().params.data.options.num_ctx == 4000)
	var old_summary_id := _last_id(transport)
	pane.cancel_tts()
	check("cancel during summary immediately releases request, busy and gateway", not pane._tts_busy and transport._pending_requests.is_empty() and gateway.finishes == 1 and pane.released == 1)
	check("terminal operation releases its bound completion callback", initial_operation.finished.get_connections().is_empty())
	var before_sends: int = transport.sent.size()
	transport.reply(old_summary_id, {"choices": [{"message": {"content": "late"}}]})
	check("late summary cannot start synthesis", transport.sent.size() == before_sends)
	config.speak_mode = config.SpeakMode.FULL
	pane._voice_speak_response("old synth")
	var old_synth_id := _last_id(transport)
	output.clear()
	_capture(voice, "synthesize_result", ["unrelated preview", "", "kokoro"], output)
	var preview_id := _last_id(transport)
	pane._voice_speak_response("replacement")
	var replacement_id := _last_id(transport)
	check("replacement starts promptly and preserves unrelated shared-client request", pane._tts_busy and not transport._pending_requests.has(old_synth_id) and transport._pending_requests.has(preview_id) and transport._pending_requests.has(replacement_id))
	transport.reply(old_synth_id, {"audio_base64": Marshalls.raw_to_base64(bytes)})
	check("late replaced synthesis cannot clear new busy state", pane._tts_busy and gateway.finishes == 2)
	transport.reply(preview_id, {"audio_base64": Marshalls.raw_to_base64(bytes)})
	check("unrelated preview completes independently", output.result.success and pane._tts_busy)
	var pcm := PackedByteArray()
	pcm.resize(32000)
	transport.reply(replacement_id, {"audio_base64": Marshalls.raw_to_base64(pcm)})
	check("actual player begins owned playback", player.playing and pane._tts_busy and gateway.starts == 1 and player.finished.get_connections().size() == 1)
	pane.cancel_tts()
	check("actual AudioStreamPlayer.stop releases busy without finished signal", not player.playing and not pane._tts_busy and player.finished.get_connections().is_empty() and gateway.finishes == 3)
	pane.cancel_tts()
	player.finished.emit()
	check("duplicate stop or late finished cannot double-release", gateway.finishes == 3 and pane.released == 3)
	pane._voice_speak_response("natural completion")
	transport.reply(_last_id(transport), {"audio_base64": Marshalls.raw_to_base64(pcm)})
	player.finished.emit()
	check("natural playback finishes exactly once", not pane._tts_busy and gateway.finishes == 4 and pane.released == 4 and player.finished.get_connections().is_empty())
	var message := Control.new()
	pane.add_child(message)
	pane._voice_speak_response("deleted message status", "", message)
	pane.last_status.free()
	pane.cancel_tts()
	check("deleted speech status cannot interrupt terminal gateway cleanup", not pane._tts_busy and gateway.finishes == 5 and pane.released == 5 and transport._pending_requests.is_empty())
	pane._voice_speak_response("teardown")
	pane._on_gateway_transcription_ready(bytes)
	pane._voice_utterance_queue.append("must not send")
	root.remove_child(pane)
	check("pane teardown cancels request without advancing queued speech", transport._pending_requests.is_empty() and gateway.finishes == 6 and pane.released == 5 and not pane._tts_busy)
	so.Chats = pane
	output.clear()
	_capture(server, "execute_tool_for_http", ["minerva_speak", {"text": "pane reload"}], output)
	var reloading_speak_id := _last_id(transport)
	pane.free()
	transport.reply(reloading_speak_id, {"audio_base64": Marshalls.raw_to_base64(bytes)})
	check("MCP completion after pane deletion refuses unavailable playback", output.result.error_code == "no_audio_player")

	core.client = saved.client
	core.registered = saved.registered
	core.services.assign(saved.services)
	so.voice_client = saved.voice
	so.voice_config = saved.config
	so._enabled_providers = saved.enabled
	so.config_file = saved.file
	so._config_file_name = saved.path
	so.Chats = saved.chats
	so.verbose_logging = saved.verbose
	transport.free()
	_completed = true
