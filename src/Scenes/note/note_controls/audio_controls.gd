extends VBoxContainer
class_name NoteAudioControls

static var _pause_icon: = preload("res://assets/icons/pause_icons/pause-24.png")
static var _play_icon: = preload("res://assets/icons/play_icons/play-24.png")
static var _speaker_muted_icon: = preload("res://assets/icons/speaker-muted-24.png")
static var _speaker_icon: = preload("res://assets/icons/speaker-24.png")


@onready var _play_button: Button = %PlayButton
@onready var _speaker_button: Button = %SpeakerButton
@onready var _timeline_slider: HSlider = %TimelineSlider
@onready var _volume_slider: HSlider = %VolumeSlider
@onready var _time_label: Label = %TimeLabel

@onready var _audio_stream_player: AudioStreamPlayer = %AudioStreamPlayer
## Used to update the time code label every one second, while the audio is playing
@onready var _time_code_timer: Timer = %Timer


## This notes audio content.
var audio: AudioStream:
	set(value):
		_audio_stream_player.stream = value

		_timeline_slider.max_value = _audio_stream_player.stream.get_length() if _audio_stream_player.stream else 0.1

		_audio_stream_player.play()
		_audio_stream_player.stream_paused = true

		_timeline_slider.editable = value != null

		if value: _format_time_label()
		else: _time_label.text = ""
	get:
		return _audio_stream_player.stream

## Setting this property pauses/resumes the audio player.
var paused: bool:
	set(value):
		_audio_stream_player.stream_paused = value

		_play_button.icon = _play_icon if value else _pause_icon

		# stop the timeline slider processing if the audio is paused
		set_process(not value)
		_time_code_timer.paused = value
	get:
		return _audio_stream_player.stream_paused

## Setting this property changes the audio player volume.
var volume: float:
	set(value):
		_volume_slider.value = value
	get:
		return _volume_slider.value

## Setting this property mutes the audio player.
var muted: bool = false:
	set(value):
		muted = value

		# if we muted the track and the volume was already set to zero
		# make it unmuted now by raising the volume
		if muted and volume == 0:
			muted = false
			volume = 10
		
		# if we're unmuting and volume was 0, raise the volume
		if not muted and volume == 0:
			volume = 10

		_speaker_button.icon = _speaker_muted_icon if muted else _speaker_icon
		_audio_stream_player.volume_linear = 0. if muted else volume / 100
		_volume_slider.editable = not muted
		


func setup(note_audio: AudioStream):
	audio = note_audio


## Constructs a dictionary with all the audio stream data serialized.[br]
## [method load_audio_from_data] can be used to load the data back.
func get_audio_data() -> Dictionary:
	if audio is AudioStreamMP3:
		return {
			"Type": "AudioStreamMP3",
			"Data": Marshalls.raw_to_base64(audio.data),
			"Loop": audio.loop,
			"LoopOffset": audio.loop_offset,
			"BarBeats": audio.bar_beats,
			"BeatCount": audio.beat_count,
			"Bpm": audio.bpm
		}
		
	elif audio is AudioStreamOggVorbis:
		var packet_data_base64 = []
		if audio.packet_sequence:
			for packet in audio.packet_sequence.packet_data:
				packet_data_base64.append(Marshalls.raw_to_base64(packet))
		
		return {
			"Type": "AudioStreamOggVorbis",
			"PacketData": packet_data_base64,
			"GranulePositions": audio.packet_sequence.granule_positions if audio.packet_sequence else PackedInt64Array(),
			"SamplingRate": audio.packet_sequence.sampling_rate if audio.packet_sequence else 0.0,
			"Loop": audio.loop,
			"LoopOffset": audio.loop_offset,
			"BarBeats": audio.bar_beats,
			"BeatCount": audio.beat_count,
			"Bpm": audio.bpm
		}
		
	elif audio is AudioStreamWAV:
		return {
			"Type": "AudioStreamWAV",
			"Data": Marshalls.raw_to_base64(audio.data),
			"Format": audio.format,
			"MixRate": audio.mix_rate,
			"Stereo": audio.stereo,
			"LoopMode": audio.loop_mode,
			"LoopBegin": audio.loop_begin,
			"LoopEnd": audio.loop_end
		}
	
	return {}

## Loads the data saved by [method get_audio_data] into a [class AudioStream].
## Returns `null` on error.
static func load_audio_from_data(audio_data: Dictionary) -> AudioStream:
	if not audio_data.has("Type"):
		return null
	
	match audio_data["Type"]:
		"AudioStreamMP3":
			var stream = AudioStreamMP3.new()
			stream.data = Marshalls.base64_to_raw(audio_data["Data"])
			stream.loop = audio_data.get("Loop", false)
			stream.loop_offset = audio_data.get("LoopOffset", 0.0)
			stream.bar_beats = audio_data.get("BarBeats", 0)
			stream.beat_count = audio_data.get("BeatCount", 0)
			stream.bpm = audio_data.get("Bpm", 0.0)
			return stream
			
		"AudioStreamOggVorbis":
			var stream = AudioStreamOggVorbis.new()
			
			# Reconstruct packet sequence
			if audio_data.has("PacketData") and audio_data["PacketData"].size() > 0:
				var packet_seq = OggPacketSequence.new()
				
				# Convert base64 packets back to PackedByteArray
				packet_seq.packet_data = []
				for packet_base64 in audio_data["PacketData"]:
					packet_seq.packet_data.append(Marshalls.base64_to_raw(packet_base64))
				
				packet_seq.granule_positions = audio_data.get("GranulePositions", PackedInt64Array())
				packet_seq.sampling_rate = audio_data.get("SamplingRate", 0.0)
				stream.packet_sequence = packet_seq
			
			stream.loop = audio_data.get("Loop", false)
			stream.loop_offset = audio_data.get("LoopOffset", 0.0)
			stream.bar_beats = audio_data.get("BarBeats", 0)
			stream.beat_count = audio_data.get("BeatCount", 0)
			stream.bpm = audio_data.get("Bpm", 0.0)
			return stream
			
		"AudioStreamWAV":
			var stream = AudioStreamWAV.new()
			stream.data = Marshalls.base64_to_raw(audio_data["Data"])
			stream.format = audio_data.get("Format", AudioStreamWAV.FORMAT_16_BITS)
			stream.mix_rate = audio_data.get("MixRate", 44100)
			stream.stereo = audio_data.get("Stereo", false)
			stream.loop_mode = audio_data.get("LoopMode", AudioStreamWAV.LOOP_DISABLED)
			stream.loop_begin = audio_data.get("LoopBegin", 0)
			stream.loop_end = audio_data.get("LoopEnd", 0)
			return stream
	
	return null

func _ready() -> void:

	set_process(false) # when the audio is unpaused it will start processing again
	_time_code_timer.paused = true

	# play the audio again, but stop it immediately for easier management in the paused setter
	_audio_stream_player.finished.connect(
		func():
			_audio_stream_player.play()
			_audio_stream_player.stream_paused = true
			_timeline_slider.value = 0
			_format_time_label()
			paused = true
	)

	_time_code_timer.timeout.connect(_format_time_label)

	

# update the timeline slider while the audio is playing
func _process(_delta: float) -> void:
	var current_pos: = _audio_stream_player.get_playback_position() + AudioServer.get_time_since_last_mix()

	_timeline_slider.set_value_no_signal(current_pos)


## Updates the time code label
func _format_time_label() -> void:
	var current: = _audio_stream_player.get_playback_position() + AudioServer.get_time_since_last_mix()
	var total = _audio_stream_player.stream.get_length()

	var time_code: =  "%s/%s" % [_format_time(current), _format_time(total)]

	_time_label.text = time_code

## Given a number of seconds, return a string representation
## in 00:00 format
func _format_time(time: float) -> String:
	
	var minutes = time / 60.0
	var seconds = fmod(time, 60.0)

	return "%02d:%02d" % [minutes, seconds]


func _on_speaker_button_pressed() -> void:
	muted = not muted

func _on_play_button_pressed() -> void:
	paused = not paused

func _on_volume_slider_value_changed(value: float) -> void:
	_audio_stream_player.volume_linear = value / 100

	_speaker_button.icon = _speaker_muted_icon if value == 0 else _speaker_icon


# region Volume Slider

# when there's a input over the volume button or the volume slider, keep the volume slider visible

var _vol_tween: Tween
var _anim_duration: = 0.1
var _keep: = false:
	set(value):
		_keep = value

		if is_instance_valid(_vol_tween) and _vol_tween.is_running():
			_vol_tween.stop()
		
		_vol_tween = create_tween()
		_vol_tween.set_parallel(true)
		_vol_tween.tween_property(_volume_slider, "custom_minimum_size:x", 150 if _keep else 0, _anim_duration)
		_vol_tween.tween_property(_volume_slider, "modulate:a", 1 if _keep else 0, _anim_duration+0.1)

func _on_speaker_button_mouse_entered() -> void:
	_keep = true

func _on_speaker_button_mouse_exited() -> void:
	_keep = false

func _on_volume_slider_mouse_entered() -> void:
	_keep = true

func _on_volume_slider_mouse_exited() -> void:
	_keep = false

# endregion


func _on_timeline_slider_value_changed(value: float) -> void:
	# if the stream is paued the seek doesn't change the current position
	# we need to force it to play just for a moment, the user won't hear anything

	if _audio_stream_player.stream_paused:
		_audio_stream_player.stream_paused = false
		_audio_stream_player.seek(value)
		_audio_stream_player.stream_paused = true
	else:
		_audio_stream_player.seek(value)
	
	if _audio_stream_player.stream:
		_format_time_label()
