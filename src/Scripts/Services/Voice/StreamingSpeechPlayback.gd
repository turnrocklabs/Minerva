extends Node
## Bounded playback sink for Core TTS streams. v1.1 raw PCM from the voice
## service is mono s16le; WAV fallback remains a bounded complete-file decode.

signal finished(outcome: Dictionary)
signal started

const PCM_PENDING_LIMIT := 2 * 1024 * 1024
const TOTAL_LIMIT := 20 * 1024 * 1024
const STARTUP_SECONDS := 0.1
const GENERATOR_SECONDS := 0.5

var _player: AudioStreamPlayer
var _format := ""
var _sample_rate := 0
var _volume := 1.0
var _pending := PackedByteArray()
var _total_bytes := 0
var _input_ended := false
var _started := false
var _done := false
var _draining := false
var _generation := 0
var _playback: AudioStreamGeneratorPlayback
var _capacity_frames := 0
var _owned_stream: AudioStream

func _exit_tree() -> void:
	if not _done:
		stop()
	else:
		_generation += 1
		_pending.clear()
		_release_player()

func begin(player: AudioStreamPlayer, format: String, sample_rate: int, volume: float) -> bool:
	if _done or not is_instance_valid(player) or format not in ["pcm_s16le", "wav"]:
		return false
	_player = player
	_format = format
	_sample_rate = sample_rate
	_volume = volume
	set_process(true)
	return true

func append(bytes: PackedByteArray) -> bool:
	if _done or _input_ended:
		return false
	var limit := TOTAL_LIMIT if _format == "wav" else PCM_PENDING_LIMIT
	# Check before append; `_pending` includes any incomplete PCM sample tail.
	if _total_bytes + bytes.size() > TOTAL_LIMIT or _pending.size() + bytes.size() > limit:
		_fail("stream_buffer_overflow", "Speech stream exceeded its playback buffer.")
		return false
	_total_bytes += bytes.size()
	_pending.append_array(bytes)
	if _format == "pcm_s16le" and not _started and _pending.size() >= int(_sample_rate * 2 * STARTUP_SECONDS):
		_start_pcm()
	return true

func end() -> void:
	if _done or _input_ended:
		return
	_input_ended = true
	if _format == "wav":
		_play_complete_wav()
		return
	if _pending.size() % 2 != 0:
		_fail("invalid_audio_stream", "PCM stream ended with a partial sample.")
		return
	if _pending.is_empty() and not _started:
		_fail("empty_audio", "PCM stream ended without audio.")
		return
	# Short streams must not wait forever for the normal startup threshold.
	if not _started:
		_start_pcm()
	_check_drain()

func stop() -> void:
	if _done:
		return
	_generation += 1
	_done = true
	set_process(false)
	_release_player()
	_pending.clear()
	finished.emit({"success": false, "error_code": "cancelled", "error_message": "Speech cancelled locally."})

func _process(_delta: float) -> void:
	if _done or _format != "pcm_s16le":
		return
	if _started:
		_push_pcm()
	_check_drain()

func _start_pcm() -> void:
	if _started or _done:
		return
	if not is_instance_valid(_player):
		_fail("no_audio_player", "Speech player is unavailable.")
		return
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = float(_sample_rate)
	generator.buffer_length = GENERATOR_SECONDS
	_player.stream = generator
	_owned_stream = generator
	_player.volume_db = linear_to_db(_volume)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	if _playback == null:
		_fail("no_audio_playback", "Speech generator playback is unavailable.")
		return
	_capacity_frames = _playback.get_frames_available()
	_started = true
	_push_pcm()
	started.emit()

func _push_pcm() -> void:
	if _playback == null or _pending.size() < 2:
		return
	if not is_instance_valid(_player):
		_fail("no_audio_player", "Speech player is unavailable.")
		return
	var frames := mini(_playback.get_frames_available(), floori(float(_pending.size()) / 2.0))
	for index in range(frames):
		var offset := index * 2
		var sample := _pending.decode_s16(offset) / 32768.0
		if not _playback.push_frame(Vector2(sample, sample)):
			_fail("audio_push_failed", "Speech generator refused an available frame.")
			return
	if frames > 0:
		_pending = _pending.slice(frames * 2)

func _check_drain() -> void:
	if _done or _draining or not _input_ended or not _pending.is_empty() or not _started:
		return
	if not is_instance_valid(_player) or _playback == null:
		_fail("no_audio_player", "Speech player disappeared before drain.")
		return
	var queued_frames := _capacity_frames - _playback.get_frames_available()
	if queued_frames > 0:
		return
	_draining = true
	var drain_generation := _generation
	# The generator has reached the mixer; retain a bounded output/resampler tail.
	var tail := clampf(AudioServer.get_output_latency() + 0.05, 0.05, 0.5)
	await get_tree().create_timer(tail).timeout
	if _done or drain_generation != _generation:
		return
	_release_player()
	_succeed()

func _play_complete_wav() -> void:
	if not is_instance_valid(_player):
		_fail("no_audio_player", "Speech player is unavailable.")
		return
	if not _valid_complete_wav(_pending):
		_fail("invalid_audio", "Completed WAV stream has an unsupported layout.")
		return
	var stream := VoiceServiceClient.decode_audio(_pending)
	_pending.clear()
	if stream == null:
		_fail("invalid_audio", "Completed WAV stream could not be decoded.")
		return
	_player.stream = stream
	_owned_stream = stream
	_player.volume_db = linear_to_db(_volume)
	_player.finished.connect(_on_wav_finished, CONNECT_ONE_SHOT)
	_started = true
	_player.play()
	started.emit()

func _valid_complete_wav(bytes: PackedByteArray) -> bool:
	# The existing decoder reads the canonical PCM header at fixed offsets, so
	# accept exactly that shape rather than validate layouts it would misdecode.
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return false
	if bytes.decode_u32(4) + 8 != bytes.size() or bytes.slice(12, 16).get_string_from_ascii() != "fmt " or bytes.decode_u32(16) != 16:
		return false
	var channels := bytes.decode_u16(22)
	var data_size := bytes.decode_u32(40)
	return bytes.decode_u16(20) == 1 and channels in [1, 2] and bytes.decode_u32(24) == _sample_rate \
		and bytes.decode_u16(34) == 16 and bytes.slice(36, 40).get_string_from_ascii() == "data" \
		and data_size > 0 and data_size % (channels * 2) == 0 and 44 + data_size == bytes.size()

func _on_wav_finished() -> void:
	_release_player()
	_succeed()

func _succeed() -> void:
	if _done:
		return
	_done = true
	set_process(false)
	finished.emit({"success": true})

func _fail(code: String, message: String) -> void:
	if _done:
		return
	_generation += 1
	_done = true
	set_process(false)
	_release_player()
	_pending.clear()
	finished.emit({"success": false, "error_code": code, "error_message": message})

func _release_player() -> void:
	if is_instance_valid(_player):
		if _player.finished.is_connected(_on_wav_finished):
			_player.finished.disconnect(_on_wav_finished)
		if _owned_stream != null and _player.stream == _owned_stream:
			_player.stop()
	# AudioServer applies player stop on its mixer thread. Discard this playback
	# reference instead of clearing a generator that can remain active meanwhile.
	if is_instance_valid(_player) and _player.stream == _owned_stream:
		_player.stream = null
	_playback = null
	_owned_stream = null
