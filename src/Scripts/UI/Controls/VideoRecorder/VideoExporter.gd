class_name VideoExporter
extends RefCounted
## Exports video recordings to MP4 via ffmpeg CLI.
## Handles edit list processing (cuts, speed, PiP compositing, crop).

const VideoRecordingDataScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
const VideoRecorderCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecorder.gd")

signal export_progress(percent: float, message: String)
signal export_completed(output_path: String)
signal export_failed(error: String)

## Export aspect ratios
enum AspectRatio { LANDSCAPE_16_9, PORTRAIT_9_16 }

## Export state
var _exporting: bool = false
var _cancelled: bool = false
var _temp_dir: String = ""
var _process_id: int = -1


## Check if ffmpeg is available
static func is_ffmpeg_available() -> bool:
	var output: Array = []
	var exit_code := OS.execute("ffmpeg", ["-version"], output, true)
	return exit_code == 0


## Export a recording to MP4
func export_video(recording_data: VideoRecordingDataScript, output_path: String, aspect_ratio: AspectRatio = AspectRatio.LANDSCAPE_16_9) -> void:
	if _exporting:
		export_failed.emit("Export already in progress")
		return

	if not is_ffmpeg_available():
		export_failed.emit("ffmpeg not found. Please install ffmpeg and ensure it's in your PATH.")
		return

	_exporting = true
	_cancelled = false

	# Create temp directory for processed frames
	_temp_dir = OS.get_user_data_dir().path_join("video_export_temp_" + str(randi()))
	DirAccess.make_dir_recursive_absolute(_temp_dir)

	export_progress.emit(0.0, "Processing frames...")

	# Process frames according to edit list
	var frame_result := _process_frames(recording_data, aspect_ratio)
	if not frame_result.success:
		_cleanup()
		export_failed.emit(frame_result.error)
		return

	if _cancelled:
		_cleanup()
		export_failed.emit("Export cancelled")
		return

	export_progress.emit(60.0, "Processing audio...")

	# Process audio
	var audio_path := _process_audio(recording_data)

	export_progress.emit(80.0, "Encoding video...")

	# Encode with ffmpeg
	var encode_result := _encode_ffmpeg(recording_data, output_path, audio_path, aspect_ratio, frame_result.frame_count)
	if not encode_result.success:
		_cleanup()
		export_failed.emit(encode_result.error)
		return

	export_progress.emit(100.0, "Complete!")
	_cleanup()
	export_completed.emit(output_path)


## Cancel an in-progress export
func cancel() -> void:
	_cancelled = true
	if _process_id >= 0:
		OS.kill(_process_id)
		_process_id = -1


#region Frame Processing

func _process_frames(recording_data: VideoRecordingDataScript, aspect_ratio: AspectRatio) -> Dictionary:
	var frame_count := 0
	var total_source_frames := recording_data.frame_index.size()
	if total_source_frames == 0:
		return {"success": false, "error": "No frames in recording"}

	for seg in recording_data.segments:
		if _cancelled:
			return {"success": false, "error": "Cancelled"}

		match seg.type:
			VideoRecordingDataScript.SegmentType.CUT:
				continue  # Skip cut segments

			VideoRecordingDataScript.SegmentType.NORMAL:
				frame_count = _write_segment_frames(
					recording_data, seg.start_ms, seg.end_ms,
					1.0, aspect_ratio, frame_count, total_source_frames
				)

			VideoRecordingDataScript.SegmentType.FAST_FORWARD:
				frame_count = _write_segment_frames(
					recording_data, seg.start_ms, seg.end_ms,
					seg.get("speed", 3.0), aspect_ratio, frame_count, total_source_frames
				)

	return {"success": true, "frame_count": frame_count}


func _write_segment_frames(recording_data: VideoRecordingDataScript, start_ms: int, end_ms: int,
		speed: float, aspect_ratio: AspectRatio, frame_number: int, total_frames: int) -> int:
	var start_frame := recording_data.get_frame_at_time(start_ms)
	var end_frame := recording_data.get_frame_at_time(end_ms)
	if start_frame < 0:
		start_frame = 0
	if end_frame < 0:
		end_frame = recording_data.frame_index.size() - 1

	# For fast-forward, skip frames based on speed
	var step := int(max(1, speed))

	var i := start_frame
	while i <= end_frame:
		if _cancelled:
			return frame_number

		var image := VideoRecorderCaptureScript.read_frame(recording_data, i)
		if image and not image.is_empty():
			# Composite PiP if applicable
			if recording_data.mode == VideoRecordingDataScript.Mode.PIP:
				var time_ms := int(recording_data.frame_index[i][1] / 1000)
				image = _composite_pip(recording_data, image, i, time_ms)

			# Apply crop for 9:16
			if aspect_ratio == AspectRatio.PORTRAIT_9_16:
				var time_ms := int(recording_data.frame_index[i][1] / 1000)
				image = _apply_crop(recording_data, image, time_ms)

			# Save as numbered JPEG
			var filename := "frame_%06d.jpg" % frame_number
			image.save_jpg(_temp_dir.path_join(filename), 0.95)
			frame_number += 1

		# Update progress (frames are 0-60% of total). `i` is an absolute index into
		# the source frame_index, so measuring it against the whole recording keeps
		# progress monotonic across segments — measuring it against this segment's
		# own span made the bar restart from 0% on every segment.
		var progress := float(i) / float(max(1, total_frames))
		export_progress.emit(clampf(progress, 0.0, 1.0) * 60.0, "Processing frame %d..." % frame_number)

		i += step

	return frame_number


func _composite_pip(recording_data: VideoRecordingDataScript, base_image: Image, frame_idx: int, time_ms: int) -> Image:
	var webcam_image := VideoRecorderCaptureScript.read_webcam_frame(recording_data, frame_idx)
	if not webcam_image or webcam_image.is_empty():
		return base_image

	var pip_pos := recording_data.get_pip_position_at(time_ms)

	# PiP circle: 15% of frame width
	var pip_diameter := int(base_image.get_width() * 0.15)
	var pip_center_x := int(pip_pos.x * base_image.get_width())
	var pip_center_y := int(pip_pos.y * base_image.get_height())

	# Resize webcam to fit PiP
	webcam_image.resize(pip_diameter, pip_diameter)

	# Create circular mask and composite
	var radius := floori(pip_diameter / 2.0)
	for y in pip_diameter:
		for x in pip_diameter:
			var dx := x - radius
			var dy := y - radius
			if dx * dx + dy * dy <= radius * radius:
				var src_color := webcam_image.get_pixel(x, y)
				var dst_x := pip_center_x - radius + x
				var dst_y := pip_center_y - radius + y
				if dst_x >= 0 and dst_x < base_image.get_width() and dst_y >= 0 and dst_y < base_image.get_height():
					base_image.set_pixel(dst_x, dst_y, src_color)

	return base_image


func _apply_crop(recording_data: VideoRecordingDataScript, image: Image, time_ms: int) -> Image:
	var crop_x := recording_data.get_crop_x_at(time_ms)

	var src_w := image.get_width()
	var src_h := image.get_height()

	# 9:16 crop: full height, width = height * 9/16
	var crop_w := int(src_h * 9.0 / 16.0)
	var crop_h := src_h

	# Center of crop
	var center_x := int(crop_x * src_w)
	var x_start := clampi(center_x - floori(crop_w / 2.0), 0, src_w - crop_w)

	# Extract crop region
	var cropped := image.get_region(Rect2i(x_start, 0, crop_w, crop_h))

	# Resize to 1080x1920
	cropped.resize(1080, 1920)
	return cropped

#endregion


#region Audio Processing

func _process_audio(recording_data: VideoRecordingDataScript) -> String:
	var audio_path := recording_data.get_audio_path()
	if not FileAccess.file_exists(audio_path):
		return ""

	# Build ffmpeg filter for audio cuts and speed changes
	var filter_parts: Array = []
	var segment_labels: Array = []
	var seg_idx := 0

	for seg in recording_data.segments:
		match seg.type:
			VideoRecordingDataScript.SegmentType.CUT:
				continue
			VideoRecordingDataScript.SegmentType.NORMAL:
				var label := "a%d" % seg_idx
				var start_s := float(seg.start_ms) / 1000.0
				var end_s := float(seg.end_ms) / 1000.0
				filter_parts.append("[0:a]atrim=start=%s:end=%s,asetpts=PTS-STARTPTS[%s]" % [str(start_s), str(end_s), label])
				segment_labels.append("[%s]" % label)
				seg_idx += 1
			VideoRecordingDataScript.SegmentType.FAST_FORWARD:
				var label := "a%d" % seg_idx
				var start_s := float(seg.start_ms) / 1000.0
				var end_s := float(seg.end_ms) / 1000.0
				var speed: float = seg.get("speed", 3.0)
				filter_parts.append("[0:a]atrim=start=%s:end=%s,asetpts=PTS-STARTPTS,atempo=%s[%s]" % [str(start_s), str(end_s), str(speed), label])
				segment_labels.append("[%s]" % label)
				seg_idx += 1

	if segment_labels.is_empty():
		return audio_path

	var edited_audio_path := _temp_dir.path_join("edited_audio.wav")

	# Build concat filter
	var filter_complex := ";".join(filter_parts)
	filter_complex += ";" + "".join(segment_labels) + "concat=n=%d:v=0:a=1[outa]" % segment_labels.size()

	var args := PackedStringArray([
		"-y", "-i", audio_path,
		"-filter_complex", filter_complex,
		"-map", "[outa]",
		edited_audio_path
	])

	var output: Array = []
	OS.execute("ffmpeg", args, output, true)
	if FileAccess.file_exists(edited_audio_path):
		return edited_audio_path
	return audio_path

#endregion


#region FFmpeg Encoding

func _encode_ffmpeg(recording_data: VideoRecordingDataScript, output_path: String,
		audio_path: String, aspect_ratio: AspectRatio, frame_count: int) -> Dictionary:
	if frame_count == 0:
		return {"success": false, "error": "No frames to encode"}

	var effective_fps := recording_data.fps

	# Calculate effective FPS based on edit list
	var effective_duration_ms := recording_data.get_effective_duration_ms()
	if effective_duration_ms > 0:
		effective_fps = int(round(float(frame_count) / (float(effective_duration_ms) / 1000.0)))
		effective_fps = clampi(effective_fps, 1, 120)

	var args := PackedStringArray([
		"-y",
		"-framerate", str(effective_fps),
		"-i", _temp_dir.path_join("frame_%06d.jpg"),
	])

	if not audio_path.is_empty() and FileAccess.file_exists(audio_path):
		args.append_array(PackedStringArray(["-i", audio_path]))

	# Video encoding settings
	if aspect_ratio == AspectRatio.PORTRAIT_9_16:
		args.append_array(PackedStringArray([
			"-c:v", "libx264",
			"-pix_fmt", "yuv420p",
			"-s", "1080x1920",
			"-preset", "medium",
			"-crf", "23",
		]))
	else:
		args.append_array(PackedStringArray([
			"-c:v", "libx264",
			"-pix_fmt", "yuv420p",
			"-preset", "medium",
			"-crf", "23",
		]))

	if not audio_path.is_empty() and FileAccess.file_exists(audio_path):
		args.append_array(PackedStringArray(["-c:a", "aac", "-b:a", "128k"]))

	# Ensure shortest stream determines length
	if not audio_path.is_empty() and FileAccess.file_exists(audio_path):
		args.append("-shortest")

	args.append(output_path)

	var output: Array = []
	var exit_code := OS.execute("ffmpeg", args, output, true)

	if exit_code != 0:
		var error_msg := "ffmpeg encoding failed (exit code %d)" % exit_code
		if not output.is_empty():
			error_msg += ": " + str(output[0]).substr(0, 500)
		return {"success": false, "error": error_msg}

	return {"success": true}

#endregion


#region Cleanup

func _cleanup() -> void:
	_exporting = false
	_process_id = -1
	# Remove temp directory
	if not _temp_dir.is_empty() and DirAccess.dir_exists_absolute(_temp_dir):
		var dir := DirAccess.open(_temp_dir)
		if dir:
			dir.list_dir_begin()
			var fname := dir.get_next()
			while not fname.is_empty():
				if not dir.current_is_dir():
					dir.remove(fname)
				fname = dir.get_next()
			dir.list_dir_end()
		DirAccess.remove_absolute(_temp_dir)
	_temp_dir = ""

#endregion
