extends SceneTree
## Graphical lifecycle coverage for raw, unprivileged CEF-backed HTML notes.
## Run with a display and the packaged CEF extension; the hermetic tier is headless.

const HTML_PREFIX := "<!DOCTYPE html><html><head></head><body><h1>note-"
const WAIT_MS := 20000
var _failures: Array[String] = []


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _count_webviews(node: Node) -> int:
	var count := 1 if node.is_class("CefTexture") else 0
	for child in node.get_children():
		count += _count_webviews(child)
	return count


func _wait_until(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return predicate.call()


func _file_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _wait_file_absent(path: String) -> bool:
	return await _wait_until(func() -> bool: return not FileAccess.file_exists(path))


func _controls(note) -> Control:
	return note._backing_note_controls[0] if not note._backing_note_controls.is_empty() else null


func _run() -> void:
	await process_frame
	if not ClassDB.class_exists("CefTexture"):
		print("SKIP: CefTexture class not available in this build")
		quit(0)
		return
	if DisplayServer.get_name() == "headless":
		print("SKIP: native CEF lifecycle requires a graphical display")
		quit(0)
		return
	var NoteScript: Script = load("res://Scripts/UI/Controls/Note.gd")
	if NoteScript == null:
		print("FAIL: could not load Note.gd")
		quit(1)
		return

	# A restored session may already host CEF views (plugin panels, web
	# editors); only the delta this test creates is its own.
	var baseline: int = _count_webviews(root)
	var notes: Array = []
	for index in range(4):
		var note: Control = NoteScript.create_html_note(
			"cef-note-%d" % index, HTML_PREFIX + "%d</h1></body></html>" % index, "", false)
		notes.append(note)
		root.add_child(note)
	var first: Control = _controls(notes[0])
	var fourth: Control = _controls(notes[3])
	var first_loaded: bool = await _wait_until(func() -> bool:
		return not first._loaded_url.is_empty() or not first._load_error.is_empty())
	if not first_loaded or not first._load_error.is_empty():
		_failures.append("first raw HTML page did not load: %s" % first._load_error)
	if _count_webviews(root) != baseline + 3 or fourth._placeholder == null or fourth._webview != null:
		_failures.append("fourth HTML note did not start behind the three-view cap: views=%d placeholder=%s webview=%s"
			% [_count_webviews(root), fourth._placeholder != null, fourth._webview != null])

	var first_path: String = first._document.file_path
	var first_source: String = _file_text(first_path)
	if first_source.find("note-0") < 0:
		_failures.append("raw backing did not contain note content")
	if first_source.find("window.minerva") >= 0 \
			or first_source.find("__MINERVA_DOCUMENT_CAPABILITY__") >= 0 \
			or not first._document.capability.is_empty():
		_failures.append("raw HTML note unexpectedly received bridge authority")

	# Drag and drop reparents a note; the view it lost on the way out comes back.
	var second: Control = _controls(notes[1])
	root.remove_child(notes[1])
	await process_frame
	root.add_child(notes[1])
	var second_back: bool = await _wait_until(func() -> bool:
		return second._webview != null or second._placeholder != null)
	if not second_back:
		_failures.append("reparented HTML note came back with neither a view nor a placeholder")
	elif _count_webviews(root) != baseline + 3:
		_failures.append("reparent changed the native view count: views=%d" % _count_webviews(root))

	# Rendering the capped note evicts the oldest browser and backing.
	fourth._placeholder.pressed.emit()
	var fourth_loaded: bool = await _wait_until(func() -> bool:
		return not fourth._loaded_url.is_empty() or not fourth._load_error.is_empty())
	if not fourth_loaded or not fourth._load_error.is_empty():
		_failures.append("activated fourth page did not load: %s" % fourth._load_error)
	if first._webview != null or first._placeholder == null or _count_webviews(root) != baseline + 3:
		_failures.append("cap activation did not evict exactly the oldest native view: first webview=%s placeholder=%s views=%d"
			% [first._webview != null, first._placeholder != null, _count_webviews(root)])
	var first_retired: bool = await _wait_file_absent(first_path)
	if not first_retired:
		_failures.append("evicted HTML backing was not retired")

	# Updating an active note replaces its browser without changing the cap.
	var prior_path: String = fourth._document.file_path
	fourth.content = HTML_PREFIX + "updated</h1></body></html>"
	var update_loaded: bool = await _wait_until(func() -> bool:
		return not fourth._loaded_url.is_empty() or not fourth._load_error.is_empty())
	if not update_loaded or not fourth._load_error.is_empty():
		_failures.append("updated page did not load: %s" % fourth._load_error)
	elif _file_text(fourth._document.file_path).find("note-updated") < 0:
		_failures.append("updated raw HTML was not materialized")
	if _count_webviews(root) != baseline + 3:
		_failures.append("HTML update changed the native view cap: views=%d" % _count_webviews(root))
	var prior_retired: bool = await _wait_file_absent(prior_path)
	if not prior_retired:
		_failures.append("replaced HTML backing was not retired")

	var remaining_paths: Array[String] = []
	for note in notes:
		var controls: Control = _controls(note)
		if controls != null and controls._document != null:
			remaining_paths.append(controls._document.file_path)
		note.queue_free()
	var all_closed: bool = await _wait_until(func() -> bool: return _count_webviews(root) == baseline)
	if not all_closed:
		_failures.append("native HTML views survived note deletion: views=%d baseline=%d" % [_count_webviews(root), baseline])
	for path in remaining_paths:
		var backing_retired: bool = await _wait_file_absent(path)
		if not backing_retired:
			_failures.append("HTML backing survived its native browser close")

	if _failures.is_empty():
		print("PASS: raw CEF HTML notes load without bridge authority and retire cleanly")
		quit(0)
	else:
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
