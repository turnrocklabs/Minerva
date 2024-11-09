extends Control
class_name VideoPlayer

#region onready variables
@onready var video_stream_player: VideoStreamPlayer = %VideoStreamPlayer
@onready var timer: Timer = %SliderTimer
@onready var play_button: Button = %PlayButton
@onready var h_slider: HSlider = %HSlider
@onready var label: Label = %Label
@onready var color_rect: ColorRect = %ColorRect
@onready var controls_timer: Timer = %ControlsTimer
@onready var volume_button: Button = %VolumeButton
@onready var volume_h_slider: HSlider = %VolumeHSlider
@onready var volume_rect: ColorRect = %VolumeRect
#endregion onready variables


var pause_icon: = preload("res://assets/icons/pause_icons/pause-24.png")
var play_icon: = preload("res://assets/icons/play_icons/play-24.png")

var was_playing: bool = false # this is for checking if the video was playing when the progress var is dragged



var video_path: String:
	set(value):
		video_path = value
		var stream: = FFmpegVideoStream.new()
		stream.file = value
		
		if video_stream_player:
			video_stream_player.stream = stream
			h_slider.max_value = video_stream_player.get_stream_length()
			h_slider.value = 0
			video_stream_player.play()


func _ready() -> void:
	if video_stream_player:
		h_slider.max_value = video_stream_player.get_stream_length()
		h_slider.value = 0
		video_stream_player.play()


func update_time_label() -> void:
	label.text = format_time_label(video_stream_player.stream_position)


func format_time_label(time: float) -> String:
	var minutes: = int(time/ 60)
	var seconds: = int(time) % 60
	return "%0*d:" % [2, minutes] + "%0*d" % [2, seconds]

# this method is connected to the pressed signal of the play button
func toggle_pause() -> void:
	timer.paused = false
	if !video_stream_player.is_playing():
		video_stream_player.stream_position = 0
		video_stream_player.play()
		video_stream_player.paused
	else:
		video_stream_player.paused = !video_stream_player.paused
	
	h_slider.value = video_stream_player.stream_position
	if !video_stream_player.paused:
		play_button.icon = pause_icon
	else:
		play_button.icon = play_icon

#region Video Slider

func _on_h_slider_drag_started() -> void:
	if !video_stream_player.paused:
		was_playing = true
	else:
		was_playing = false
	video_stream_player.paused = true
	timer.paused = true


func _on_h_slider_drag_ended(value_changed: bool) -> void:
	if value_changed:
		video_stream_player.stream_position = h_slider.value
	if was_playing:
		video_stream_player.paused = false
	timer.paused = false


func _on_volume_h_slider_drag_ended(value_changed: bool) -> void:
	if value_changed:
		#not sure if we should use volume_db or just volume or if it even makes a difference
		video_stream_player.volume_db = volume_h_slider.value
		#video_stream_player.volume = volume_h_slider.value

#endregion Video Slider

#region Timers
func _on_slider_timer_timeout() -> void:
	h_slider.value = video_stream_player.stream_position
	update_time_label()


func _on_controls_timer_timeout() -> void:
	make_controls_invisible()

#endregion Timers


#region Controls Visibility
var tween: Tween
func make_controls_invisible() -> void:
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_property(color_rect,"modulate", Color(1,1,1,0), 0.3)
	await tween.finished
	volume_rect.visible = false
	color_rect.visible = false
	#if visible and self.get_rect().has_point(get_local_mouse_position()) and is_visible_in_tree():
		#DisplayServer.mouse_set_mode(DisplayServer.MOUSE_MODE_HIDDEN)


func make_controls_visible() -> void:
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_property(color_rect,"modulate", Color(1,1,1,1), 0.1)
	DisplayServer.mouse_set_mode(DisplayServer.MOUSE_MODE_VISIBLE)
	color_rect.visible = true

#endregion Controls Visibility

#region Input listeners for pausing
# this method is connected to the base node, the aspectRatio Container, the color_rect, videoStream node gui_input signals
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

#both color_rect and volume_rect are connected to this function
func _on_color_rect_mouse_entered() -> void:
	controls_timer.paused = true

#both color_rect and volume_rect are connected to this function
func _on_color_rect_mouse_exited() -> void:
	if not color_rect.get_rect().has_point(get_local_mouse_position()) or  not volume_rect.get_rect().has_point(get_local_mouse_position()):
		controls_timer.paused = false

#endregion Input listeners for pausing


func _on_volume_button_pressed() -> void:
	volume_rect.visible =!volume_rect.visible


func _on_visibility_changed() -> void:
	if timer and controls_timer:
		if !visible:
			timer.paused = true
			controls_timer.paused = true
		else:
			timer.paused = false
			controls_timer.paused = false


func _on_focus_exited() -> void:
	timer.paused = true
	controls_timer.paused = true



func _on_tree_exited() -> void:
	DisplayServer.mouse_set_mode(DisplayServer.MOUSE_MODE_VISIBLE)
