extends SceneTree
## Real AudioStreamGenerator coverage for short-END flushing and drain completion.

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	var host := Node.new()
	root.add_child(host)
	var player := AudioStreamPlayer.new()
	host.add_child(player)
	var sink = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(sink)
	var outcome := {}
	sink.finished.connect(func(value: Dictionary): outcome.assign(value))
	_check("PCM sink accepts proven mono layout", sink.begin(player, "pcm_s16le", 24000, 1.0))
	# Twenty milliseconds remains below startup prebuffer and exercises END flush.
	var pcm := PackedByteArray()
	pcm.resize(960)
	for offset in range(0, pcm.size(), 2):
		pcm.encode_s16(offset, 1200 if offset % 8 < 4 else -1200)
	_check("nonzero split PCM is admitted", sink.append(pcm.slice(0, 333)) and sink.append(pcm.slice(333)))
	sink.end()
	var deadline := Time.get_ticks_msec() + 2000
	while outcome.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check("short END starts, consumes and drains generator", outcome.get("success", false) and not player.playing)

	var stopped = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(stopped)
	var stopped_outcome := {}
	stopped.finished.connect(func(value: Dictionary): stopped_outcome.assign(value))
	stopped.begin(player, "pcm_s16le", 24000, 1.0)
	var active_pcm := PackedByteArray()
	active_pcm.resize(9600)
	stopped.append(active_pcm)
	_check("cancel scenario reaches active generator playback", player.playing)
	stopped.stop()
	_check("immediate stop clears playback and completes once", stopped_outcome.get("error_code") == "cancelled" and not player.playing)

	var old_sink = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(old_sink)
	old_sink.begin(player, "pcm_s16le", 24000, 1.0)
	old_sink.append(active_pcm)
	var replacement := AudioStreamGenerator.new()
	replacement.mix_rate = 24000
	player.stream = replacement
	player.play()
	old_sink.free()
	_check("freeing old sink cannot stop replacement playback", player.playing and player.stream == replacement)
	player.stop()

	var odd = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(odd)
	var odd_outcome := {}
	odd.finished.connect(func(value: Dictionary): odd_outcome.assign(value))
	odd.begin(player, "pcm_s16le", 24000, 1.0)
	odd.append(PackedByteArray([1]))
	odd.end()
	_check("partial PCM sample at END fails visibly", odd_outcome.get("error_code") == "invalid_audio_stream")

	var capped = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(capped)
	var cap_outcome := {}
	capped.finished.connect(func(value: Dictionary): cap_outcome.assign(value))
	capped.begin(player, "pcm_s16le", 24000, 1.0)
	var oversized := PackedByteArray()
	oversized.resize(2 * 1024 * 1024 + 1)
	_check("PCM pending cap rejects before append", not capped.append(oversized) and cap_outcome.get("error_code") == "stream_buffer_overflow" and capped._pending.is_empty())

	var wav_sink = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(wav_sink)
	var wav_outcome := {}
	wav_sink.finished.connect(func(value: Dictionary): wav_outcome.assign(value))
	wav_sink.begin(player, "wav", 24000, 1.0)
	wav_sink.append(_wav(pcm, 24000))
	wav_sink.end()
	_check("canonical completed PCM16 WAV delegates to existing playback", player.playing and wav_outcome.is_empty())
	player.finished.emit()
	_check("completed WAV finishes through player lifecycle", wav_outcome.get("success", false))

	var bad_wav = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	host.add_child(bad_wav)
	var bad_outcome := {}
	bad_wav.finished.connect(func(value: Dictionary): bad_outcome.assign(value))
	bad_wav.begin(player, "wav", 24000, 1.0)
	bad_wav.append(PackedByteArray([1, 2, 3, 4]))
	bad_wav.end()
	_check("declared WAV cannot fall through to raw PCM decoder", bad_outcome.get("error_code") == "invalid_audio")
	print("=== Streaming speech playback: %d passed, %d failed ===" % [passed, failed])
	host.free()
	quit(1 if failed else 0)

func _check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _wav(pcm: PackedByteArray, sample_rate: int) -> PackedByteArray:
	var wav := PackedByteArray()
	wav.resize(44)
	for pair in [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [36, "data"]]:
		var text: PackedByteArray = pair[1].to_ascii_buffer()
		for index in range(4): wav[pair[0] + index] = text[index]
	wav.encode_u32(4, 36 + pcm.size())
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, 1)
	wav.encode_u32(24, sample_rate)
	wav.encode_u32(28, sample_rate * 2)
	wav.encode_u16(32, 2)
	wav.encode_u16(34, 16)
	wav.encode_u32(40, pcm.size())
	wav.append_array(pcm)
	return wav
