class_name VideoRecorderOverlay
extends PanelContainer
## Recording overlay UI: mode selector, elapsed timer, Pause/Stop buttons.
## Floats above the main UI during recording.

const VideoRecordingDataScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
const VideoRecorderCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecorder.gd")
const VideoCropOverlayScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoCropOverlay.gd")
const WebcamCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/WebcamCapture.gd")

signal recording_completed(recording_data: VideoRecordingDataScript)

## The capture engine
var recorder: VideoRecorderCaptureScript = null

## Crop overlay (added to viewport root during recording)
var crop_overlay: VideoCropOverlayScript = null

## UI references
var mode_selector: OptionButton = null
var fps_selector: OptionButton = null
var mic_selector: OptionButton = null
var camera_label: Label = null
var timer_label: Label = null
var record_btn: Button = null
var pause_btn: Button = null
var stop_btn: Button = null
var crop_toggle: CheckButton = null
var status_label: Label = null
var level_bar: ProgressBar = null
var level_label: Label = null

## State
#var _overlay_visible: bool = false


func _ready() -> void:
	z_index = 1000  # Stay on top (same pattern as video_player.gd fullscreen)
	# Start camera monitoring early so feeds are discovered by the time user picks a mode
	WebcamCaptureScript._ensure_monitoring()
	_build_ui()
	_update_ui_state()
	# Re-check camera availability after a short delay (feeds need time to enumerate)
	get_tree().create_timer(1.0).timeout.connect(_refresh_camera_modes)


func _build_ui() -> void:
	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 6)
	add_child(main_vbox)

	# Title bar
	var title := Label.new()
	title.text = "Video Recorder"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(title)

	# Mode + FPS row
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	main_vbox.add_child(mode_row)

	var mode_label := Label.new()
	mode_label.text = "Mode:"
	mode_row.add_child(mode_label)

	mode_selector = OptionButton.new()
	mode_selector.add_item("Viewport", 0)
	mode_selector.add_item("Webcam", 1)
	mode_selector.add_item("PiP", 2)
	mode_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(mode_selector)

	# Webcam/PiP modes start disabled — CameraServer needs async time to enumerate
	# feeds after set_monitoring_feeds(true). _refresh_camera_modes() enables them.
	mode_selector.set_item_disabled(1, true)
	mode_selector.set_item_disabled(2, true)

	var fps_label := Label.new()
	fps_label.text = "FPS:"
	mode_row.add_child(fps_label)

	fps_selector = OptionButton.new()
	fps_selector.add_item("15", 0)
	fps_selector.add_item("24", 1)
	fps_selector.add_item("30", 2)
	fps_selector.selected = 0  # Default 15fps (reduces GPU stall from viewport readback)
	mode_row.add_child(fps_selector)

	# Mic selector row
	var mic_row := HBoxContainer.new()
	mic_row.add_theme_constant_override("separation", 4)
	main_vbox.add_child(mic_row)

	var mic_label := Label.new()
	mic_label.text = "Mic:"
	mic_row.add_child(mic_label)

	mic_selector = OptionButton.new()
	mic_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mic_selector.item_selected.connect(_on_mic_selected)
	mic_row.add_child(mic_selector)
	_populate_mic_list()

	# Camera info label (shown when webcam/PiP mode selected)
	camera_label = Label.new()
	camera_label.text = ""
	camera_label.add_theme_font_size_override("font_size", 11)
	camera_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	main_vbox.add_child(camera_label)
	mode_selector.item_selected.connect(_on_mode_changed)
	_update_camera_label()

	# Audio level meter
	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 4)
	main_vbox.add_child(level_row)

	level_label = Label.new()
	level_label.text = "Level:"
	level_label.add_theme_font_size_override("font_size", 11)
	level_row.add_child(level_label)

	level_bar = ProgressBar.new()
	level_bar.min_value = 0.0
	level_bar.max_value = 1.0
	level_bar.value = 0.0
	level_bar.show_percentage = false
	level_bar.custom_minimum_size = Vector2(120, 12)
	level_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	level_row.add_child(level_bar)

	# Timer + status row
	var timer_row := HBoxContainer.new()
	timer_row.add_theme_constant_override("separation", 8)
	main_vbox.add_child(timer_row)

	timer_label = Label.new()
	timer_label.text = "0:00"
	timer_label.add_theme_font_size_override("font_size", 18)
	timer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timer_row.add_child(timer_label)

	status_label = Label.new()
	status_label.text = "Ready"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	timer_row.add_child(status_label)

	# Buttons row
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	main_vbox.add_child(btn_row)

	record_btn = Button.new()
	record_btn.text = "Record"
	record_btn.pressed.connect(_on_record_pressed)
	btn_row.add_child(record_btn)

	pause_btn = Button.new()
	pause_btn.text = "Pause"
	pause_btn.pressed.connect(_on_pause_pressed)
	pause_btn.disabled = true
	btn_row.add_child(pause_btn)

	stop_btn = Button.new()
	stop_btn.text = "Stop"
	stop_btn.pressed.connect(_on_stop_pressed)
	stop_btn.disabled = true
	btn_row.add_child(stop_btn)

	crop_toggle = CheckButton.new()
	crop_toggle.text = "Crop"
	crop_toggle.toggled.connect(_on_crop_toggled)
	btn_row.add_child(crop_toggle)


func _update_ui_state() -> void:
	var is_recording := recorder != null and recorder.state != VideoRecorderCaptureScript.State.IDLE
	var is_paused := recorder != null and recorder.state == VideoRecorderCaptureScript.State.PAUSED

	record_btn.disabled = is_recording
	pause_btn.disabled = not is_recording
	stop_btn.disabled = not is_recording
	mode_selector.disabled = is_recording
	fps_selector.disabled = is_recording

	if is_paused:
		pause_btn.text = "Resume"
		status_label.text = "Paused"
	elif is_recording:
		pause_btn.text = "Pause"
		status_label.text = "Recording"
	else:
		status_label.text = "Ready"


func _on_record_pressed() -> void:
	var mode_idx := mode_selector.selected
	var mode: VideoRecordingDataScript.Mode
	match mode_idx:
		0: mode = VideoRecordingDataScript.Mode.VIEWPORT
		1: mode = VideoRecordingDataScript.Mode.WEBCAM
		2: mode = VideoRecordingDataScript.Mode.PIP
		_: mode = VideoRecordingDataScript.Mode.VIEWPORT

	var fps_idx := fps_selector.selected
	var fps: int
	match fps_idx:
		0: fps = 15
		1: fps = 24
		_: fps = 30

	# Create recorder
	recorder = VideoRecorderCaptureScript.new()
	add_child(recorder)
	recorder.elapsed_time_updated.connect(_on_elapsed_time_updated)
	recorder.recording_stopped.connect(_on_recording_stopped)

	var err := recorder.start_recording(mode, fps)
	if err != OK:
		SingletonObject.ErrorDisplay("Recording Failed", "Could not start recording: %s" % error_string(err))
		recorder.queue_free()
		recorder = null
		return

	mic_selector.disabled = true
	_update_ui_state()


func _on_pause_pressed() -> void:
	if not recorder:
		return
	if recorder.state == VideoRecorderCaptureScript.State.RECORDING:
		recorder.pause_recording()
	elif recorder.state == VideoRecorderCaptureScript.State.PAUSED:
		recorder.resume_recording()
	_update_ui_state()


func _on_stop_pressed() -> void:
	if not recorder:
		return
	recorder.stop_recording()


func _on_elapsed_time_updated(seconds: float) -> void:
	var minutes := int(seconds/ 60.0)
	var secs := int(seconds) % 60
	timer_label.text = "%d:%02d" % [minutes, secs]


func _on_recording_stopped(recording_data: VideoRecordingDataScript) -> void:
	mic_selector.disabled = false
	_update_ui_state()
	timer_label.text = "0:00"

	# Remove crop overlay if showing
	if crop_overlay:
		crop_overlay.queue_free()
		crop_overlay = null

	# Clean up recorder
	if recorder:
		recorder.queue_free()
		recorder = null

	recording_completed.emit(recording_data)


func _on_crop_toggled(toggled_on: bool) -> void:
	if toggled_on:
		if not crop_overlay:
			crop_overlay = VideoCropOverlayScript.new()
			crop_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
			crop_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
			# Add to viewport root so it overlays everything
			get_tree().root.add_child(crop_overlay)
		crop_overlay.visible = true
	else:
		if crop_overlay:
			crop_overlay.visible = false


func _process(_delta: float) -> void:
	# Update audio level meter while recording
	if recorder and recorder.state != VideoRecorderCaptureScript.State.IDLE:
		level_bar.value = recorder.get_audio_level()
	elif level_bar and level_bar.value > 0.0:
		level_bar.value = 0.0


func _populate_mic_list() -> void:
	mic_selector.clear()
	var devices := AudioServer.get_input_device_list()
	var current := AudioServer.get_input_device()
	for i in devices.size():
		mic_selector.add_item(devices[i], i)
		if devices[i] == current:
			mic_selector.selected = i


func _on_mic_selected(index: int) -> void:
	var device := mic_selector.get_item_text(index)
	AudioServer.set_input_device(device)


func _on_mode_changed(_index: int) -> void:
	_update_camera_label()


func _update_camera_label() -> void:
	var mode_idx := mode_selector.selected
	if mode_idx in [1, 2]:  # Webcam or PiP
		var names := WebcamCaptureScript.get_camera_names()
		if not names.is_empty():
			camera_label.text = "Camera: %s" % names[0]
		else:
			camera_label.text = "Camera: (none found)"
		camera_label.visible = true
	else:
		camera_label.visible = false


func _refresh_camera_modes() -> void:
	var available := WebcamCaptureScript.is_camera_available()
	mode_selector.set_item_disabled(1, not available)
	mode_selector.set_item_disabled(2, not available)


func _exit_tree() -> void:
	if recorder and recorder.state != VideoRecorderCaptureScript.State.IDLE:
		recorder.stop_recording()
	if crop_overlay:
		crop_overlay.queue_free()
		crop_overlay = null
