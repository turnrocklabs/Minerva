extends SceneTree
## UiScaleSync: every sub-window carries the root's content_scale_factor —
## on entering the tree, on every popup, and after a zoom change. This is the
## test that makes chore 019fb90972's bug class unrepresentable: a dialog that
## nobody synced by hand still renders at the UI zoom.

const UiScaleSyncScript = preload("res://Scripts/Services/UiScaleSync.gd")

var _pass := 0
var _fail := 0


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _initialize() -> void:
	print("[tags: unit,ui,scale]")
	print("=== test_ui_scale_sync ===\n")
	# _initialize() runs before the SceneTree attaches its root: root.get_tree()
	# is still null there and anything parented to root reports is_inside_tree()
	# == false, so UiScaleSync.sync() correctly declines to stamp it. One frame
	# gives the rig the live tree the product is installed into.
	await process_frame
	root.content_scale_factor = 1.5
	UiScaleSyncScript.install(self)

	# A code-created dialog, added with no sync of its own — the way 58 sites
	# in the codebase do it.
	var dialog := ConfirmationDialog.new()
	root.add_child(dialog)
	check("a ConfirmationDialog entering the tree takes the root's factor",
		is_equal_approx(dialog.content_scale_factor, 1.5))

	# A plain Window built and parented BEFORE install would have been missed
	# by node_added — resync_all covers it, which is also the zoom-change path.
	var stale := Window.new()
	stale.visible = false
	root.add_child(stale)
	stale.content_scale_factor = 1.0
	root.content_scale_factor = 2.0
	UiScaleSyncScript.resync_all(self)
	check("a zoom change re-stamps every open window",
		is_equal_approx(stale.content_scale_factor, 2.0)
			and is_equal_approx(dialog.content_scale_factor, 2.0))

	# A dialog whose factor drifted (built at one zoom, popped at another)
	# is re-stamped on about_to_popup — the hook sync() armed on first entry.
	dialog.content_scale_factor = 1.0
	dialog.about_to_popup.emit()
	check("about_to_popup re-stamps the factor",
		is_equal_approx(dialog.content_scale_factor, 2.0))

	# The hook is idempotent: a window leaving and re-entering the tree is not
	# double-connected (a second connect would push a duplicate-connection
	# error, which the engine reports on the console).
	root.remove_child(dialog)
	root.add_child(dialog)
	check("re-entering the tree keeps one popup hook",
		dialog.about_to_popup.get_connections().size() == 1)

	# The root itself is never touched by its own hook.
	check("the root keeps its own factor", is_equal_approx(root.content_scale_factor, 2.0))

	dialog.free()
	stale.free()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)
