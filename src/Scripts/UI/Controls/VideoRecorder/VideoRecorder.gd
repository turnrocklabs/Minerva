class_name VideoRecorderCapture
extends Node
## Frame capture engine for recording Minerva's viewport.
## Captures frames via RenderingServer.frame_post_draw with FPS limiting,
## backpressure-based frame skipping, JPEG compression on a background thread,
## and audio via AudioEffectRecord.

signal recording_started()
signal recording_stopped(recording_data: VideoRecordingData)
signal recording_paused()
signal recording_resumed()
signal elapsed_time_updated(seconds: float)

const VideoRecordingDataScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
const WebcamCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/WebcamCapture.gd")

## Recording state
enum State { IDLE, RECORDING, PAUSED }
var state: State = State.IDLE

## Recording data model
var data: VideoRecordingDataScript = null

## Configuration
var target_fps: int = 30
var jpeg_quality: float = 0.85
var recording_mode: VideoRecordingDataScript.Mode = VideoRecordingDataScript.Mode.VIEWPORT

## Internal state
var _last_capture_us: int = 0
var _recording_start_time_us: int = 0
var _pause_offset_us: int = 0
var _pause_start_us: int = 0
var _elapsed_update_timer: float = 0.0

## File handles for streaming writes
var _frames_file: FileAccess = null
var _frames_byte_offset: int = 0
var _webcam_file: FileAccess = null
var _webcam_byte_offset: int = 0

## Webcam capture
var _webcam: WebcamCaptureScript = null

## Audio recording — reuses AudioToText's mic_player and the existing
## AudioEffectRecord at index 0 on the "Rec" bus (proven to work for speech-to-text).
var _audio_effect: AudioEffectRecord = null
var _owns_mic: bool = false  # true if we started the mic and need to stop it
var _bus_modified: bool = false
var _original_rec_bus_muted: bool = true
var _original_rec_bus_volume_db: float = 0.0

## Background thread for JPEG compression + disk writes
var _write_thread: Thread = null
var _write_queue: Array = []  # Array of {type, image, timestamp_us}
var _write_mutex: Mutex = null
var _write_semaphore: Semaphore = null
var _thread_running: bool = false

## PiP position (used during recording)
var pip_position: Vector2 = Vector2(0.85, 0.8)

## Crop position (used during recording)
var crop_x: float = 0.5


func _ready() -> void:
	_write_mutex = Mutex.new()
	_write_semaphore = Semaphore.new()


func _exit_tree() -> void:
	if state != State.IDLE:
		stop_recording()


func _process(delta: float) -> void:
	if state != State.RECORDING:
		return
	# Only update elapsed display — frame capture is driven by frame_post_draw
	_elapsed_update_timer += delta
	if _elapsed_update_timer >= 0.1:
		_elapsed_update_timer = 0.0
		var elapsed_us := _get_elapsed_us()
		elapsed_time_updated.emit(float(elapsed_us) / 1_000_000.0)


## Called after each rendered frame. Applies FPS limiting and backpressure.
func _on_frame_post_draw() -> void:
	if state != State.RECORDING:
		return

	# FPS limiting — skip if not enough time has passed
	var now := Time.get_ticks_usec()
	var frame_interval_us := int(1_000_000.0 / float(target_fps))
	if now - _last_capture_us < frame_interval_us:
		return

	# Backpressure — skip capture if the write thread is backed up
	_write_mutex.lock()
	var queue_size := _write_queue.size()
	_write_mutex.unlock()
	if queue_size > 2:
		return

	_last_capture_us = now
	_capture_frame()


## Start a new recording
func start_recording(mode: VideoRecordingDataScript.Mode = VideoRecordingDataScript.Mode.VIEWPORT, fps: int = 30) -> Error:
	if state != State.IDLE:
		return ERR_ALREADY_IN_USE

	recording_mode = mode
	target_fps = fps

	# Create recording data
	data = VideoRecordingDataScript.new()
	data.mode = mode
	data.fps = fps

	# Get viewport resolution
	var viewport := get_viewport()
	if viewport:
		var vp_size := viewport.get_visible_rect().size
		data.resolution = Vector2i(int(vp_size.x), int(vp_size.y))
	else:
		data.resolution = Vector2i(1920, 1080)

	# Ensure directory
	var err := data.ensure_dir()
	if err != OK:
		push_error("[VideoRecorder] Failed to create recording directory: %s" % error_string(err))
		return err

	# Open frame files
	_frames_file = FileAccess.open(data.get_frames_path(), FileAccess.WRITE)
	if not _frames_file:
		push_error("[VideoRecorder] Failed to open frames file")
		return ERR_FILE_CANT_OPEN
	_frames_byte_offset = 0

	# Open webcam file if needed
	if mode in [VideoRecordingDataScript.Mode.WEBCAM, VideoRecordingDataScript.Mode.PIP]:
		_webcam = WebcamCaptureScript.new()
		if not _webcam.start():
			push_warning("[VideoRecorder] No webcam available, falling back to viewport-only")
			_webcam = null
			if mode == VideoRecordingDataScript.Mode.WEBCAM:
				# Can't do webcam-only without webcam
				_frames_file = null
				return ERR_UNAVAILABLE
			# PiP mode falls back to viewport-only
			data.mode = VideoRecordingDataScript.Mode.VIEWPORT
			recording_mode = VideoRecordingDataScript.Mode.VIEWPORT
		else:
			_webcam_file = FileAccess.open(data.get_webcam_frames_path(), FileAccess.WRITE)
			if not _webcam_file:
				push_warning("[VideoRecorder] Failed to open webcam frames file")
				_webcam.stop()
				_webcam = null

	# Start audio recording
	_start_audio()

	# Start background write thread
	_thread_running = true
	_write_thread = Thread.new()
	_write_thread.start(_write_thread_func)

	# Set timing
	_recording_start_time_us = Time.get_ticks_usec()
	_last_capture_us = 0
	_pause_offset_us = 0
	_elapsed_update_timer = 0.0

	state = State.RECORDING

	# Drive capture from the render loop — fires after each frame is fully drawn
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)

	recording_started.emit()
	print("[VideoRecorder] Recording started (mode=%s, fps=%d)" % [VideoRecordingDataScript.Mode.keys()[mode], fps])
	return OK


## Stop recording and finalize files
func stop_recording() -> void:
	if state == State.IDLE:
		return

	if state == State.PAUSED:
		# Unpause to get correct timing
		_pause_offset_us += Time.get_ticks_usec() - _pause_start_us

	state = State.IDLE

	# Disconnect capture signal
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)

	# Calculate final duration
	var elapsed_us := _get_elapsed_us()
	data.duration_ms = int(elapsed_us / 1000.0)

	# Stop audio
	_stop_audio()

	# Stop webcam
	if _webcam:
		_webcam.stop()
		_webcam = null

	# Stop write thread
	_thread_running = false
	_write_semaphore.post()  # Wake up thread so it can exit
	if _write_thread and _write_thread.is_started():
		_write_thread.wait_to_finish()
	_write_thread = null

	# Close files
	_frames_file = null
	_webcam_file = null

	# Save manifest and indices
	data.save_manifest()
	data.save_frame_index()
	if not data.webcam_frame_index.is_empty():
		data.save_webcam_index()

	# Initialize default edits
	data._init_default_segments()
	data.save_edits()

	print("[VideoRecorder] Recording stopped (duration=%dms, frames=%d)" % [data.duration_ms, data.frame_index.size()])
	recording_stopped.emit(data)


## Pause recording
func pause_recording() -> void:
	if state != State.RECORDING:
		return
	state = State.PAUSED
	_pause_start_us = Time.get_ticks_usec()
	recording_paused.emit()


## Resume recording
func resume_recording() -> void:
	if state != State.PAUSED:
		return
	_pause_offset_us += Time.get_ticks_usec() - _pause_start_us
	state = State.RECORDING
	recording_resumed.emit()


## Get elapsed recording time in microseconds (excluding paused time)
func _get_elapsed_us() -> int:
	if state == State.PAUSED:
		return _pause_start_us - _recording_start_time_us - _pause_offset_us
	return Time.get_ticks_usec() - _recording_start_time_us - _pause_offset_us


#region Frame Capture

func _capture_frame() -> void:
	var timestamp_us := _get_elapsed_us()

	match recording_mode:
		VideoRecordingDataScript.Mode.VIEWPORT:
			# Viewport only → main frame stream
			var image := _capture_viewport_image()
			if image:
				_enqueue_write("viewport", image, timestamp_us)

		VideoRecordingDataScript.Mode.WEBCAM:
			# Webcam only → write webcam as the main frame stream
			if _webcam and _webcam.is_active():
				var image := _webcam.get_frame()
				if image and not image.is_empty():
					_enqueue_write("viewport", image, timestamp_us)

		VideoRecordingDataScript.Mode.PIP:
			# Both: viewport is main, webcam is secondary
			var image := _capture_viewport_image()
			if image:
				_enqueue_write("viewport", image, timestamp_us)
			if _webcam and _webcam.is_active():
				var webcam_image := _webcam.get_frame()
				if webcam_image and not webcam_image.is_empty():
					_enqueue_write("webcam", webcam_image, timestamp_us)


func _capture_viewport_image() -> Image:
	var viewport := get_viewport()
	if not viewport:
		return null
	var vp_texture := viewport.get_texture()
	if not vp_texture:
		return null
	var image := vp_texture.get_image()
	if image and not image.is_empty():
		return image
	return null


func _enqueue_write(type: String, image: Image, timestamp_us: int) -> void:
	_write_mutex.lock()
	_write_queue.append({
		"type": type,
		"image": image,
		"timestamp_us": timestamp_us,
	})
	_write_mutex.unlock()
	_write_semaphore.post()

#endregion


#region Background Write Thread

func _write_thread_func() -> void:
	while _thread_running:
		_write_semaphore.wait()
		if not _thread_running:
			break

		# Process all queued writes
		_write_mutex.lock()
		var queue := _write_queue.duplicate()
		_write_queue.clear()
		_write_mutex.unlock()

		for item in queue:
			_process_write(item)

	# Drain remaining queue
	_write_mutex.lock()
	var remaining := _write_queue.duplicate()
	_write_queue.clear()
	_write_mutex.unlock()

	for item in remaining:
		_process_write(item)


func _process_write(item: Dictionary) -> void:
	var image: Image = item.image
	var timestamp_us: int = item.timestamp_us

	# Compress to JPEG
	var jpeg_buffer := image.save_jpg_to_buffer(jpeg_quality)
	if jpeg_buffer.is_empty():
		return

	if item.type == "viewport" and _frames_file:
		# Write frame size header (4 bytes) + JPEG data
		_frames_file.store_32(jpeg_buffer.size())
		_frames_file.store_buffer(jpeg_buffer)

		# Record index entry
		data.append_frame_index_entry(_frames_byte_offset, timestamp_us)
		_frames_byte_offset += 4 + jpeg_buffer.size()

	elif item.type == "webcam" and _webcam_file:
		_webcam_file.store_32(jpeg_buffer.size())
		_webcam_file.store_buffer(jpeg_buffer)

		data.append_webcam_frame_index_entry(_webcam_byte_offset, timestamp_us)
		_webcam_byte_offset += 4 + jpeg_buffer.size()

#endregion


#region Audio Recording

func _start_audio() -> void:
	var bus_idx := AudioServer.get_bus_index("Rec")
	if bus_idx == -1:
		push_warning("[VideoRecorder] No 'Rec' audio bus found, recording without audio")
		return

	# Use the existing AudioEffectRecord at index 0 (defined in default_bus_layout.tres).
	_audio_effect = AudioServer.get_bus_effect(bus_idx, 0) as AudioEffectRecord
	if not _audio_effect:
		push_warning("[VideoRecorder] No AudioEffectRecord on 'Rec' bus at index 0")
		return

	if _audio_effect.is_recording_active():
		push_warning("[VideoRecorder] AudioEffectRecord already active (speech-to-text in use?)")
		_audio_effect = null
		return

	# Reuse AudioToText's mic_player — it's already in the tree on the "Rec" bus
	# and proven to work for push-to-talk speech capture.
	var att := SingletonObject.AtT
	if not att.mic_player.playing:
		att._start_mic()
		_owns_mic = true
	else:
		_owns_mic = false  # mic was already running, don't stop it later

	_audio_effect.set_recording_active(true)

	# Unmute "Rec" bus at very low volume (-60 dB) so peak metering works.
	# At -60 dB the signal is 0.001x full volume — inaudible but meters register.
	_original_rec_bus_muted = AudioServer.is_bus_mute(bus_idx)
	_original_rec_bus_volume_db = AudioServer.get_bus_volume_db(bus_idx)
	AudioServer.set_bus_mute(bus_idx, false)
	AudioServer.set_bus_volume_db(bus_idx, -60.0)
	_bus_modified = true

	print("[VideoRecorder] Audio started: mic=%s, playing=%s" % [
		AudioServer.get_input_device(), att.mic_player.playing])


func _stop_audio() -> void:
	if _audio_effect and _audio_effect.is_recording_active():
		var recording := _audio_effect.get_recording()
		_audio_effect.set_recording_active(false)

		if recording and data:
			recording.save_to_wav(data.get_audio_path())
			var f := FileAccess.open(data.get_audio_path(), FileAccess.READ)
			if f:
				print("[VideoRecorder] Audio saved: %s (%d bytes)" % [data.get_audio_path(), f.get_length()])
			else:
				push_warning("[VideoRecorder] Audio WAV file not found after save")
		else:
			push_warning("[VideoRecorder] No audio recording data (recording=%s)" % [recording != null])

	_audio_effect = null

	# Restore "Rec" bus to its original muted state
	if _bus_modified:
		var restore_idx := AudioServer.get_bus_index("Rec")
		if restore_idx >= 0:
			AudioServer.set_bus_volume_db(restore_idx, _original_rec_bus_volume_db)
			AudioServer.set_bus_mute(restore_idx, _original_rec_bus_muted)
		_bus_modified = false

	# Stop the mic only if we started it
	if _owns_mic:
		SingletonObject.AtT._stop_mic()
		_owns_mic = false


## Read audio level (0.0 - 1.0) via bus peak metering.
## During recording the "Rec" bus is unmuted at -60 dB so meters register.
## We compensate the reading by +60 dB to get the true signal level.
func get_audio_level() -> float:
	if not _audio_effect or not _audio_effect.is_recording_active():
		return 0.0
	var bus_idx := AudioServer.get_bus_index("Rec")
	if bus_idx >= 0:
		var peak_db := AudioServer.get_bus_peak_volume_left_db(bus_idx, 0)
		# Compensate for the -60 dB bus volume we set for metering
		var compensated_db := peak_db + 60.0
		return clampf(db_to_linear(compensated_db), 0.0, 1.0)
	return 0.0

#endregion


#region Frame Reading (for playback/export)

## Read a single viewport frame by index from frames.bin
static func read_frame(recording_data: VideoRecordingDataScript, frame_idx: int) -> Image:
	if frame_idx < 0 or frame_idx >= recording_data.frame_index.size():
		return null

	var offset: int = recording_data.frame_index[frame_idx][0]
	var f := FileAccess.open(recording_data.get_frames_path(), FileAccess.READ)
	if not f:
		return null

	f.seek(offset)
	var jpeg_size := f.get_32()
	var jpeg_data := f.get_buffer(jpeg_size)

	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg_data) != OK:
		return null
	return image


## Read a single webcam frame by index
static func read_webcam_frame(recording_data: VideoRecordingDataScript, frame_idx: int) -> Image:
	if frame_idx < 0 or frame_idx >= recording_data.webcam_frame_index.size():
		return null

	var offset: int = recording_data.webcam_frame_index[frame_idx][0]
	var f := FileAccess.open(recording_data.get_webcam_frames_path(), FileAccess.READ)
	if not f:
		return null

	f.seek(offset)
	var jpeg_size := f.get_32()
	var jpeg_data := f.get_buffer(jpeg_size)

	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg_data) != OK:
		return null
	return image

#endregion
