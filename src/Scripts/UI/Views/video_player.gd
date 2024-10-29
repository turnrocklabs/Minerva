extends Control

@onready var video_stream_player: VideoStreamPlayer = %VideoStreamPlayer
@onready var timer: Timer = %SliderTimer
@onready var button: Button = %PlayButton
@onready var h_slider: HSlider = %HSlider
@onready var label: Label = %Label
@onready var color_rect: ColorRect = $VBoxContainer/ColorRect
@onready var controls_timer: Timer = $VBoxContainer/ColorRect/ControlsTimer

var pause_icon: = preload("res://assets/icons/pause_icons/pause-24.png")
var play_icon: = preload("res://assets/icons/play_icons/play-24.png")

func _ready() -> void:
	h_slider.max_value = video_stream_player.get_stream_length()
	h_slider.value = 0


func update_time_label() -> void:
	label.text = format_time_label(video_stream_player.stream_position)

func format_time_label(time: float) -> String:
	var minutes: = int(time/ 60)
	var seconds: = int(time) % 60
	return "%0*d:" % [2, minutes] + "%0*d" % [2, seconds]

# this method is connected to the pressed signal of the play button
func toggle_pause() -> void:
	timer.paused = false
	video_stream_player.paused = !video_stream_player.paused
	h_slider.value = video_stream_player.stream_position
	if !video_stream_player.paused:
		button.icon = pause_icon
	else:
		button.icon = play_icon


func _on_h_slider_drag_started() -> void:
	video_stream_player.paused = true
	timer.paused = true


func _on_h_slider_drag_ended(value_changed: bool) -> void:
	if value_changed:
		video_stream_player.stream_position = h_slider.value


func _on_slider_timer_timeout() -> void:
	h_slider.value = video_stream_player.stream_position
	update_time_label()


func _on_controls_timer_timeout() -> void:
	make_controls_invisible()

var tween: Tween
func make_controls_invisible() -> void:
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_property(color_rect,"modulate", Color(1,1,1,0), 0.3)


func make_controls_visible() -> void:
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_property(color_rect,"modulate", Color(1,1,1,1), 0.1)


# this method gat called when the base node or the videoStream node recieve input
func _on_gui_input(event: InputEvent) -> void:
	make_controls_visible()
	controls_timer.start()
	handle_input_for_pause(event)


func handle_input_for_pause(event: InputEvent) -> void:
	if event.is_pressed():
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				toggle_pause()
		elif event is InputEventKey:
			if event.keycode == KEY_SPACE:
				toggle_pause()
