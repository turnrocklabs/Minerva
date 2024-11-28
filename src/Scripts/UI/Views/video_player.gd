class_name VideoPlayer extends Control

#region variables
@export var video_stream_player: VideoStreamPlayer
@export var h_slider: HSlider
@export var volume_h_slider: HSlider
@onready var timer: Timer = %SliderTimer
@onready var play_button: Button = %PlayButton
@onready var label: Label = %RunningTimeLabel
@onready var color_rect: ColorRect = %ColorRect
@onready var controls_timer: Timer = %ControlsTimer
@onready var volume_button: Button = %VolumeButton
@onready var volume_rect: ColorRect = %VolumeRect
@onready var video_current_frame: TextureRect = %VideoCurrentFrame
#endregion variables

# icon textures for the buttons
static var pause_icon: = preload("res://assets/icons/pause_icons/pause-24.png")
static var play_icon: = preload("res://assets/icons/play_icons/play-24.png")
static var muted_icon: = preload("res://assets/icons/speaker-muted-24.png")
static var speaker_icon: = preload("res://assets/icons/speaker-24.png")

# this is for checking if the video was playing when the progress var is dragged
var was_playing: bool = false 
static var frame_time: = 1.0/24.0
var skip_time: = 10.0
var video_title: String = ""

var video_path: String:
	set(value):
		video_path = value
		if video_stream_player:
			var video_resource
			if video_path.get_extension() == ".ogv":
				video_resource = VideoStreamTheora.new()
				video_resource.file = value
			else:
				video_resource = FFmpegVideoStream.new()
				video_resource.file = value
			video_stream_player.stream = video_resource
			h_slider.max_value = video_stream_player.get_stream_length()
			h_slider.value = 0


func _ready() -> void:
	if video_stream_player:
		h_slider.max_value = video_stream_player.get_stream_length()
		h_slider.value = 0
		volume_h_slider.value = video_stream_player.volume
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
	else:
		video_stream_player.paused = !video_stream_player.paused
	
	h_slider.value = video_stream_player.stream_position
	if !video_stream_player.paused:
		play_button.icon = pause_icon
	else:
		play_button.icon = play_icon

#region Sliders

func _on_h_slider_drag_started() -> void:
	if !video_stream_player.paused:
		was_playing = true
	else:
		was_playing = false
	video_stream_player.paused = true
	timer.paused = true


func _on_h_slider_drag_ended(value_changed: bool) -> void:
	if value_changed:
		video_stream_player.paused = false
		video_stream_player.stream_position = h_slider.value
		await get_tree().create_timer(0.23).timeout
		video_current_frame.texture = video_stream_player.get_video_texture()
		video_current_frame.visible = true
		video_stream_player.paused = true
	if was_playing:
		video_stream_player.paused = false
	timer.paused = false


func _on_volume_h_slider_value_changed(value: float) -> void:
	video_stream_player.volume = value
	if value == 0:
		volume_button.icon = muted_icon
	else:
		volume_button.icon = speaker_icon
#endregion Sliders

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
			elif event.keycode == KEY_ESCAPE:
				if is_fullscreen:
					get_tree().root.borderless = false
					self.queue_free()

#both color_rect and volume_rect are connected to this function
func _on_color_rect_mouse_entered() -> void:
	controls_timer.paused = true

#both color_rect and volume_rect are connected to this function
func _on_color_rect_mouse_exited() -> void:
	if not color_rect.get_rect().has_point(get_local_mouse_position()) \
		or  not volume_rect.get_rect().has_point(get_local_mouse_position()):
		controls_timer.paused = false

#endregion Input listeners for pausing

#region Buttons pressed
func _on_back_button_pressed() -> void:
	video_stream_player.paused = true
	if video_stream_player.stream_position - skip_time < 0:
		video_stream_player.stream_position = 0
	else:
		video_stream_player.stream_position -= skip_time
	video_stream_player.paused = false
	video_stream_player.queue_redraw()
	video_stream_player.paused = true

func _on_ford_button_pressed() -> void:
	video_stream_player.paused = true
	if video_stream_player.stream_position + skip_time > video_stream_player.get_stream_length():
		video_stream_player.stream_position = video_stream_player.get_stream_length()
	else:
		video_stream_player.stream_position += skip_time
	video_stream_player.paused = false
	video_stream_player.queue_redraw()
	video_stream_player.paused = true


func _on_frame_back_button_pressed() -> void:
	video_stream_player.paused = true
	if video_stream_player.stream_position - frame_time < 0:
		video_stream_player.stream_position = 0
	else:
		video_stream_player.stream_position -= frame_time
	video_stream_player.paused = false
	video_stream_player.queue_redraw()
	video_stream_player.paused = true


func _on_frame_ford_button_pressed() -> void:
	video_stream_player.paused = true
	if video_stream_player.stream_position + frame_time > video_stream_player.get_stream_length():
		video_stream_player.stream_position = video_stream_player.get_stream_length()
	else:
		video_stream_player.stream_position += frame_time
	video_stream_player.paused = false
	video_stream_player.queue_redraw()
	video_stream_player.paused = true


var muted = false
var last_volume_value: float = 0.0
func _on_volume_button_pressed() -> void:
	if !muted:
		if video_stream_player.volume != 0:
			last_volume_value = video_stream_player.volume
		video_stream_player.volume = 0
		volume_h_slider.value = video_stream_player.volume
		volume_button.icon = muted_icon
		muted = true
	else:
		video_stream_player.volume = last_volume_value
		volume_h_slider.value = video_stream_player.volume
		volume_button.icon = speaker_icon
		muted = false


func _on_screenshot_button_pressed() -> void:
	# Create a Viewport if you don't have one already
	var viewport = SubViewport.new()
	viewport.size = video_stream_player.get_video_texture().get_size()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	# Add a TextureRect or Sprite2D to the Viewport
	var texture_rect = TextureRect.new()
	texture_rect.texture = video_stream_player.get_video_texture()
	texture_rect.size = viewport.size
	viewport.add_child(texture_rect)
	
	await RenderingServer.frame_post_draw  # Wait for the frame to be drawned
	# Get the image from the Viewport's texture
	var viewport_texture = viewport.get_texture()
	var image = null
	if viewport_texture:
		image = viewport_texture.get_image()
	else:
		print("Failed to get texture from viewport")
		return
	if image == null:
		print("Failed to get image from viewport texture")
		return
	# Create a Texture from the Image if needed
	var image_texture = ImageTexture.new()
	ImageTexture.create_from_image(image)
	video_current_frame.texture = image_texture
	# Proceed with the rest of your code
	var stream_position = "%s at position %s" % [video_path.get_file(), str(video_stream_player.stream_position)]
	var ep: EditorPane = SingletonObject.editor_container.editor_pane
	SingletonObject.is_graph = true
	SingletonObject.is_picture = true
	var editor = ep.add(Editor.Type.GRAPHICS, null, stream_position)
	editor.graphics_editor.setup_from_image(image)
	remove_child(viewport)
	viewport = null


var is_fullscreen: bool = false
func _on_fullscreen_button_pressed() -> void:
	video_stream_player.paused = true
	if !is_fullscreen:
		var full_screen_player: VideoPlayer = SingletonObject.video_player_scene.instantiate()
		full_screen_player.z_index = 1000
		full_screen_player.video_path = self.video_path
		full_screen_player.is_fullscreen = true
		get_tree().root.add_child(full_screen_player)
		full_screen_player.grab_focus()
		get_tree().root.borderless = true
	else:
		get_tree().root.borderless = false
		self.queue_free()
#region Buttons pressed

func _on_volume_button_mouse_entered() -> void:
	volume_rect.visible = true

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
