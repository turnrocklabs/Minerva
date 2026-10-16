extends SceneTree
## Happy-path routing through the real delivery/log/PCM transport owners.
## Run only in an isolated container profile; never against a live Minerva.

var _passed: int = 0
var _failed: int = 0
var _sent: Array[Dictionary] = []


func _init() -> void:
	_run.call_deferred()


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		printerr("FAIL: " + label)


func _send(plugin_id: String, event: String, payload: Dictionary) -> Error:
	check("PCM targets the selected plugin", plugin_id == "audio_probe" and event == "voice.audio")
	_sent.append(payload.duplicate(true))
	return OK


func _run() -> void:
	await process_frame
	# Runtime loads allow the --script runner to initialize autoload types.
	var config = load("res://Scripts/Services/Voice/VoiceConfig.gd").new()
	var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new(null, null, false)
	policy.grant_capability("audio_probe", "host.audio")
	var next_frame := func() -> void: await process_frame
	var devices = load("res://Scripts/Services/Plugins/PluginAudioDevices.gd").new(config, policy, _send, next_frame,
		func() -> String: return "Default", func(_name: String) -> void: pass, func(_message: String) -> void: pass)
	var key: String = "plugin:audio_probe:remote"
	devices.handle("audio_probe", {"op": "register", "device_id": "remote", "label": "Remote", "output": true})
	devices.handle("audio_probe", {"op": "availability", "device_id": "remote", "available": true})
	check("remote speaker selected", devices.select("output", key).success)
	var store = load("res://Scripts/Services/Voice/SpeechLog.gd").new(ProjectSettings.globalize_path("user://selected-speaker-" + str(Time.get_ticks_usec())))
	var delivery = load("res://Scripts/Services/Voice/SpeechDelivery.gd").new(store, devices, null, Callable(),
		func(_message: String) -> void: pass, func(_delivery) -> void: pass)
	var origins: Array[Dictionary] = [{"chat_id": "keyboard_chat"}, {"chat_id": "passthrough_chat"},
		{"chat_id": "remote_chat", "plugin_id": "audio_probe", "send_id": 7}]
	for origin: Dictionary in origins:
		_sent.clear()
		var operation = load("res://Scripts/Services/Voice/SpeechOperation.gd").new()
		var prepared: Dictionary = delivery.prepare(operation, null, config, "test test test", origin)
		check("automatic reply admitted to selected remote", prepared.success and prepared.get("device") == key)
		if not prepared.success:
			continue
		var logged: Dictionary = store.get_record(prepared.log_id).origin
		check("log retains actual chat origin", logged.chat_id == origin.chat_id and logged.get("plugin_id", "") == origin.get("plugin_id", ""))
		# Feed a small valid WAV through SpeechOperation, as buffered synthesis does.
		var pcm: PackedByteArray = PackedByteArray([0, 0, 1, 0, 255, 127, 0, 128])
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.mix_rate = 16000
		wav.data = pcm
		var wav_path: String = "user://selected-speaker.wav"
		check("WAV fixture saved", wav.save_to_wav(wav_path) == OK)
		check("synthesized speech starts", operation.play(null, FileAccess.get_file_as_bytes(wav_path), 1.0))
		var deadline: int = Time.get_ticks_msec() + 3000
		while (_sent.is_empty() or _sent.back().get("op") != "end") and Time.get_ticks_msec() < deadline:
			await process_frame
		check("PCM reached plugin through EOS", not _sent.is_empty() and _sent.back().get("op") == "end")
		if _sent.is_empty():
			continue
		var expected: Dictionary = {"kind": "explicit"} if not origin.has("plugin_id") else {"kind": "turn", "chat_id": origin.chat_id, "send_id": 7}
		check("transport authorization preserves remote turn ownership", _sent[0].get("origin") == expected)
		var received: PackedByteArray = PackedByteArray()
		for frame: Dictionary in _sent:
			if frame.op == "chunk":
				received.append_array(Marshalls.base64_to_raw(frame.pcm))
		check("speaker receives exact PCM", received == pcm)
		var acknowledged: Dictionary = devices.handle("audio_probe", {"op": "output_complete", "device_id": "remote", "stream_id": _sent[0].stream_id, "success": true})
		check("speaker drain completes speech and marks log heard", acknowledged.success and operation.done and operation.completion_outcome.success and store.get_record(prepared.log_id).heard)
		await process_frame
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)
