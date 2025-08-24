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

		_timeline_slider.max_value = _audio_stream_player.stream.get_length() if _audio_stream_player.stream else 0.

		_audio_stream_player.play()
		_audio_stream_player.stream_paused = true

		_timeline_slider.editable = value != null

		if value: _format_time_label()
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
