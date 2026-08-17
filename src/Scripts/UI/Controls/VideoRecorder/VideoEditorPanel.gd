class_name VideoEditorPanel
extends PanelContainer
## Video editor panel for editing recorded videos.
## Provides toolbar, preview area with PiP/crop overlay, and timeline.

const VideoRecordingDataScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
const VideoRecorderCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecorder.gd")
const VideoTimelineScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoTimeline.gd")
const VideoCropOverlayScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoCropOverlay.gd")
const VideoExporterScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoExporter.gd")

signal data_changed()

## Recording data model
var data: VideoRecordingDataScript = null

## Unique editor instance ID
var editor_id: String = ""

## UI References
var toolbar: HBoxContainer = null
var preview_container: PanelContainer = null
var preview_texture_rect: TextureRect = null
var crop_overlay: VideoCropOverlayScript = null
var timeline: VideoTimelineScript = null
var time_label: Label = null
var duration_label: Label = null

## Playback state
var _playing: bool = false
var _playback_timer: float = 0.0
var _current_frame_idx: int = -1

## Audio playback — plays on "VideoBus" (not muted, routes to Master/speakers)
var _audio_player: AudioStreamPlayer = null
var _audio_stream: AudioStreamWAV = null

## Context menu
var _context_menu: PopupMenu = null

## Export progress dialog
var _export_dialog: AcceptDialog = null
var _export_progress: ProgressBar = null
var _export_label: Label = null

## Exporter
var _exporter: VideoExporterScript = null


var _ui_built: bool = false

func _ready() -> void:
	editor_id = str(randi() % 1000000).pad_zeros(6)
	_ensure_ui()


func _ensure_ui() -> void:
	if _ui_built:
		return
	_ui_built = true
	_build_ui()
	_setup_context_menu()


func _build_ui() -> void:
	var main_vbox := VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	toolbar_scroll.custom_minimum_size.y = 36
	main_vbox.add_child(toolbar_scroll)
	toolbar = _create_toolbar()
	toolbar_scroll.add_child(toolbar)

	# Preview + Timeline split
	var split := VSplitContainer.new()
	split.name = "MainSplit"
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(split)

	# Preview area
	preview_container = PanelContainer.new()
	preview_container.name = "PreviewContainer"
	preview_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_container.clip_contents = true
	split.add_child(preview_container)

	preview_texture_rect = TextureRect.new()
	preview_texture_rect.name = "PreviewTexture"
	preview_texture_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	preview_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_container.add_child(preview_texture_rect)

	# Crop overlay (over preview)
	crop_overlay = VideoCropOverlayScript.new()
	crop_overlay.name = "CropOverlay"
	crop_overlay.visible = false
	crop_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	crop_overlay.crop_position_changed.connect(_on_crop_position_changed)
	preview_container.add_child(crop_overlay)

	# Audio player for preview playback (same bus as video_player.tscn)
	_audio_player = AudioStreamPlayer.new()
	_audio_player.bus = &"VideoBus"
	add_child(_audio_player)

	# Timeline
	timeline = VideoTimelineScript.new()
	timeline.name = "Timeline"
	timeline.custom_minimum_size.y = 120
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.playhead_moved.connect(_on_playhead_moved)
	timeline.context_menu_requested.connect(_on_context_menu_requested)
	split.add_child(timeline)


func _create_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.add_theme_constant_override("separation", 4)

	# Play/Pause button
	var play_btn := Button.new()
	play_btn.name = "PlayButton"
	play_btn.text = "Play"
	play_btn.pressed.connect(_on_play_pressed)
	tb.add_child(play_btn)

	# Stop button
	var stop_btn := Button.new()
	stop_btn.name = "StopButton"
	stop_btn.text = "Stop"
	stop_btn.pressed.connect(_on_stop_pressed)
	tb.add_child(stop_btn)

	tb.add_child(VSeparator.new())

	# Time display
	time_label = Label.new()
	time_label.name = "TimeLabel"
	time_label.text = "0:00.000"
	time_label.custom_minimum_size.x = 80
	tb.add_child(time_label)

	var slash_label := Label.new()
	slash_label.text = "/"
	tb.add_child(slash_label)

	duration_label = Label.new()
	duration_label.name = "DurationLabel"
	duration_label.text = "0:00.000"
	duration_label.custom_minimum_size.x = 80
	tb.add_child(duration_label)

	tb.add_child(VSeparator.new())

	# Undo/Redo
	var undo_btn := Button.new()
	undo_btn.name = "UndoButton"
	undo_btn.text = "Undo"
	undo_btn.pressed.connect(_on_undo_pressed)
	tb.add_child(undo_btn)

	var redo_btn := Button.new()
	redo_btn.name = "RedoButton"
	redo_btn.text = "Redo"
	redo_btn.pressed.connect(_on_redo_pressed)
	tb.add_child(redo_btn)

	tb.add_child(VSeparator.new())

	# Show crop overlay toggle
	var crop_toggle := CheckButton.new()
	crop_toggle.name = "CropToggle"
	crop_toggle.text = "Show Crop"
	crop_toggle.toggled.connect(_on_crop_toggle)
	tb.add_child(crop_toggle)

	tb.add_child(VSeparator.new())

	# Export buttons
	var export_16_9_btn := Button.new()
	export_16_9_btn.name = "Export16x9"
	export_16_9_btn.text = "Export 16:9"
	export_16_9_btn.pressed.connect(_on_export_16_9_pressed)
	tb.add_child(export_16_9_btn)

	var export_9_16_btn := Button.new()
	export_9_16_btn.name = "Export9x16"
	export_9_16_btn.text = "Export 9:16"
	export_9_16_btn.pressed.connect(_on_export_9_16_pressed)
	tb.add_child(export_9_16_btn)

	return tb


func _setup_context_menu() -> void:
	_context_menu = PopupMenu.new()
	_context_menu.name = "TimelineContextMenu"
	_context_menu.add_item("Mark Cut Start", 0)
	_context_menu.add_item("Mark Cut End", 1)
	_context_menu.add_separator()
	_context_menu.add_item("Mark Speed Start", 2)
	_context_menu.add_item("Mark Speed End (2x)", 3)
	_context_menu.add_item("Mark Speed End (3x)", 4)
	_context_menu.add_item("Mark Speed End (5x)", 5)
	_context_menu.add_separator()
	_context_menu.add_item("Remove Selected Segment", 6)
	_context_menu.add_separator()
	_context_menu.add_item("Set Crop Keyframe Here", 7)
	_context_menu.add_item("Set PiP Keyframe Here", 8)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)


## Load a recording into the editor
func load_recording(recording_data_: VideoRecordingDataScript) -> void:
	_ensure_ui()
	data = recording_data_
	timeline.set_recording_data(data)

	if data:
		duration_label.text = VideoTimelineScript.format_time(data.duration_ms)
		_load_audio()
		_show_frame_at_time(0)
	else:
		duration_label.text = "0:00.000"
		_audio_stream = null

	data_changed.emit()


## Load from recording path
func load_from_path(recording_path: String) -> bool:
	# Extract recording ID from path
	var id := recording_path.get_file()
	if id.is_empty():
		id = recording_path.rstrip("/").get_file()

	var recording := VideoRecordingDataScript.load_recording(id)
	if not recording:
		push_error("[VideoEditorPanel] Failed to load recording: %s" % recording_path)
		return false

	load_recording(recording)
	return true


#region Playback

func _process(delta: float) -> void:
	if not _playing or not data:
		return

	_playback_timer += delta * 1000.0  # Convert to ms

	# Skip cut segments, adjust for speed
	var effective_time := _get_effective_time(int(_playback_timer))

	if effective_time >= data.duration_ms:
		_stop_playback()
		return

	timeline.playhead_ms = effective_time
	_show_frame_at_time(effective_time)
	time_label.text = VideoTimelineScript.format_time(effective_time)


func _get_effective_time(elapsed_ms: int) -> int:
	# Map playback elapsed time to source time considering edits
	var remaining := elapsed_ms

	for seg in data.segments:
		var seg_duration: int = seg.end_ms - seg.start_ms

		match seg.type:
			VideoRecordingDataScript.SegmentType.CUT:
				continue  # Skip cuts entirely
			VideoRecordingDataScript.SegmentType.NORMAL:
				if remaining <= seg_duration:
					return seg.start_ms + remaining
				remaining -= seg_duration
			VideoRecordingDataScript.SegmentType.FAST_FORWARD:
				var effective_duration := int(float(seg_duration) / seg.get("speed", 3.0))
				if remaining <= effective_duration:
					var progress := float(remaining) / float(effective_duration)
					return seg.start_ms + int(progress * seg_duration)
				remaining -= effective_duration

	return data.duration_ms


func _show_frame_at_time(time_ms: int) -> void:
	if not data:
		return

	var frame_idx := data.get_frame_at_time(time_ms)
	if frame_idx == _current_frame_idx:
		return
	_current_frame_idx = frame_idx

	var image := VideoRecorderCaptureScript.read_frame(data, frame_idx)
	if image and not image.is_empty():
		# Composite PiP if applicable
		if data.mode == VideoRecordingDataScript.Mode.PIP:
			var webcam_img := VideoRecorderCaptureScript.read_webcam_frame(data, frame_idx)
			if webcam_img and not webcam_img.is_empty():
				image = _composite_pip_preview(image, webcam_img, time_ms)

		var tex := ImageTexture.create_from_image(image)
		preview_texture_rect.texture = tex


func _composite_pip_preview(base: Image, webcam: Image, time_ms: int) -> Image:
	var pip_pos := data.get_pip_position_at(time_ms)
	var pip_diameter := int(base.get_width() * 0.15)
	var pip_center_x := int(pip_pos.x * base.get_width())
	var pip_center_y := int(pip_pos.y * base.get_height())

	webcam.resize(pip_diameter, pip_diameter)
	var radius := floori(pip_diameter / 2.0)

	for y in pip_diameter:
		for x in pip_diameter:
			var dx := x - radius
			var dy := y - radius
			if dx * dx + dy * dy <= radius * radius:
				var src_color := webcam.get_pixel(x, y)
				var dst_x := pip_center_x - radius + x
				var dst_y := pip_center_y - radius + y
				if dst_x >= 0 and dst_x < base.get_width() and dst_y >= 0 and dst_y < base.get_height():
					base.set_pixel(dst_x, dst_y, src_color)

	return base

#endregion


#region Toolbar Handlers

func _on_play_pressed() -> void:
	if _playing:
		_playing = false
		if _audio_player.playing:
			_audio_player.stop()
		toolbar.get_node("PlayButton").text = "Play"
	else:
		_playing = true
		_playback_timer = float(timeline.playhead_ms)
		toolbar.get_node("PlayButton").text = "Pause"
		# Start audio from the current playhead position
		_play_audio_from(timeline.playhead_ms)


func _on_stop_pressed() -> void:
	_stop_playback()
	timeline.playhead_ms = 0
	_show_frame_at_time(0)
	time_label.text = VideoTimelineScript.format_time(0)


func _stop_playback() -> void:
	_playing = false
	if _audio_player and _audio_player.playing:
		_audio_player.stop()
	toolbar.get_node("PlayButton").text = "Play"


func _load_audio() -> void:
	_audio_stream = null
	if not data:
		return
	var audio_path := data.get_audio_path()
	if not FileAccess.file_exists(audio_path):
		print("[VideoEditorPanel] No audio file: %s" % audio_path)
		return
	_audio_stream = AudioStreamWAV.new()
	var f := FileAccess.open(audio_path, FileAccess.READ)
	if not f:
		return
	# Parse WAV header to get format info
	var riff := f.get_buffer(4).get_string_from_ascii()  # "RIFF"
	f.get_32()  # file size
	var wave := f.get_buffer(4).get_string_from_ascii()  # "WAVE"
	if riff != "RIFF" or wave != "WAVE":
		push_warning("[VideoEditorPanel] Invalid WAV file: %s" % audio_path)
		_audio_stream = null
		return
	# Read chunks until we find "fmt " and "data"
	var format_tag: int = 1
	var channels: int = 1
	var sample_rate: int = 44100
	var bits_per_sample: int = 16
	while f.get_position() < f.get_length():
		var chunk_id := f.get_buffer(4).get_string_from_ascii()
		var chunk_size := f.get_32()
		if chunk_id == "fmt ":
			format_tag = f.get_16()
			channels = f.get_16()
			sample_rate = f.get_32()
			f.get_32()  # byte rate
			f.get_16()  # block align
			bits_per_sample = f.get_16()
			if chunk_size > 16:
				f.seek(f.get_position() + chunk_size - 16)
			# AudioStreamWAV only handles uncompressed PCM (format tag 1). The tag
			# was read but never checked, so float/compressed WAVs were decoded as
			# PCM and played back as garbage instead of being rejected.
			if format_tag != 1:
				push_warning("[VideoEditorPanel] Unsupported WAV format tag %d (expected PCM) in %s" % [format_tag, audio_path])
				_audio_stream = null
				return
		elif chunk_id == "data":
			var audio_data := f.get_buffer(chunk_size)
			_audio_stream.data = audio_data
			_audio_stream.mix_rate = sample_rate
			_audio_stream.stereo = channels >= 2
			match bits_per_sample:
				8: _audio_stream.format = AudioStreamWAV.FORMAT_8_BITS
				16: _audio_stream.format = AudioStreamWAV.FORMAT_16_BITS
				_: _audio_stream.format = AudioStreamWAV.FORMAT_16_BITS
			break
		else:
			f.seek(f.get_position() + chunk_size)
	print("[VideoEditorPanel] Audio loaded: %dHz, %dch, %dbit" % [sample_rate, channels, bits_per_sample])


func _play_audio_from(time_ms: int) -> void:
	if not _audio_stream or not _audio_player:
		return
	_audio_player.stream = _audio_stream
	_audio_player.play(float(time_ms) / 1000.0)


func _on_undo_pressed() -> void:
	if data and data.undo():
		timeline.queue_redraw()
		data_changed.emit()


func _on_redo_pressed() -> void:
	if data and data.redo():
		timeline.queue_redraw()
		data_changed.emit()


func _on_crop_toggle(toggled_on: bool) -> void:
	crop_overlay.visible = toggled_on
	if toggled_on and data:
		crop_overlay.crop_x = data.get_crop_x_at(timeline.playhead_ms)


func _on_export_16_9_pressed() -> void:
	_start_export(VideoExporterScript.AspectRatio.LANDSCAPE_16_9)


func _on_export_9_16_pressed() -> void:
	_start_export(VideoExporterScript.AspectRatio.PORTRAIT_9_16)

#endregion


#region Timeline/Crop Handlers

func _on_playhead_moved(time_ms: int) -> void:
	_show_frame_at_time(time_ms)
	time_label.text = VideoTimelineScript.format_time(time_ms)
	if crop_overlay.visible:
		crop_overlay.crop_x = data.get_crop_x_at(time_ms)
	# Seek audio if playing
	if _playing and _audio_player and _audio_stream:
		_playback_timer = float(time_ms)
		_play_audio_from(time_ms)


func _on_crop_position_changed(x: float) -> void:
	if data:
		data.set_crop_position(timeline.playhead_ms, x)
		timeline.queue_redraw()
		data_changed.emit()


var _cut_start_ms: int = -1
var _speed_start_ms: int = -1

func _on_context_menu_requested(time_ms: int, global_pos: Vector2) -> void:
	_context_menu.position = Vector2i(int(global_pos.x), int(global_pos.y))
	_context_menu.set_meta("time_ms", time_ms)
	_context_menu.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	var time_ms: int = _context_menu.get_meta("time_ms", 0)

	match id:
		0:  # Mark Cut Start
			_cut_start_ms = time_ms
			SingletonObject.create_toast_notification("Cut start marked at %s" % VideoTimelineScript.format_time(time_ms), ToastNotification.Type.INFO)
		1:  # Mark Cut End
			if _cut_start_ms >= 0 and time_ms > _cut_start_ms:
				data.add_cut(_cut_start_ms, time_ms)
				_cut_start_ms = -1
				timeline.queue_redraw()
				data_changed.emit()
				SingletonObject.create_toast_notification("Cut region added", ToastNotification.Type.INFO)
		2:  # Mark Speed Start
			_speed_start_ms = time_ms
			SingletonObject.create_toast_notification("Speed start marked at %s" % VideoTimelineScript.format_time(time_ms), ToastNotification.Type.INFO)
		3:  # Speed End 2x
			_apply_speed_region(time_ms, 2.0)
		4:  # Speed End 3x
			_apply_speed_region(time_ms, 3.0)
		5:  # Speed End 5x
			_apply_speed_region(time_ms, 5.0)
		6:  # Remove Selected Segment
			if timeline._selected_segment >= 0:
				data.remove_segment(timeline._selected_segment)
				timeline._selected_segment = -1
				timeline.queue_redraw()
				data_changed.emit()
		7:  # Set Crop Keyframe
			if data:
				data.set_crop_position(time_ms, crop_overlay.crop_x)
				timeline.queue_redraw()
				data_changed.emit()
		8:  # Set PiP Keyframe
			if data:
				data.set_pip_position(time_ms, data.get_pip_position_at(time_ms))
				timeline.queue_redraw()
				data_changed.emit()


func _apply_speed_region(end_ms: int, speed: float) -> void:
	if _speed_start_ms >= 0 and end_ms > _speed_start_ms:
		data.add_speed_region(_speed_start_ms, end_ms, speed)
		_speed_start_ms = -1
		timeline.queue_redraw()
		data_changed.emit()
		SingletonObject.create_toast_notification("Speed region added (%.1fx)" % speed, ToastNotification.Type.INFO)

#endregion


#region Export

func _start_export(aspect_ratio: VideoExporterScript.AspectRatio) -> void:
	if not data:
		SingletonObject.ErrorDisplay("Export Failed", "No recording loaded")
		return

	if not VideoExporterScript.is_ffmpeg_available():
		SingletonObject.ErrorDisplay("Export Failed",
			"ffmpeg not found. Please install ffmpeg and ensure it is in your PATH.\n\n" +
			"Linux: sudo apt install ffmpeg\n" +
			"macOS: brew install ffmpeg\n" +
			"Windows: Download from ffmpeg.org")
		return

	# Show save dialog
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.filters = PackedStringArray(["*.mp4 ; MP4 Video"])
	dialog.title = "Export Video"

	var aspect_str := "16x9" if aspect_ratio == VideoExporterScript.AspectRatio.LANDSCAPE_16_9 else "9x16"
	dialog.current_file = "recording_%s_%s.mp4" % [data.recording_id.substr(0, 8), aspect_str]

	dialog.file_selected.connect(func(path: String):
		_do_export(path, aspect_ratio)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())

	add_child(dialog)
	dialog.popup_centered(Vector2i(700, 500))


func _do_export(output_path: String, aspect_ratio: VideoExporterScript.AspectRatio) -> void:
	# Create export progress dialog
	_export_dialog = AcceptDialog.new()
	_export_dialog.title = "Exporting Video..."
	_export_dialog.exclusive = true

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(400, 100)
	_export_dialog.add_child(vbox)

	_export_label = Label.new()
	_export_label.text = "Starting export..."
	vbox.add_child(_export_label)

	_export_progress = ProgressBar.new()
	_export_progress.custom_minimum_size.y = 24
	vbox.add_child(_export_progress)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func():
		if _exporter:
			_exporter.cancel()
	)
	vbox.add_child(cancel_btn)

	add_child(_export_dialog)
	_export_dialog.popup_centered()

	# Create exporter and run
	_exporter = VideoExporterScript.new()
	_exporter.export_progress.connect(_on_export_progress)
	_exporter.export_completed.connect(_on_export_completed)
	_exporter.export_failed.connect(_on_export_failed)
	_exporter.export_video(data, output_path, aspect_ratio)


func _on_export_progress(percent: float, message: String) -> void:
	if _export_progress:
		_export_progress.value = percent
	if _export_label:
		_export_label.text = message


func _on_export_completed(output_path: String) -> void:
	if _export_dialog:
		_export_dialog.queue_free()
		_export_dialog = null
	SingletonObject.create_toast_notification("Video exported to: %s" % output_path.get_file(), ToastNotification.Type.INFO)
	# Offer to open in file browser
	OS.shell_open(output_path.get_base_dir())
	_exporter = null


func _on_export_failed(error: String) -> void:
	if _export_dialog:
		_export_dialog.queue_free()
		_export_dialog = null
	SingletonObject.ErrorDisplay("Export Failed", error)
	_exporter = null

#endregion


#region MCP API Methods (called by MinervaMCPServer)

func get_state_dict() -> Dictionary:
	if not data:
		return {"error": "No recording loaded"}
	return {
		"recording_id": data.recording_id,
		"mode": VideoRecordingDataScript.Mode.keys()[data.mode],
		"duration_ms": data.duration_ms,
		"effective_duration_ms": data.get_effective_duration_ms(),
		"fps": data.fps,
		"resolution": [data.resolution.x, data.resolution.y],
		"segments": data._segments_to_array(),
		"pip_keyframes": data._pip_keyframes_to_array(),
		"crop_keyframes": data._crop_keyframes_to_array(),
		"playhead_ms": timeline.playhead_ms,
	}


func mcp_add_cut(start_ms: int, end_ms: int) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	if data.add_cut(start_ms, end_ms):
		timeline.queue_redraw()
		data_changed.emit()
		return {"success": true, "effective_duration_ms": data.get_effective_duration_ms()}
	return {"success": false, "error": "Invalid cut range"}


func mcp_add_speed_region(start_ms: int, end_ms: int, speed: float) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	if data.add_speed_region(start_ms, end_ms, speed):
		timeline.queue_redraw()
		data_changed.emit()
		return {"success": true, "effective_duration_ms": data.get_effective_duration_ms()}
	return {"success": false, "error": "Invalid speed region range"}


func mcp_remove_edit(segment_index: int) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	if data.remove_segment(segment_index):
		timeline.queue_redraw()
		data_changed.emit()
		return {"success": true}
	return {"success": false, "error": "Invalid segment index or cannot remove normal segments"}


func mcp_set_pip_position(time_ms: int, x: float, y: float) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	data.set_pip_position(time_ms, Vector2(x, y))
	timeline.queue_redraw()
	data_changed.emit()
	return {"success": true}


func mcp_set_crop_position(time_ms: int, x: float) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	data.set_crop_position(time_ms, x)
	timeline.queue_redraw()
	data_changed.emit()
	return {"success": true}


func mcp_export(output_path: String, aspect_ratio_str: String) -> Dictionary:
	if not data:
		return {"success": false, "error": "No recording loaded"}
	if not VideoExporterScript.is_ffmpeg_available():
		return {"success": false, "error": "ffmpeg not found in PATH"}

	var aspect_ratio: VideoExporterScript.AspectRatio
	if aspect_ratio_str == "9:16":
		aspect_ratio = VideoExporterScript.AspectRatio.PORTRAIT_9_16
	else:
		aspect_ratio = VideoExporterScript.AspectRatio.LANDSCAPE_16_9

	# Save edits before export
	data.save_edits()

	var exporter := VideoExporterScript.new()
	exporter.export_video(data, output_path, aspect_ratio)

	# Wait for completion (blocking for MCP)
	# Note: In practice this should use await, but MCP calls are synchronous
	return {"success": true, "message": "Export started to: %s" % output_path}

#endregion
