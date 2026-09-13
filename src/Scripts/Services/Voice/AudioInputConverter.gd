class_name AudioInputConverter
extends RefCounted
## Converts captured PCM to the 16 kHz mono s16le contract shared by STT and VAD.

const TARGET_RATE := 16000
const FILTER_HALF_WIDTH := 16


class StreamResampler extends RefCounted:
	var source_rate: int
	var valid := false
	var _samples := PackedFloat32Array()
	var _buffer_start := 0
	var _total_input := 0
	var _next_output := 0
	var _phase_count := 1
	var _phase_step := 1
	var _phase_taps: Array[PackedFloat32Array] = []

	func _init(rate: int) -> void:
		source_rate = rate
		if source_rate < 8000 or source_rate > 192000:
			return
		valid = true
		var divisor := _gcd(source_rate, TARGET_RATE) if source_rate > 0 else 1
		_phase_count = floori(float(TARGET_RATE) / divisor)
		_phase_step = floori(float(source_rate) / divisor)
		_build_phase_taps()

	func append_frames(frames: PackedVector2Array) -> PackedByteArray:
		if not valid:
			return PackedByteArray()
		if source_rate == TARGET_RATE:
			var mono := PackedFloat32Array()
			mono.resize(frames.size())
			for index in range(frames.size()):
				mono[index] = (frames[index].x + frames[index].y) * 0.5
			_total_input += frames.size()
			_next_output += frames.size()
			return _floats_to_pcm16(mono)
		for frame in frames:
			_samples.append((frame.x + frame.y) * 0.5)
		_total_input += frames.size()
		return _render(false)

	func flush() -> PackedByteArray:
		if source_rate == TARGET_RATE:
			return PackedByteArray()
		return _render(true)

	func _render(flush_tail: bool) -> PackedByteArray:
		if source_rate <= 0 or _total_input == 0:
			return PackedByteArray()
		# Ceil retains the final partial interval; duration error stays below one target sample.
		var target_count := int(ceil(float(_total_input) * TARGET_RATE / source_rate))
		var values := PackedFloat32Array()
		while _next_output < target_count:
			var center := float(_next_output) * source_rate / TARGET_RATE
			if not flush_tail and center + FILTER_HALF_WIDTH >= _total_input:
				break
			values.append(_sample_at(center))
			_next_output += 1
		_trim_history()
		return _floats_to_pcm16(values)

	func _floats_to_pcm16(samples: PackedFloat32Array) -> PackedByteArray:
		var pcm := PackedByteArray()
		pcm.resize(samples.size() * 2)
		for index in range(samples.size()):
			var sample := samples[index] if is_finite(samples[index]) else 0.0
			var value := clampi(roundi(clampf(sample, -1.0, 1.0) * 32767.0), -32768, 32767)
			pcm.encode_s16(index * 2, value)
		return pcm

	func _sample_at(center: float) -> float:
		var first := floori(center) - FILTER_HALF_WIDTH + 1
		var weighted := 0.0
		var taps: PackedFloat32Array = _phase_taps[(_next_output * _phase_step) % _phase_count]
		for tap_index in range(taps.size()):
			var source_index := first + tap_index
			var local := source_index - _buffer_start
			if local >= 0 and local < _samples.size():
				weighted += _samples[local] * taps[tap_index]
		return weighted

	func _build_phase_taps() -> void:
		var cutoff := minf(1.0, float(TARGET_RATE) / source_rate) * 0.9
		for phase in range(_phase_count):
			var fraction := float(phase) / _phase_count
			var taps := PackedFloat32Array()
			taps.resize(FILTER_HALF_WIDTH * 2)
			var total := 0.0
			for tap_index in range(taps.size()):
				var distance := fraction - (tap_index - FILTER_HALF_WIDTH + 1)
				var normalized := distance / FILTER_HALF_WIDTH
				var window := 0.42 + 0.5 * cos(PI * normalized) + 0.08 * cos(TAU * normalized)
				var x := PI * cutoff * distance
				var weight := cutoff * (1.0 if absf(x) < 0.000001 else sin(x) / x) * window
				taps[tap_index] = weight
				total += weight
			if absf(total) > 0.000001:
				for tap_index in range(taps.size()):
					taps[tap_index] /= total
			_phase_taps.append(taps)

	func _trim_history() -> void:
		var next_center := float(_next_output) * source_rate / TARGET_RATE
		var retain_from := maxi(0, floori(next_center) - FILTER_HALF_WIDTH)
		var discard := mini(retain_from - _buffer_start, _samples.size())
		if discard > 0:
			_samples = _samples.slice(discard)
			_buffer_start += discard

	func _gcd(left: int, right: int) -> int:
		while right != 0:
			var remainder := left % right
			left = right
			right = remainder
		return maxi(left, 1)


static func frames_to_pcm16(frames: PackedVector2Array, source_rate: int) -> PackedByteArray:
	var converter := StreamResampler.new(source_rate)
	var result := converter.append_frames(frames)
	result.append_array(converter.flush())
	return result


static func stream_to_16k_mono(recording: AudioStreamWAV) -> Dictionary:
	if recording == null or recording.format != AudioStreamWAV.FORMAT_16_BITS or recording.mix_rate < 8000 or recording.mix_rate > 192000 or recording.data.is_empty():
		return {"success": false, "error_code": "unsupported_audio", "error_message": "Recording must be PCM16 audio."}
	var channels := 2 if recording.stereo else 1
	var frame_bytes := channels * 2
	var source_data: PackedByteArray = recording.data
	if source_data.size() % frame_bytes != 0:
		return {"success": false, "error_code": "invalid_audio", "error_message": "Recording contains a partial PCM frame."}
	var frames := PackedVector2Array()
	frames.resize(floori(float(source_data.size()) / frame_bytes))
	for index in range(frames.size()):
		var offset := index * frame_bytes
		var left := float(source_data.decode_s16(offset)) / 32768.0
		var right := float(source_data.decode_s16(offset + 2)) / 32768.0 if channels == 2 else left
		frames[index] = Vector2(left, right)
	var pcm := frames_to_pcm16(frames, recording.mix_rate)
	return {"success": true, "wav": pcm16_to_wav(pcm), "pcm": pcm,
		"source_rate": recording.mix_rate, "source_channels": channels,
		"source_bytes": source_data.size(), "output_bytes": pcm.size() + 44}


static func pcm16_to_wav(pcm: PackedByteArray) -> PackedByteArray:
	var wav := PackedByteArray()
	wav.resize(44)
	_write_ascii(wav, 0, "RIFF")
	wav.encode_u32(4, 36 + pcm.size())
	_write_ascii(wav, 8, "WAVEfmt ")
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, 1)
	wav.encode_u32(24, TARGET_RATE)
	wav.encode_u32(28, TARGET_RATE * 2)
	wav.encode_u16(32, 2)
	wav.encode_u16(34, 16)
	_write_ascii(wav, 36, "data")
	wav.encode_u32(40, pcm.size())
	wav.append_array(pcm)
	return wav


static func _write_ascii(bytes: PackedByteArray, offset: int, value: String) -> void:
	var encoded := value.to_ascii_buffer()
	for index in range(encoded.size()):
		bytes[offset + index] = encoded[index]
