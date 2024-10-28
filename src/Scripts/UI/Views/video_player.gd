extends Control
@onready var video_stream_player: VideoStreamPlayer = $MarginContainer/VBoxContainer/AspectRatioContainer/VideoStreamPlayer
@onready var button: Button = $MarginContainer/VBoxContainer/HBoxContainer/Button
@onready var h_slider: HSlider = $MarginContainer/VBoxContainer/HBoxContainer/HSlider
@onready var label: Label = $MarginContainer/VBoxContainer/HBoxContainer/Label

func _ready() -> void:
	h_slider.max_value = video_stream_player.get_stream_length()
	h_slider.value_changed.connect(update_time_label)


func _process(delta: float) -> void:
	h_slider.value = video_stream_player.stream_position


func update_time_label() -> void:
	label.text = format_time_label(video_stream_player.stream_position)

func format_time_label(time: float) -> String:
	var minutes: = int(time)/ 60
	var seconds: = int(time) % 60
	return "%s:%s" % [minutes, seconds]

func _on_button_pressed() -> void:
	video_stream_player.paused = !video_stream_player.paused
