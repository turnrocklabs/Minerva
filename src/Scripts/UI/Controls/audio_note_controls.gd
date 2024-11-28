class_name AudioControl
extends HBoxContainer

@export var audio_slider: HSlider
@export var volume_slider: HSlider
@export var audio_stream_player: AudioStreamPlayer
@export var audio_timer: Timer

@export_category("audio buttons")
@export var play_button: Button
@export var stop_button: Button
@export var mute_button: Button

static var pause_icon: = preload("res://assets/icons/pause_icons/pause-24.png")
static var play_icon: = preload("res://assets/icons/play_icons/play-24.png")
static var muted_icon: = preload("res://assets/icons/speaker-muted-24.png")
static var speaker_icon: = preload("res://assets/icons/speaker-24.png")

var audio: AudioStream:
	set(value):
		audio = value
		audio_stream_player.stream = audio
		audio_slider.max_value = audio_stream_player.stream.get_length()
		audio_slider.value = 0

var audio_progress: = 0.0
var last_audio_volume: float = 1.0
var was_playing: = false
func _on_play_button_pressed() -> void:
	if was_playing:
		audio_stream_player.stream_paused = !audio_stream_player.stream_paused
		audio_timer.paused = audio_stream_player.stream_paused
		play_button.icon = play_icon
		if audio_stream_player.stream_paused:
			play_button.icon = play_icon
		else:
			play_button.icon = pause_icon
	else:
		audio_stream_player.play()
		play_button.icon = pause_icon
		was_playing = true


func _on_stop_button_pressed() -> void:
	audio_stream_player.stop()
	audio_progress = 0.0
	was_playing = false
	play_button.icon = play_icon
	audio_slider.value = audio_progress


var muted: = false
func _on_mute_button_pressed() -> void:
	
	if muted:
		volume_slider.value = last_audio_volume
		#_on_volume_slider_value_changed(last_audio_volume)
		mute_button.icon = speaker_icon
		muted = false
	else:
		volume_slider.value = 0.0
		#_on_volume_slider_value_changed(0.0)
		mute_button.icon = muted_icon
		muted = true


func _on_volume_slider_value_changed(value: float) -> void:
	audio_stream_player.volume_db = linear_to_db(value)
	if value != 0:
		last_audio_volume = value
	if value == 0:
		mute_button.icon = muted_icon
	else:
		mute_button.icon = speaker_icon


func _on_audio_timer_timeout() -> void:
	audio_slider.value = audio_stream_player.get_playback_position()


func _on_audio_slider_drag_ended(value_changed: bool) -> void:
	if value_changed:
		audio_stream_player.pla
