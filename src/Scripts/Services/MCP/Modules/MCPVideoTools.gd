class_name MCPVideoTools
extends MCPToolModule
## MCP tool module for Video Editor domain tools.
## Handles video recording editing, cut/speed regions, PiP, crop, and export.


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_video_editor",
		"minerva_video_add_cut",
		"minerva_video_add_speed_region",
		"minerva_video_remove_edit",
		"minerva_video_set_pip_position",
		"minerva_video_set_crop_position",
		"minerva_video_get_state",
		"minerva_video_export",
		"minerva_video_list_recordings",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_video_editor",
		"Open a recording in the video editor. Creates a new editor tab for editing a recorded video. Next steps: use minerva_video_add_cut, minerva_video_add_speed_region for editing, minerva_video_export to render.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the video editor tab"
				},
				"recording_path": {
					"type": "string",
					"description": "Path to the recording directory (from minerva_video_list_recordings)"
				}
			},
			"required": ["name", "recording_path"]
		}
	, "video")

	server._register_tool("minerva_video_add_cut",
		"Cut out a time region from the video. The cut region will be excluded from the final export.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"start_ms": {
					"type": "integer",
					"description": "Start time in milliseconds"
				},
				"end_ms": {
					"type": "integer",
					"description": "End time in milliseconds"
				}
			},
			"required": ["editor_name", "start_ms", "end_ms"]
		}
	, "video")

	server._register_tool("minerva_video_add_speed_region",
		"Speed up a time region in the video (fast-forward effect).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"start_ms": {
					"type": "integer",
					"description": "Start time in milliseconds"
				},
				"end_ms": {
					"type": "integer",
					"description": "End time in milliseconds"
				},
				"speed": {
					"type": "number",
					"description": "Speed multiplier (e.g. 2.0, 3.0, 5.0). Default: 3.0"
				}
			},
			"required": ["editor_name", "start_ms", "end_ms"]
		}
	, "video")

	server._register_tool("minerva_video_remove_edit",
		"Remove a cut or speed edit by segment index, reverting it to normal playback.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"segment_index": {
					"type": "integer",
					"description": "Index of the segment to remove (from minerva_video_get_state)"
				}
			},
			"required": ["editor_name", "segment_index"]
		}
	, "video")

	server._register_tool("minerva_video_set_pip_position",
		"Set the Picture-in-Picture webcam overlay position at a specific time. Creates a keyframe for smooth transitions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"time_ms": {
					"type": "integer",
					"description": "Time in milliseconds for the keyframe"
				},
				"x": {
					"type": "number",
					"description": "Normalized X position (0.0=left, 1.0=right)"
				},
				"y": {
					"type": "number",
					"description": "Normalized Y position (0.0=top, 1.0=bottom)"
				}
			},
			"required": ["editor_name", "time_ms", "x", "y"]
		}
	, "video")

	server._register_tool("minerva_video_set_crop_position",
		"Set the vertical (9:16) crop region center position at a specific time. Creates a keyframe for the crop window.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"time_ms": {
					"type": "integer",
					"description": "Time in milliseconds for the keyframe"
				},
				"x": {
					"type": "number",
					"description": "Normalized center X position of the 9:16 crop (0.0=left, 0.5=center, 1.0=right)"
				}
			},
			"required": ["editor_name", "time_ms", "x"]
		}
	, "video")

	server._register_tool("minerva_video_get_state",
		"Get the current edit state of a video editor, including segments, keyframes, and duration.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "video")

	server._register_tool("minerva_video_export",
		"Export the video to MP4 file. Requires ffmpeg to be installed.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the video editor tab"
				},
				"output_path": {
					"type": "string",
					"description": "Full file path for the output MP4"
				},
				"aspect_ratio": {
					"type": "string",
					"enum": ["16:9", "9:16"],
					"description": "Export aspect ratio. '16:9' for landscape (1920x1080), '9:16' for vertical/shorts (1080x1920). Default: '16:9'"
				}
			},
			"required": ["editor_name", "output_path"]
		}
	, "video")

	server._register_tool("minerva_video_list_recordings",
		"List all available video recordings with their metadata.",
		{
			"type": "object",
			"properties": {},
		}
	, "video")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_video_editor": return _create_video_editor(arguments)
		"minerva_video_add_cut": return _video_add_cut(arguments)
		"minerva_video_add_speed_region": return _video_add_speed_region(arguments)
		"minerva_video_remove_edit": return _video_remove_edit(arguments)
		"minerva_video_set_pip_position": return _video_set_pip_position(arguments)
		"minerva_video_set_crop_position": return _video_set_crop_position(arguments)
		"minerva_video_get_state": return _video_get_state(arguments)
		"minerva_video_export": return _video_export(arguments)
		"minerva_video_list_recordings": return _video_list_recordings(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


## Find a video editor by tab name
func _find_video_editor(name_: String):  # Returns VideoEditorPanel or null
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name = name_.strip_edges()

	# Exact match
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.VIDEO_EDITOR and editor.tab_title == clean_name:
			return editor.video_editor_panel

	# Case-insensitive match
	var lower_name = clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.VIDEO_EDITOR and editor.tab_title.to_lower() == lower_name:
			return editor.video_editor_panel

	return null


## Create a new video editor
func _create_video_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "")
	var recording_path: String = args.get("recording_path", "")

	if name_.is_empty():
		return {"success": false, "error": "name is required"}
	if recording_path.is_empty():
		return {"success": false, "error": "recording_path is required"}

	# Check if editor already open with this name
	var existing = _find_video_editor(name_)
	if existing:
		return {"success": true, "editor_name": name_, "message": "Editor already open"}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"success": false, "error": "Editor pane not available"}

	var editor = editor_pane.add(Editor.Type.VIDEO_EDITOR, recording_path, name_)
	if not editor:
		return {"success": false, "error": "Failed to create video editor"}

	return {
		"success": true,
		"editor_name": name_,
		"message": "Video editor created for recording: %s" % recording_path
	}


## Add a cut segment
func _video_add_cut(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var start_ms: int = args.get("start_ms", 0)
	var end_ms: int = args.get("end_ms", 0)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_add_cut(start_ms, end_ms)


## Add a speed region
func _video_add_speed_region(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var start_ms: int = args.get("start_ms", 0)
	var end_ms: int = args.get("end_ms", 0)
	var speed: float = args.get("speed", 3.0)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_add_speed_region(start_ms, end_ms, speed)


## Remove an edit segment
func _video_remove_edit(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var segment_index: int = args.get("segment_index", -1)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_remove_edit(segment_index)


## Set PiP position keyframe
func _video_set_pip_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var time_ms: int = args.get("time_ms", 0)
	var x: float = args.get("x", 0.85)
	var y: float = args.get("y", 0.8)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_set_pip_position(time_ms, x, y)


## Set crop position keyframe
func _video_set_crop_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var time_ms: int = args.get("time_ms", 0)
	var x: float = args.get("x", 0.5)

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_set_crop_position(time_ms, x)


## Get editor state
func _video_get_state(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	var state = editor.get_state_dict()
	state["success"] = true
	return state


## Export video
func _video_export(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var output_path: String = args.get("output_path", "")
	var aspect_ratio_str: String = args.get("aspect_ratio", "16:9")

	if output_path.is_empty():
		return {"success": false, "error": "output_path is required"}

	var editor = _find_video_editor(editor_name)
	if not editor:
		return {"success": false, "error": "Video editor '%s' not found" % editor_name}

	return editor.mcp_export(output_path, aspect_ratio_str)


## List all recordings
func _video_list_recordings(_args: Dictionary) -> Dictionary:
	var VideoRecordingDataScript = load("res://Scripts/UI/Controls/VideoRecorder/VideoRecordingData.gd")
	var recordings = VideoRecordingDataScript.list_recordings()
	return {
		"success": true,
		"recordings": recordings,
		"count": recordings.size()
	}
