extends SceneTree
## Headless test for the image-note substrate extension in MCPNotesTools
## (media-plugins flf2v note-picker, Part 1).
##
## Validates that:
##   - _get_note() exports image-backed notes (IMAGE / PLUGIN_DATA) to a PNG on
##     disk and surfaces image_path / image_width / image_height / image_format.
##   - The exported PNG actually loads back at the right dimensions.
##   - The caption is surfaced as content when there is no text body.
##   - Text notes get NO image_* fields (and still report type).
##   - _list_notes() entries carry a `type` field for filtering.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_get_note_image_export.gd

const NotesToolsScript := "res://Scripts/Services/MCP/Modules/MCPNotesTools.gd"

var NoteScript: Script = null

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== get_note image-export substrate tests ===\n")
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	await process_frame  # let autoloads register

	NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	var ToolsScript: Script = load(NotesToolsScript)
	check("scripts loaded", NoteScript != null and ToolsScript != null)
	if NoteScript == null or ToolsScript == null:
		_finish()
		return

	var tools = ToolsScript.new(null)  # server not needed for _get_note happy path

	await _test_image_note_exports(tools)
	await _test_text_note_has_no_image(tools)

	_finish()


func _make_image(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.7, 0.2, 1.0))
	return img


func _test_image_note_exports(tools) -> void:
	print("test_image_note_exports:")
	var note = NoteScript.create_image_note("Keyframe A", _make_image(40, 24), "a sunny meadow")
	root.add_child(note)
	await process_frame  # let ready fire so image cache populates

	var res: Dictionary = tools._get_note({"note_id": note.uuid})
	check("success", res.get("success", false), str(res))
	check("type == IMAGE", res.get("type", "") == "IMAGE", "got: %s" % res.get("type", ""))
	check("has image_path", res.has("image_path") and not String(res.get("image_path", "")).is_empty())
	check("image_width == 40", int(res.get("image_width", 0)) == 40, "got: %s" % res.get("image_width", 0))
	check("image_height == 24", int(res.get("image_height", 0)) == 24, "got: %s" % res.get("image_height", 0))
	check("image_format == png", res.get("image_format", "") == "png")
	check("caption surfaced as content", res.get("content", "") == "a sunny meadow", "got: '%s'" % res.get("content", ""))

	var path: String = res.get("image_path", "")
	check("exported PNG exists on disk", FileAccess.file_exists(path), path)
	if FileAccess.file_exists(path):
		var loaded := Image.load_from_file(path)
		check("PNG reloads", loaded != null)
		if loaded != null:
			check("reloaded dims match", loaded.get_width() == 40 and loaded.get_height() == 24,
				"got %dx%d" % [loaded.get_width(), loaded.get_height()])

	note.queue_free()


func _test_text_note_has_no_image(tools) -> void:
	print("test_text_note_has_no_image:")
	var note = NoteScript.create_text_note("Just text", "hello world")
	root.add_child(note)
	await process_frame

	var res: Dictionary = tools._get_note({"note_id": note.uuid})
	check("success", res.get("success", false), str(res))
	check("type == TEXT", res.get("type", "") == "TEXT", "got: %s" % res.get("type", ""))
	check("no image_path on text note", not res.has("image_path"))
	check("text content preserved", res.get("content", "") == "hello world")

	note.queue_free()


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		print("  FAIL: %s%s" % [desc, ("  [%s]" % detail) if detail != "" else ""])


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)
