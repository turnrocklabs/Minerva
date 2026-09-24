extends SceneTree

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	# The gateway only starts while Voice Support is enabled; the saved setting
	# is whatever the profile holds, so it is set here and restored at the end.
	var VoiceFeature = load("res://Scripts/Services/Voice/VoiceFeatureControl.gd")
	var voice_was_enabled: bool = VoiceFeature.is_enabled()
	VoiceFeature.set_enabled(true)
	var base_gateway = load("res://Scripts/Services/Voice/VoiceGatewayClient.gd").new()
	var bundled_adapter = base_gateway._create_detector_adapter()
	check("Voice Support defaults to the bundled detector adapter", bundled_adapter.get_script() == load("res://Scripts/Services/Voice/BundledVoiceDetectorAdapter.gd"))
	bundled_adapter.free()
	base_gateway.free()
	var gateway = load("res://test/fixtures/voice_gateway_lifecycle.gd").new()
	root.add_child(gateway)
	gateway.start()
	var first_generation: int = gateway._session_generation
	gateway.engagement_state = "ENGAGED"
	gateway._recording = true
	gateway._vad_active = true
	gateway._ptt_active = true
	gateway._ptt_saved_engagement = "ENGAGED"
	gateway._tts_playing = true
	gateway._audio_buffer = PackedByteArray([1, 2])
	gateway._pre_vad_buffer.assign([PackedByteArray([3, 4])])
	gateway.stop()
	check("stop clears capture session state and returns UI to standby",
		gateway.engagement_state == "STANDBY" and not gateway._recording and not gateway._vad_active and not gateway._ptt_active and gateway._ptt_saved_engagement.is_empty() and gateway._audio_buffer.is_empty() and gateway._pre_vad_buffer.is_empty())
	check("gateway stop preserves independently owned live TTS state", gateway._tts_playing)
	check("stop invalidates the previous health generation", gateway._session_generation != first_generation and not gateway._should_connect)
	gateway._tts_playing = false
	gateway.start()
	check("restart allocates a new detector session and capture owner", gateway._session_generation != first_generation and gateway.detector.starts == 2 and gateway.mic_starts == 2 and gateway.mic_stops == 1)
	gateway.detector.emit_connected()
	gateway._recording = true
	gateway._vad_active = true
	gateway._audio_buffer = PackedByteArray([9, 9])
	gateway.detector.emit_disconnected()
	check("socket close resets capture state before automatic reconnect", not gateway._connected and not gateway._recording and not gateway._vad_active and gateway._audio_buffer.is_empty() and gateway.engagement_state == "STANDBY")
	gateway.detector.emit_connected()
	gateway._pre_vad_buffer.assign([PackedByteArray([7, 8])])
	gateway._handle_vad_start()
	check("VAD before wake stays idle in standby", gateway._vad_active and not gateway._recording)
	gateway.wake_word_detected.connect(func(_confidence: float): gateway.stop(), CONNECT_ONE_SHOT)
	gateway.detector.emit_event({"type": "wake_word", "confidence": 0.99})
	check("a synchronous wake listener can stop without stale handler resurrection", not gateway._should_connect and gateway.engagement_state == "STANDBY" and not gateway._recording)
	gateway.start()
	gateway.detector.emit_connected()
	gateway._handle_vad_start()
	gateway._handle_wake_word(0.99)
	check("wake after VAD initializes a fresh recording", gateway.engagement_state == "ENGAGED" and gateway._recording)
	gateway.stop()
	gateway.free()
	var adapter = load("res://Scripts/Services/Voice/DockerVoiceDetectorAdapter.gd").new()
	root.add_child(adapter)
	adapter._generation = 2
	adapter._should_connect = false
	adapter._handle_health_result(1, HTTPRequest.RESULT_CANT_CONNECT, 0)
	check("stale health completion after stop cannot restart detector", not adapter._should_connect and adapter._health_retries == 0 and adapter._ws == null)
	var failures: Array[String] = []
	adapter.start_failed.connect(func(reason: String): failures.append(reason))
	adapter._should_connect = true
	adapter._health_retries = adapter.MAX_HEALTH_RETRIES - 1
	adapter._handle_health_result(adapter._generation, HTTPRequest.RESULT_CANT_CONNECT, 0)
	check("final health failure is terminal once and audio remains unavailable", failures.size() == 1 and not adapter._should_connect and adapter.send_audio(PackedByteArray([1, 2])) == ERR_CONNECTION_ERROR)
	adapter.free()
	VoiceFeature.set_enabled(voice_was_enabled)
	print("Voice gateway lifecycle: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)
