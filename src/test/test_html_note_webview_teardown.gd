extends SceneTree
## Repro for the orphaned-webview bug.
##
## link_webview_to_note embeds a native godot_wry WebView (html_controls.gd:85,
## ClassDB.instantiate("WebView")) inside a note. Deleting the note must tear
## that native WebView down. Before the fix, NoteHtmlControls._exit_tree() only
## pruned the static _active_webviews list and never called the explicit
## teardown, so the native render was orphaned in the notes area.
##
## This test creates an HTML note, renders it, frees the note, then scans the
## tree for orphaned WebView nodes.
##
## A native WebView needs a real display server, so this test SKIPS under
## --headless (instantiating one there hangs). Run it on a desktop session:
##   godot --path ~/github/Minerva/src --script test/test_html_note_webview_teardown.gd
##
## Not in run-functional-tests.sh's hermetic list (that tier must stay headless).

const HTML := "<!DOCTYPE html><html><head></head><body><h1>mock</h1></body></html>"


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _count_webviews(node: Node) -> int:
	var n := 0
	if node.is_class("WebView"):
		n += 1
	for c in node.get_children():
		n += _count_webviews(c)
	return n


func _settle() -> void:
	for i in range(8):
		await process_frame


func _run() -> void:
	await process_frame  # let autoloads register

	if not ClassDB.class_exists("WebView"):
		print("SKIP: WebView class not available in this build")
		quit(0)
		return

	# A native godot_wry WebView needs a real display server; instantiating one
	# under --headless hangs. Skip there — meaningful only with a display.
	if DisplayServer.get_name() == "headless":
		print("SKIP: headless display server — native WebView teardown not testable")
		quit(0)
		return

	var NoteScript: Script = load("res://Scripts/UI/Controls/Note.gd")
	if NoteScript == null:
		print("FAIL: could not load Note.gd")
		quit(1)
		return

	var failures: Array[String] = []

	var note = NoteScript.create_html_note("teardown-test", HTML, "", false)
	root.add_child(note)
	await _settle()

	var before := _count_webviews(root)
	print("WebView nodes after render: ", before)
	if before < 1:
		failures.append("expected >=1 WebView node after render, got %d" % before)

	# Mirror the user's flow: delete the note.
	note.queue_free()
	await _settle()

	var after := _count_webviews(root)
	print("WebView nodes after note freed: ", after)
	if after != 0:
		failures.append("orphaned WebView: expected 0 after note freed, got %d" % after)

	if failures.is_empty():
		print("PASS: no orphaned webview after note deletion")
		quit(0)
	else:
		for f in failures:
			print("FAIL: ", f)
		quit(1)
