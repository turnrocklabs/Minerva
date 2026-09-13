extends SceneTree

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	var gateway = load("res://test/fixtures/voice_gateway_lifecycle.gd").new()
	root.add_child(gateway)
	gateway.start()
	var first_generation: int = gateway.health_generations.back()
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
	check("restart allocates a new health generation and capture owner", gateway.health_generations.back() != first_generation and gateway.mic_starts == 2 and gateway.mic_stops == 1)
	gateway._connected = true
	gateway._recording = true
	gateway._vad_active = true
	gateway._audio_buffer = PackedByteArray([9, 9])
	gateway._ws = WebSocketPeer.new()
	gateway._process(0.0)
	check("socket close resets capture state before automatic reconnect", not gateway._connected and not gateway._recording and not gateway._vad_active and gateway._audio_buffer.is_empty() and gateway.engagement_state == "STANDBY")
	gateway._pre_vad_buffer.assign([PackedByteArray([7, 8])])
	gateway._handle_vad_start()
	check("VAD before wake stays idle in standby", gateway._vad_active and not gateway._recording)
	gateway.wake_word_detected.connect(func(_confidence: float): gateway.stop(), CONNECT_ONE_SHOT)
	gateway._handle_gateway_message(JSON.stringify({"type": "wake_word", "confidence": 0.99}).to_utf8_buffer())
	check("a synchronous wake listener can stop without stale handler resurrection", not gateway._should_connect and gateway.engagement_state == "STANDBY" and not gateway._recording)
	gateway.start()
	gateway._handle_vad_start()
	gateway._handle_wake_word(0.99)
	check("wake after VAD initializes a fresh recording", gateway.engagement_state == "ENGAGED" and gateway._recording)
	gateway.stop()
	gateway.free()
	print("Voice gateway lifecycle: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)
