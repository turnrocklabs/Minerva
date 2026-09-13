extends SceneTree

const Converter = preload("res://Scripts/Services/Voice/AudioInputConverter.gd")

var passed := 0
var failed := 0


func _init() -> void:
	_test_downmix_and_header()
	_test_recording_contract()
	_test_resampling_quality(44100)
	_test_resampling_quality(48000)
	_test_chunk_continuity()
	_report_conversion_cost(44100)
	_report_conversion_cost(48000)
	print("\nAudio input converter: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("  PASS: ", label)
	else:
		failed += 1
		printerr("  FAIL: ", label)


func _stereo_tone(rate: int, seconds: float, frequency: float, right_scale: float = 1.0) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(roundi(rate * seconds))
	for index in range(frames.size()):
		var value := 0.6 * sin(TAU * frequency * index / rate)
		frames[index] = Vector2(value, value * right_scale)
	return frames


func _pcm_rms(pcm: PackedByteArray, skip_samples: int = 0) -> float:
	var samples := floori(float(pcm.size()) / 2.0)
	if samples <= skip_samples:
		return 0.0
	var sum := 0.0
	for index in range(skip_samples, samples):
		var value := float(pcm.decode_s16(index * 2)) / 32768.0
		sum += value * value
	return sqrt(sum / (samples - skip_samples))


func _test_downmix_and_header() -> void:
	var pcm := Converter.frames_to_pcm16(_stereo_tone(16000, 0.1, 1000.0, -1.0), 16000)
	var wav := Converter.pcm16_to_wav(pcm)
	check("opposed stereo channels downmix to silence", _pcm_rms(pcm) < 0.0001)
	check("canonical WAV declares mono PCM16 at 16 kHz", wav.slice(0, 4).get_string_from_ascii() == "RIFF" and wav.decode_u16(22) == 1 and wav.decode_u32(24) == 16000 and wav.decode_u16(34) == 16 and wav.decode_u32(40) == pcm.size() and wav.size() == pcm.size() + 44)


func _test_recording_contract() -> void:
	var frames := _stereo_tone(44100, 0.1, 1000.0)
	var recording := _recording_from_frames(frames, 44100)
	var converted: Dictionary = Converter.stream_to_16k_mono(recording)
	check("native AudioEffectRecord shape converts without a disk read", converted.success and converted.source_rate == 44100 and converted.source_channels == 2 and converted.wav.decode_u32(24) == 16000 and converted.wav.decode_u16(22) == 1)
	recording.format = AudioStreamWAV.FORMAT_IMA_ADPCM
	check("compressed recording data is never reinterpreted as PCM", not Converter.stream_to_16k_mono(recording).success)


func _recording_from_frames(frames: PackedVector2Array, rate: int) -> AudioStreamWAV:
	var recording := AudioStreamWAV.new()
	recording.format = AudioStreamWAV.FORMAT_16_BITS
	recording.mix_rate = rate
	recording.stereo = true
	var pcm := PackedByteArray()
	pcm.resize(frames.size() * 4)
	for index in range(frames.size()):
		pcm.encode_s16(index * 4, roundi(frames[index].x * 32767.0))
		pcm.encode_s16(index * 4 + 2, roundi(frames[index].y * 32767.0))
	recording.data = pcm
	return recording


func _test_resampling_quality(rate: int) -> void:
	var passband := Converter.frames_to_pcm16(_stereo_tone(rate, 0.25, 1000.0), rate)
	var stopband := Converter.frames_to_pcm16(_stereo_tone(rate, 0.25, 12000.0), rate)
	var expected_samples := ceili(0.25 * rate * 16000.0 / rate)
	check("%d Hz conversion retains duration within one target sample" % rate, abs(floori(float(passband.size()) / 2.0) - expected_samples) <= 1)
	check("%d Hz FIR retains speech-band energy" % rate, _pcm_rms(passband, 32) > 0.35)
	check("%d Hz FIR rejects above-Nyquist energy" % rate, _pcm_rms(stopband, 32) < 0.03)
	var error := 0.0
	var compared := 0
	for index in range(32, floori(float(passband.size()) / 2.0) - 32):
		var expected := 0.6 * sin(TAU * 1000.0 * index / 16000.0)
		error += absf(float(passband.decode_s16(index * 2)) / 32768.0 - expected)
		compared += 1
	check("%d Hz rational phases preserve waveform timing" % rate, compared > 0 and error / compared < 0.03)
	var odd_frames := _stereo_tone(rate, 0.1, 1234.0).slice(0, 1001)
	var odd_pcm := Converter.frames_to_pcm16(odd_frames, rate)
	check("%d Hz conversion retains the final noninteger interval" % rate, floori(float(odd_pcm.size()) / 2.0) == ceili(1001.0 * 16000.0 / rate))


func _test_chunk_continuity() -> void:
	var frames := _stereo_tone(44100, 0.37, 1234.0)
	var whole := Converter.frames_to_pcm16(frames, 44100)
	var stream := Converter.StreamResampler.new(44100)
	var chunked := PackedByteArray()
	var offset := 0
	while offset < frames.size():
		var finish := mini(offset + 1471, frames.size())
		chunked.append_array(stream.append_frames(frames.slice(offset, finish)))
		offset = finish
	chunked.append_array(stream.flush())
	check("chunked gateway conversion matches buffered conversion exactly", chunked == whole)


func _report_conversion_cost(rate: int) -> void:
	# Signal synthesis is outside the timer so this reports converter preparation only.
	var frames := _stereo_tone(rate, 10.0, 1000.0)
	var recording := _recording_from_frames(frames, rate)
	var started := Time.get_ticks_usec()
	var first_result: Dictionary = Converter.stream_to_16k_mono(recording)
	var first_usec := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var second_result: Dictionary = Converter.stream_to_16k_mono(recording)
	var repeated_usec := Time.get_ticks_usec() - started
	check("%d Hz 10-second recording conversion succeeds" % rate, first_result.success and second_result.success)
	if not first_result.success or not second_result.success:
		return
	var first: PackedByteArray = first_result.pcm
	var second: PackedByteArray = second_result.pcm
	var stream := Converter.StreamResampler.new(rate)
	var streamed := PackedByteArray()
	var max_chunk_usec := 0
	var total_chunk_usec := 0
	var offset := 0
	var streamed_until := frames.size() - 100
	while offset < streamed_until:
		var finish := mini(offset + roundi(rate / 30.0), streamed_until)
		started = Time.get_ticks_usec()
		streamed.append_array(stream.append_frames(frames.slice(offset, finish)))
		var elapsed := Time.get_ticks_usec() - started
		max_chunk_usec = maxi(max_chunk_usec, elapsed)
		total_chunk_usec += elapsed
		offset = finish
	started = Time.get_ticks_usec()
	streamed.append_array(stream.append_frames(frames.slice(streamed_until)))
	streamed.append_array(stream.flush())
	var finalized_wav := Converter.pcm16_to_wav(streamed)
	var finalize_usec := Time.get_ticks_usec() - started
	check("%d Hz 10-second benchmark preserves exact output size" % rate, first.size() == second.size() and streamed.size() == first.size())
	check("%d Hz incremental finalization wraps the complete canonical WAV" % rate, finalized_wav.size() == streamed.size() + 44)
	print("  PERF: source_rate=%d duration_s=10 batch_first_ms=%.3f batch_repeated_ms=%.3f incremental_total_ms=%.3f max_chunk_ms=%.3f stop_finalize_ms=%.3f" % [rate, first_usec / 1000.0, repeated_usec / 1000.0, total_chunk_usec / 1000.0, max_chunk_usec / 1000.0, finalize_usec / 1000.0])
