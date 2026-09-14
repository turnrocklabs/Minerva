extends SceneTree
## Integrated PTT and hands-free capture lifecycles over the real Core sender.

const AudioConverter = preload("res://Scripts/Services/Voice/AudioInputConverter.gd")

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	await process_frame
	var core = root.get_node("Core")
	var singleton = root.get_node("SingletonObject")
	var saved: Dictionary = {"client": core.client, "registered": core.registered, "services": core.services.duplicate(), "voice": singleton.voice_client, "config": singleton.voice_config, "chats": singleton.Chats}
	var transport = load("res://test/fixtures/core_lifecycle_client.gd").new()
	root.add_child(transport)
	transport.client_id = "client-test"
	core.client = transport
	core.registered = true
	var service_script = load("res://Scripts/Services/Providers/Core/scripts/service.gd")
	core.services.assign([service_script.new({"client_id": "voice-service", "name": "Voice", "actions": [{"topic": "voice/stt/transcribe"}]})])
	var voice = load("res://Scripts/Services/Voice/VoiceServiceClient.gd").new()
	singleton.voice_client = voice
	var config = load("res://Scripts/Services/Voice/VoiceConfig.gd").new()
	config.stt_transport = config.STTTransport.STREAMED
	singleton.voice_config = config
	singleton.Chats = null
	await _ptt_round_trip(transport)
	await _gateway_round_trip_and_stop(transport)
	core.client = saved.client
	core.registered = saved.registered
	core.services.assign(saved.services)
	singleton.voice_client = saved.voice
	singleton.voice_config = saved.config
	singleton.Chats = saved.chats
	transport.free()
	print("=== Voice input streaming: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _ptt_round_trip(transport: Node) -> void:
	transport.sent_packets.clear()
	var capture = load("res://test/fixtures/voice_audio_capture.gd").new()
	root.add_child(capture)
	capture.file_path = "user://voice-stream-ptt.wav"
	var recording: AudioStreamWAV = AudioStreamWAV.new()
	recording.format = AudioStreamWAV.FORMAT_16_BITS
	recording.mix_rate = int(AudioServer.get_mix_rate())
	recording.stereo = true
	var recording_data: PackedByteArray = PackedByteArray()
	recording_data.resize(400)
	recording.data = recording_data
	capture.effect = capture.CaptureEffect.new(recording)
	capture._normalization_capture = capture.NormalizationCapture.new()
	var target: LineEdit = LineEdit.new()
	capture.add_child(target)
	var request = capture.PTTRequest.new()
	request.target = target
	check("first PTT press opens stream and keeps listening", capture.start_ptt(request) == OK and capture.ptt_state == capture.PTTState.LISTENING and transport.sent_packets.size() == 1)
	var frames: PackedVector2Array = PackedVector2Array()
	frames.resize(1200)
	for index in frames.size():
		frames[index] = Vector2(0.25, 0.25)
	capture._normalization_capture.frames = frames
	capture._drain_normalization_capture()
	check("PTT uploads DATA while still listening", capture.ptt_state == capture.PTTState.LISTENING and transport.sent_packets.back()[0] == 2)
	root.get_node("SingletonObject").get_voice_config().stt_model = "large-v3-turbo"
	check("second PTT press enqueues normalized DATA and END without buffered STT", capture.start_ptt(request) == OK and transport.sent_packets.size() >= 3 and transport.sent_packets.back()[0] == 3 and capture.submitted.is_empty())
	var open: Dictionary = _decode_open(transport.sent_packets[0])
	check("mid-capture settings changes do not rewrite frozen OPEN selection", open.params.data.model == "small.en")
	transport._handle_message({"cmd": "response", "topic": "voice/stt/stream", "params": {"request_id": open.params.request_id, "result": {"text": "streamed ptt", "msg_id": open.msg_id}}})
	await process_frame
	check("PTT inserts only the final correlated transcript", target.text == "streamed ptt" and capture.ptt_state == capture.PTTState.READY)
	transport.sent_packets.clear()
	check("replacement PTT stream starts", capture.start_ptt(request) == OK)
	capture._normalization_capture.frames = frames
	capture._drain_normalization_capture()
	var stopped_open: Dictionary = _decode_open(transport.sent_packets[0])
	var packets_before_stop: int = int(transport.sent_packets.size())
	capture._StopConverting()
	transport._handle_message({"cmd": "response", "topic": "voice/stt/stream", "params": {"request_id": stopped_open.params.request_id, "result": {"text": "late", "msg_id": stopped_open.msg_id}}})
	await process_frame
	check("actual PTT Stop sends no END and suppresses late transcript", transport.sent_packets.size() == packets_before_stop and transport.sent_packets.back()[0] == 2 and target.text == "streamed ptt")
	capture.free()

func _gateway_round_trip_and_stop(transport: Node) -> void:
	transport.sent_packets.clear()
	var gateway = load("res://test/fixtures/voice_gateway_lifecycle.gd").new()
	root.add_child(gateway)
	gateway.engagement_state = "ENGAGED"
	var pcm: PackedByteArray = PackedByteArray()
	pcm.resize(18000)
	for offset in range(0, pcm.size(), 2):
		pcm.encode_s16(offset, 8000)
	gateway._pre_vad_buffer.assign([pcm])
	var results: Array[Dictionary] = []
	gateway.transcription_stream_finished.connect(func(_operation, outcome: Dictionary): results.append(outcome))
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	check("hands-free admission opens once and uploads its wake/VAD prefix", gateway._recording and transport.sent_packets.size() == 2 and transport.sent_packets[1][0] == 2)
	gateway._handle_vad_end()
	var open: Dictionary = _decode_open(transport.sent_packets[0])
	check("VAD endpoint sends END while transcript remains pending", transport.sent_packets.back()[0] == 3 and results.is_empty())
	transport._handle_message({"cmd": "response", "topic": "voice/stt/stream", "params": {"request_id": open.params.request_id, "result": {"text": "streamed gateway", "msg_id": open.msg_id}}})
	await process_frame
	check("hands-free emits one final transcription outcome", results.size() == 1 and results[0].success and results[0].text == "streamed gateway")

	transport.sent_packets.clear()
	gateway._pre_vad_buffer.assign([pcm])
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	var packets_before_stop: int = int(transport.sent_packets.size())
	gateway.cancel_active_transcription()
	check("Stop cancels active hands-free upload without END", results.size() == 2 and results.back().error_code == "cancelled" and transport.sent_packets.size() == packets_before_stop and transport.sent_packets.back()[0] == 2)

	gateway._pre_vad_buffer.assign([pcm])
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	gateway._process_captured_frames(PackedVector2Array([Vector2(0.2, 0.2)]), int(AudioServer.get_mix_rate()), gateway._recording_discarded_start + 1)
	check("capture ring loss cancels streamed utterance before END", not gateway._recording and results.back().error_code == "capture_overflow")

	gateway._pre_vad_buffer.assign([pcm])
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	gateway._input_converter = AudioConverter.StreamResampler.new(48000 if int(AudioServer.get_mix_rate()) != 48000 else 44100)
	gateway._process_captured_frames(PackedVector2Array([Vector2(0.2, 0.2)]), int(AudioServer.get_mix_rate()), gateway._recording_discarded_start)
	check("mid-utterance rate change cancels streamed utterance", not gateway._recording and results.back().error_code == "capture_rate_changed")
	gateway._input_converter = null

	transport.sent_packets.clear()
	gateway._pre_vad_buffer.assign([pcm])
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	gateway._handle_vad_end()
	var pending_open: Dictionary = _decode_open(transport.sent_packets[0])
	gateway._pre_vad_buffer.assign([pcm])
	gateway._vad_active = true
	gateway._begin_recording_if_admitted()
	check("new utterance remains admitted while prior END awaits recognition", gateway._pending_stt_streams.size() == 1 and gateway._recording and gateway._stt_stream_operation != null)
	gateway._reset_capture_session("test disconnect")
	var results_after_disconnect: int = results.size()
	transport._handle_message({"cmd": "response", "topic": "voice/stt/stream", "params": {"request_id": pending_open.params.request_id, "result": {"text": "stale", "msg_id": pending_open.msg_id}}})
	await process_frame
	check("disconnect cancels pending and active owners and discards late result", gateway._pending_stt_streams.is_empty() and gateway._stt_stream_operation == null and results.size() == results_after_disconnect)
	gateway.free()

func _decode_open(packet: PackedByteArray) -> Dictionary:
	var size: int = packet.decode_u32(17)
	return JSON.parse_string(packet.slice(25, 25 + size).get_string_from_utf8())
