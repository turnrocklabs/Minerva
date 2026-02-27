class_name VideoRecordingData
extends RefCounted
## Data model for video recordings.
## Handles manifest, frame index, edit decision list, and file I/O.

## Recording modes
enum Mode { VIEWPORT, WEBCAM, PIP }

## Edit segment types
enum SegmentType { NORMAL, CUT, FAST_FORWARD }

## Manifest data
var recording_id: String = ""
var mode: Mode = Mode.VIEWPORT
var fps: int = 30
var resolution: Vector2i = Vector2i(1920, 1080)
var duration_ms: int = 0
var created_at: String = ""

## File paths (set after init)
var recording_dir: String = ""

## Frame index: Array of [byte_offset: int, timestamp_us: int]
var frame_index: Array = []
var webcam_frame_index: Array = []

## Edit decision list
var segments: Array = []  # Array of {type: SegmentType, start_ms: int, end_ms: int, speed: float}
var pip_keyframes: Array = []  # Array of {time_ms: int, position: Vector2}
var crop_keyframes: Array = []  # Array of {time_ms: int, x: float}

## Undo/redo stacks for edits
var _undo_stack: Array = []
var _redo_stack: Array = []


func _init(id: String = "") -> void:
	if id.is_empty():
		recording_id = _generate_uuid()
	else:
		recording_id = id
	created_at = Time.get_datetime_string_from_system()


static func _generate_uuid() -> String:
	var chars := "0123456789abcdef"
	var uuid := ""
	for i in 36:
		if i in [8, 13, 18, 23]:
			uuid += "-"
		else:
			uuid += chars[randi() % 16]
	return uuid


## Get the recordings base directory
static func get_recordings_base_dir() -> String:
	return "user://recordings"


## Get this recording's directory path
func get_recording_dir() -> String:
	if recording_dir.is_empty():
		recording_dir = get_recordings_base_dir().path_join(recording_id)
	return recording_dir


## Ensure the recording directory exists
func ensure_dir() -> Error:
	var dir_path := get_recording_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		return DirAccess.make_dir_recursive_absolute(dir_path)
	return OK


## Get file paths
func get_manifest_path() -> String:
	return get_recording_dir().path_join("manifest.json")

func get_frames_path() -> String:
	return get_recording_dir().path_join("frames.bin")

func get_frame_index_path() -> String:
	return get_recording_dir().path_join("frame_index.bin")

func get_audio_path() -> String:
	return get_recording_dir().path_join("audio.wav")

func get_webcam_frames_path() -> String:
	return get_recording_dir().path_join("webcam_frames.bin")

func get_webcam_index_path() -> String:
	return get_recording_dir().path_join("webcam_index.bin")

func get_edits_path() -> String:
	return get_recording_dir().path_join("edits.json")


#region Manifest I/O

func save_manifest() -> Error:
	var data := {
		"recording_id": recording_id,
		"mode": Mode.keys()[mode],
		"fps": fps,
		"resolution": [resolution.x, resolution.y],
		"duration_ms": duration_ms,
		"created_at": created_at,
		"frame_count": frame_index.size(),
		"webcam_frame_count": webcam_frame_index.size(),
	}
	return _save_json(get_manifest_path(), data)


func load_manifest() -> Error:
	var result := _load_json(get_manifest_path())
	if result.is_empty():
		return ERR_FILE_NOT_FOUND

	recording_id = result.get("recording_id", recording_id)
	var mode_str: String = result.get("mode", "VIEWPORT")
	mode = Mode.get(mode_str, Mode.VIEWPORT)
	fps = result.get("fps", 30)
	var res_arr: Array = result.get("resolution", [1920, 1080])
	resolution = Vector2i(res_arr[0], res_arr[1])
	duration_ms = result.get("duration_ms", 0)
	created_at = result.get("created_at", "")
	return OK

#endregion


#region Frame Index I/O

## Append a frame index entry during recording
func append_frame_index_entry(byte_offset: int, timestamp_us: int) -> void:
	frame_index.append([byte_offset, timestamp_us])


func append_webcam_frame_index_entry(byte_offset: int, timestamp_us: int) -> void:
	webcam_frame_index.append([byte_offset, timestamp_us])


## Save frame index to binary file (array of [int64 offset, int64 timestamp_us])
func save_frame_index() -> Error:
	return _save_binary_index(get_frame_index_path(), frame_index)


func load_frame_index() -> Error:
	var result := _load_binary_index(get_frame_index_path())
	if result.is_empty() and FileAccess.file_exists(get_frame_index_path()):
		return ERR_FILE_CORRUPT
	frame_index = result
	return OK


func save_webcam_index() -> Error:
	return _save_binary_index(get_webcam_index_path(), webcam_frame_index)


func load_webcam_index() -> Error:
	var result := _load_binary_index(get_webcam_index_path())
	if result.is_empty() and FileAccess.file_exists(get_webcam_index_path()):
		return ERR_FILE_CORRUPT
	webcam_frame_index = result
	return OK


static func _save_binary_index(path: String, index: Array) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return FileAccess.get_open_error()
	for entry in index:
		f.store_64(entry[0])  # byte_offset
		f.store_64(entry[1])  # timestamp_us
	return OK


static func _load_binary_index(path: String) -> Array:
	var result: Array = []
	if not FileAccess.file_exists(path):
		return result
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return result
	while f.get_position() < f.get_length():
		var offset := f.get_64()
		var ts := f.get_64()
		result.append([offset, ts])
	return result

#endregion


#region Edits I/O

func save_edits() -> Error:
	var data := {
		"version": 1,
		"segments": _segments_to_array(),
		"pip_keyframes": _pip_keyframes_to_array(),
		"crop_keyframes": _crop_keyframes_to_array(),
	}
	return _save_json(get_edits_path(), data)


func load_edits() -> Error:
	var data := _load_json(get_edits_path())
	if data.is_empty():
		# No edits file means fresh recording - initialize with single normal segment
		_init_default_segments()
		return OK

	segments = _array_to_segments(data.get("segments", []))
	pip_keyframes = _array_to_pip_keyframes(data.get("pip_keyframes", []))
	crop_keyframes = _array_to_crop_keyframes(data.get("crop_keyframes", []))
	return OK


func _init_default_segments() -> void:
	segments = [{
		"type": SegmentType.NORMAL,
		"start_ms": 0,
		"end_ms": duration_ms,
	}]
	crop_keyframes = [{"time_ms": 0, "x": 0.5}]
	if mode == Mode.PIP:
		pip_keyframes = [{"time_ms": 0, "position": Vector2(0.85, 0.8)}]


func _segments_to_array() -> Array:
	var arr: Array = []
	for seg in segments:
		var d := {
			"type": SegmentType.keys()[seg.type],
			"start_ms": seg.start_ms,
			"end_ms": seg.end_ms,
		}
		if seg.type == SegmentType.FAST_FORWARD:
			d["speed"] = seg.get("speed", 3.0)
		arr.append(d)
	return arr


func _array_to_segments(arr: Array) -> Array:
	var result: Array = []
	for d in arr:
		var seg := {
			"type": SegmentType.get(d.get("type", "NORMAL"), SegmentType.NORMAL),
			"start_ms": int(d.get("start_ms", 0)),
			"end_ms": int(d.get("end_ms", 0)),
		}
		if seg.type == SegmentType.FAST_FORWARD:
			seg["speed"] = d.get("speed", 3.0)
		result.append(seg)
	return result


func _pip_keyframes_to_array() -> Array:
	var arr: Array = []
	for kf in pip_keyframes:
		arr.append({
			"time_ms": kf.time_ms,
			"position": [kf.position.x, kf.position.y],
		})
	return arr


func _array_to_pip_keyframes(arr: Array) -> Array:
	var result: Array = []
	for d in arr:
		var pos: Array = d.get("position", [0.85, 0.8])
		result.append({
			"time_ms": int(d.get("time_ms", 0)),
			"position": Vector2(pos[0], pos[1]),
		})
	return result


func _crop_keyframes_to_array() -> Array:
	var arr: Array = []
	for kf in crop_keyframes:
		arr.append({
			"time_ms": kf.time_ms,
			"x": kf.x,
		})
	return arr


func _array_to_crop_keyframes(arr: Array) -> Array:
	var result: Array = []
	for d in arr:
		result.append({
			"time_ms": int(d.get("time_ms", 0)),
			"x": d.get("x", 0.5),
		})
	return result

#endregion


#region Edit Operations (with undo/redo)

func add_cut(start_ms: int, end_ms: int) -> bool:
	if start_ms >= end_ms or start_ms < 0 or end_ms > duration_ms:
		return false
	_push_undo()
	_insert_segment(SegmentType.CUT, start_ms, end_ms)
	return true


func add_speed_region(start_ms: int, end_ms: int, speed: float) -> bool:
	if start_ms >= end_ms or start_ms < 0 or end_ms > duration_ms or speed <= 0:
		return false
	_push_undo()
	_insert_segment(SegmentType.FAST_FORWARD, start_ms, end_ms, speed)
	return true


func remove_segment(index: int) -> bool:
	if index < 0 or index >= segments.size():
		return false
	var seg = segments[index]
	if seg.type == SegmentType.NORMAL:
		return false  # Can't remove normal segments
	_push_undo()
	# Replace the removed segment with a normal segment
	segments[index] = {
		"type": SegmentType.NORMAL,
		"start_ms": seg.start_ms,
		"end_ms": seg.end_ms,
	}
	_merge_adjacent_normal_segments()
	return true


func set_pip_position(time_ms: int, position: Vector2) -> void:
	_push_undo()
	# Find existing keyframe at this time or insert new one
	for i in pip_keyframes.size():
		if pip_keyframes[i].time_ms == time_ms:
			pip_keyframes[i].position = position
			return
	pip_keyframes.append({"time_ms": time_ms, "position": position})
	pip_keyframes.sort_custom(func(a, b): return a.time_ms < b.time_ms)


func set_crop_position(time_ms: int, x: float) -> void:
	_push_undo()
	x = clampf(x, 0.0, 1.0)
	for i in crop_keyframes.size():
		if crop_keyframes[i].time_ms == time_ms:
			crop_keyframes[i].x = x
			return
	crop_keyframes.append({"time_ms": time_ms, "x": x})
	crop_keyframes.sort_custom(func(a, b): return a.time_ms < b.time_ms)


func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_redo_stack.append(_get_edit_state())
	_restore_edit_state(_undo_stack.pop_back())
	return true


func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(_get_edit_state())
	_restore_edit_state(_redo_stack.pop_back())
	return true

#endregion


#region Internal Edit Helpers

func _push_undo() -> void:
	_undo_stack.append(_get_edit_state())
	_redo_stack.clear()


func _get_edit_state() -> Dictionary:
	return {
		"segments": segments.duplicate(true),
		"pip_keyframes": pip_keyframes.duplicate(true),
		"crop_keyframes": crop_keyframes.duplicate(true),
	}


func _restore_edit_state(state: Dictionary) -> void:
	segments = state.segments
	pip_keyframes = state.pip_keyframes
	crop_keyframes = state.crop_keyframes


func _insert_segment(type: SegmentType, start_ms: int, end_ms: int, speed: float = 3.0) -> void:
	var new_segments: Array = []
	for seg in segments:
		# Segment is entirely before the new one
		if seg.end_ms <= start_ms:
			new_segments.append(seg)
			continue
		# Segment is entirely after the new one
		if seg.start_ms >= end_ms:
			new_segments.append(seg)
			continue

		# Segment overlaps - split it
		if seg.start_ms < start_ms:
			new_segments.append({
				"type": seg.type,
				"start_ms": seg.start_ms,
				"end_ms": start_ms,
			})
			if seg.type == SegmentType.FAST_FORWARD:
				new_segments.back()["speed"] = seg.get("speed", 3.0)

		# Only insert the new segment once (when we first encounter overlap)
		if new_segments.is_empty() or new_segments.back().get("start_ms", -1) != start_ms:
			var new_seg := {
				"type": type,
				"start_ms": start_ms,
				"end_ms": end_ms,
			}
			if type == SegmentType.FAST_FORWARD:
				new_seg["speed"] = speed
			# Check if we already added this segment
			var already_added := false
			for ns in new_segments:
				if ns.start_ms == start_ms and ns.end_ms == end_ms and ns.type == type:
					already_added = true
					break
			if not already_added:
				new_segments.append(new_seg)

		if seg.end_ms > end_ms:
			new_segments.append({
				"type": seg.type,
				"start_ms": end_ms,
				"end_ms": seg.end_ms,
			})
			if seg.type == SegmentType.FAST_FORWARD:
				new_segments.back()["speed"] = seg.get("speed", 3.0)

	segments = new_segments
	_merge_adjacent_normal_segments()


func _merge_adjacent_normal_segments() -> void:
	if segments.size() < 2:
		return
	var merged: Array = [segments[0]]
	for i in range(1, segments.size()):
		var prev = merged.back()
		var curr = segments[i]
		if prev.type == SegmentType.NORMAL and curr.type == SegmentType.NORMAL and prev.end_ms == curr.start_ms:
			prev.end_ms = curr.end_ms
		else:
			merged.append(curr)
	segments = merged

#endregion


#region Interpolation

## Get the interpolated crop X position at a given time
func get_crop_x_at(time_ms: int) -> float:
	if crop_keyframes.is_empty():
		return 0.5
	if crop_keyframes.size() == 1:
		return crop_keyframes[0].x
	# Clamp to first/last
	if time_ms <= crop_keyframes[0].time_ms:
		return crop_keyframes[0].x
	if time_ms >= crop_keyframes.back().time_ms:
		return crop_keyframes.back().x
	# Linear interpolation
	for i in range(crop_keyframes.size() - 1):
		var a = crop_keyframes[i]
		var b = crop_keyframes[i + 1]
		if time_ms >= a.time_ms and time_ms <= b.time_ms:
			var t := float(time_ms - a.time_ms) / float(b.time_ms - a.time_ms)
			return lerpf(a.x, b.x, t)
	return 0.5


## Get the interpolated PiP position at a given time
func get_pip_position_at(time_ms: int) -> Vector2:
	if pip_keyframes.is_empty():
		return Vector2(0.85, 0.8)
	if pip_keyframes.size() == 1:
		return pip_keyframes[0].position
	if time_ms <= pip_keyframes[0].time_ms:
		return pip_keyframes[0].position
	if time_ms >= pip_keyframes.back().time_ms:
		return pip_keyframes.back().position
	for i in range(pip_keyframes.size() - 1):
		var a = pip_keyframes[i]
		var b = pip_keyframes[i + 1]
		if time_ms >= a.time_ms and time_ms <= b.time_ms:
			var t := float(time_ms - a.time_ms) / float(b.time_ms - a.time_ms)
			return a.position.lerp(b.position, t)
	return Vector2(0.85, 0.8)


## Get the frame index nearest to a timestamp (in ms)
func get_frame_at_time(time_ms: int) -> int:
	if frame_index.is_empty():
		return -1
	var target_us := time_ms * 1000
	# Binary search
	var lo : int = 0
	var hi : int = frame_index.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2.0
		if frame_index[mid][1] < target_us:
			lo = int(mid + 1)
		else:
			hi = int(mid)
	return lo


## Calculate the effective duration after edits (cuts removed, fast-forward compressed)
func get_effective_duration_ms() -> int:
	var total := 0
	for seg in segments:
		match seg.type:
			SegmentType.NORMAL:
				total += seg.end_ms - seg.start_ms
			SegmentType.CUT:
				pass  # Skip
			SegmentType.FAST_FORWARD:
				total += int(float(seg.end_ms - seg.start_ms) / seg.get("speed", 3.0))
	return total

#endregion


#region Serialization (for project save/load)

func to_dict() -> Dictionary:
	return {
		"recording_id": recording_id,
		"mode": Mode.keys()[mode],
		"fps": fps,
		"resolution": [resolution.x, resolution.y],
		"duration_ms": duration_ms,
		"created_at": created_at,
		"segments": _segments_to_array(),
		"pip_keyframes": _pip_keyframes_to_array(),
		"crop_keyframes": _crop_keyframes_to_array(),
	}


func load_from_dict(data: Dictionary) -> void:
	recording_id = data.get("recording_id", recording_id)
	var mode_str: String = data.get("mode", "VIEWPORT")
	mode = Mode.get(mode_str, Mode.VIEWPORT)
	fps = data.get("fps", 30)
	var res_arr: Array = data.get("resolution", [1920, 1080])
	resolution = Vector2i(res_arr[0], res_arr[1])
	duration_ms = data.get("duration_ms", 0)
	created_at = data.get("created_at", "")
	segments = _array_to_segments(data.get("segments", []))
	pip_keyframes = _array_to_pip_keyframes(data.get("pip_keyframes", []))
	crop_keyframes = _array_to_crop_keyframes(data.get("crop_keyframes", []))

#endregion


#region Static Helpers

static func list_recordings() -> Array:
	var base_dir := get_recordings_base_dir()
	var recordings: Array = []
	if not DirAccess.dir_exists_absolute(base_dir):
		return recordings

	var dir := DirAccess.open(base_dir)
	if not dir:
		return recordings

	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if dir.current_is_dir() and name != "." and name != "..":
			var manifest_path := base_dir.path_join(name).path_join("manifest.json")
			if FileAccess.file_exists(manifest_path):
				var data := VideoRecordingData.new(name)
				if data.load_manifest() == OK:
					recordings.append({
						"id": name,
						"mode": Mode.keys()[data.mode],
						"duration_ms": data.duration_ms,
						"fps": data.fps,
						"resolution": [data.resolution.x, data.resolution.y],
						"created_at": data.created_at,
						"path": base_dir.path_join(name),
					})
		name = dir.get_next()
	dir.list_dir_end()
	return recordings


## Load a recording from disk
static func load_recording(recording_id_: String) -> VideoRecordingData:
	var data := VideoRecordingData.new(recording_id_)
	if data.load_manifest() != OK:
		return null
	data.load_frame_index()
	data.load_webcam_index()
	data.load_edits()
	return data

#endregion


#region JSON Helpers

static func _save_json(path: String, data: Dictionary) -> Error:
	var json_str := JSON.stringify(data, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return FileAccess.get_open_error()
	f.store_string(json_str)
	return OK


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	if json.data is Dictionary:
		return json.data
	return {}

#endregion
