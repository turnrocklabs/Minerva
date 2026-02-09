class_name VideoTimeline
extends Control
## Custom timeline control for the video editor.
## Shows thumbnail strip, color-coded segments, draggable playhead,
## scroll-wheel zoom, and keyframe markers.

const VideoRecordingDataScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
const VideoRecorderCaptureScript := preload("res://Scripts/UI/Controls/VideoRecorder/VideoRecorder.gd")

signal playhead_moved(time_ms: int)
signal segment_selected(index: int)
signal context_menu_requested(time_ms: int, position: Vector2)

## Recording data reference
var recording_data: VideoRecordingDataScript = null

## Playhead position in ms
var playhead_ms: int = 0:
	set(value):
		playhead_ms = clampi(value, 0, _total_duration_ms())
		queue_redraw()

## Zoom level (pixels per second)
var zoom: float = 100.0
var min_zoom: float = 20.0
var max_zoom: float = 500.0

## Scroll offset (in pixels)
var scroll_offset: float = 0.0

## Thumbnails cache: frame_index -> ImageTexture
var _thumbnail_cache: Dictionary = {}
var _thumbnail_interval_ms: int = 2000  # One thumbnail every 2 seconds
var _thumbnail_height: int = 48

## Interaction state
var _dragging_playhead: bool = false
var _selected_segment: int = -1

## Colors
var color_normal := Color(0.2, 0.6, 0.2, 0.6)
var color_cut := Color(0.7, 0.15, 0.15, 0.6)
var color_fast_forward := Color(0.7, 0.65, 0.1, 0.6)
var color_playhead := Color(1.0, 0.3, 0.3, 1.0)
var color_pip_keyframe := Color(0.3, 0.8, 1.0, 0.9)
var color_crop_keyframe := Color(1.0, 0.6, 0.2, 0.9)
var color_background := Color(0.12, 0.12, 0.14, 1.0)
var color_time_text := Color(0.7, 0.7, 0.7, 1.0)

## Layout constants
const HEADER_HEIGHT := 24.0
const THUMBNAIL_ROW_HEIGHT := 52.0
const SEGMENT_ROW_HEIGHT := 28.0
const KEYFRAME_ROW_HEIGHT := 16.0
const PLAYHEAD_WIDTH := 2.0
const KEYFRAME_DIAMOND_SIZE := 6.0


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	custom_minimum_size.y = HEADER_HEIGHT + THUMBNAIL_ROW_HEIGHT + SEGMENT_ROW_HEIGHT + KEYFRAME_ROW_HEIGHT * 2


func _total_duration_ms() -> int:
	if recording_data:
		return recording_data.duration_ms
	return 0


func _time_to_x(time_ms: int) -> float:
	return float(time_ms) / 1000.0 * zoom - scroll_offset


func _x_to_time(x: float) -> int:
	return int((x + scroll_offset) / zoom * 1000.0)


func _total_width() -> float:
	return float(_total_duration_ms()) / 1000.0 * zoom


func set_recording_data(data: VideoRecordingDataScript) -> void:
	recording_data = data
	_thumbnail_cache.clear()
	scroll_offset = 0.0
	playhead_ms = 0
	_generate_thumbnails()
	queue_redraw()


func _generate_thumbnails() -> void:
	if not recording_data or recording_data.frame_index.is_empty():
		return

	# Generate thumbnails at regular intervals
	var interval_ms := _thumbnail_interval_ms
	var duration_ms := recording_data.duration_ms
	var time_ms := 0

	while time_ms <= duration_ms:
		var frame_idx := recording_data.get_frame_at_time(time_ms)
		if frame_idx >= 0 and not _thumbnail_cache.has(time_ms):
			var image := VideoRecorderCaptureScript.read_frame(recording_data, frame_idx)
			if image and not image.is_empty():
				# Resize to thumbnail
				var aspect := float(image.get_width()) / float(image.get_height())
				var thumb_w := int(_thumbnail_height * aspect)
				image.resize(thumb_w, _thumbnail_height)
				_thumbnail_cache[time_ms] = ImageTexture.create_from_image(image)
		time_ms += interval_ms


func _draw() -> void:
	var area_size := size

	# Background
	draw_rect(Rect2(Vector2.ZERO, area_size), color_background)

	if not recording_data:
		draw_string(ThemeDB.fallback_font, Vector2(10, 16), "No recording loaded", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color_time_text)
		return

	# Header: time markers
	_draw_time_markers(area_size)

	# Thumbnail strip
	_draw_thumbnails(area_size)

	# Segment bars
	_draw_segments(area_size)

	# Keyframe markers
	_draw_keyframes(area_size)

	# Playhead
	_draw_playhead(area_size)


func _draw_time_markers(area_size: Vector2) -> void:
	var duration_ms := _total_duration_ms()
	if duration_ms == 0:
		return

	# Calculate marker interval based on zoom
	var marker_interval_s := 1.0
	if zoom < 40:
		marker_interval_s = 10.0
	elif zoom < 80:
		marker_interval_s = 5.0
	elif zoom < 150:
		marker_interval_s = 2.0

	var time_s := 0.0
	var max_time_s := float(duration_ms) / 1000.0

	while time_s <= max_time_s:
		var x := _time_to_x(int(time_s * 1000))
		if x >= 0 and x <= area_size.x:
			# Tick mark
			draw_line(Vector2(x, 0), Vector2(x, HEADER_HEIGHT), color_time_text * Color(1, 1, 1, 0.3), 1.0)
			# Time label
			var minutes := int(time_s) / 60
			var seconds := int(time_s) % 60
			var label := "%d:%02d" % [minutes, seconds]
			draw_string(ThemeDB.fallback_font, Vector2(x + 2, HEADER_HEIGHT - 6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color_time_text)
		time_s += marker_interval_s


func _draw_thumbnails(area_size: Vector2) -> void:
	var y_start := HEADER_HEIGHT
	for time_ms in _thumbnail_cache:
		var tex: ImageTexture = _thumbnail_cache[time_ms]
		var x := _time_to_x(time_ms)
		if x + tex.get_width() >= 0 and x <= area_size.x:
			draw_texture(tex, Vector2(x, y_start + 2))


func _draw_segments(area_size: Vector2) -> void:
	var y_start := HEADER_HEIGHT + THUMBNAIL_ROW_HEIGHT

	for i in recording_data.segments.size():
		var seg = recording_data.segments[i]
		var x_start := _time_to_x(seg.start_ms)
		var x_end := _time_to_x(seg.end_ms)

		if x_end < 0 or x_start > area_size.x:
			continue

		var color: Color
		match seg.type:
			VideoRecordingDataScript.SegmentType.NORMAL:
				color = color_normal
			VideoRecordingDataScript.SegmentType.CUT:
				color = color_cut
			VideoRecordingDataScript.SegmentType.FAST_FORWARD:
				color = color_fast_forward

		if i == _selected_segment:
			color = color.lightened(0.3)

		draw_rect(Rect2(x_start, y_start, x_end - x_start, SEGMENT_ROW_HEIGHT), color)

		# Border
		draw_rect(Rect2(x_start, y_start, x_end - x_start, SEGMENT_ROW_HEIGHT), color.darkened(0.3), false, 1.0)

		# Label
		var label := ""
		match seg.type:
			VideoRecordingDataScript.SegmentType.CUT:
				label = "CUT"
			VideoRecordingDataScript.SegmentType.FAST_FORWARD:
				label = "%sx" % str(seg.get("speed", 3.0))

		if not label.is_empty() and x_end - x_start > 30:
			draw_string(ThemeDB.fallback_font, Vector2(x_start + 4, y_start + 18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


func _draw_keyframes(area_size: Vector2) -> void:
	var pip_y := HEADER_HEIGHT + THUMBNAIL_ROW_HEIGHT + SEGMENT_ROW_HEIGHT + KEYFRAME_ROW_HEIGHT / 2
	var crop_y := pip_y + KEYFRAME_ROW_HEIGHT

	# PiP keyframes
	for kf in recording_data.pip_keyframes:
		var x := _time_to_x(kf.time_ms)
		if x >= 0 and x <= area_size.x:
			_draw_diamond(Vector2(x, pip_y), KEYFRAME_DIAMOND_SIZE, color_pip_keyframe)

	# Crop keyframes
	for kf in recording_data.crop_keyframes:
		var x := _time_to_x(kf.time_ms)
		if x >= 0 and x <= area_size.x:
			_draw_diamond(Vector2(x, crop_y), KEYFRAME_DIAMOND_SIZE, color_crop_keyframe)


func _draw_diamond(center: Vector2, size_: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -size_),
		center + Vector2(size_, 0),
		center + Vector2(0, size_),
		center + Vector2(-size_, 0),
	])
	draw_colored_polygon(points, color)


func _draw_playhead(area_size: Vector2) -> void:
	var x := _time_to_x(playhead_ms)
	if x >= 0 and x <= area_size.x:
		draw_line(Vector2(x, 0), Vector2(x, area_size.y), color_playhead, PLAYHEAD_WIDTH)
		# Triangle at top
		var tri := PackedVector2Array([
			Vector2(x, 0),
			Vector2(x - 5, -8),
			Vector2(x + 5, -8),
		])
		draw_colored_polygon(tri, color_playhead)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_dragging_playhead = true
					_update_playhead_from_mouse(event.position)
					# Check segment selection
					_check_segment_click(event.position)
				else:
					_dragging_playhead = false

			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					var time_ms := _x_to_time(event.position.x)
					context_menu_requested.emit(time_ms, event.global_position)

			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					zoom = clampf(zoom * 1.15, min_zoom, max_zoom)
					queue_redraw()

			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					zoom = clampf(zoom / 1.15, min_zoom, max_zoom)
					queue_redraw()

	elif event is InputEventMouseMotion:
		if _dragging_playhead:
			_update_playhead_from_mouse(event.position)

		# Middle mouse drag for scrolling
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			scroll_offset -= event.relative.x
			scroll_offset = clampf(scroll_offset, 0, maxf(0, _total_width() - size.x))
			queue_redraw()


func _update_playhead_from_mouse(pos: Vector2) -> void:
	var time_ms := _x_to_time(pos.x)
	playhead_ms = time_ms
	playhead_moved.emit(playhead_ms)


func _check_segment_click(pos: Vector2) -> void:
	var y_start := HEADER_HEIGHT + THUMBNAIL_ROW_HEIGHT
	if pos.y < y_start or pos.y > y_start + SEGMENT_ROW_HEIGHT:
		return

	var time_ms := _x_to_time(pos.x)
	for i in recording_data.segments.size():
		var seg = recording_data.segments[i]
		if time_ms >= seg.start_ms and time_ms <= seg.end_ms:
			_selected_segment = i
			segment_selected.emit(i)
			queue_redraw()
			return


## Scroll to ensure the playhead is visible
func ensure_playhead_visible() -> void:
	var x := _time_to_x(playhead_ms)
	if x < 0:
		scroll_offset += x - 20
	elif x > size.x:
		scroll_offset += x - size.x + 20
	scroll_offset = clampf(scroll_offset, 0, maxf(0, _total_width() - size.x))
	queue_redraw()


## Format time for display
static func format_time(ms: int) -> String:
	var total_seconds := ms / 1000
	var minutes := total_seconds / 60
	var seconds := total_seconds % 60
	var millis := ms % 1000
	return "%d:%02d.%03d" % [minutes, seconds, millis]
