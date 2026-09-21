extends SceneTree
## Fresh-process regression for the CAD inherited-member/update crash.
## MINERVA_CAD_UI_PATH may point at an isolated installed-plugin copy.

const DEFAULT_CAD_UI := "res://../../minerva-plugins/cad/ui"

var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Deferred execution lets project autoloads finish before plugin scripts load.
	await process_frame
	var ui_dir := OS.get_environment("MINERVA_CAD_UI_PATH")
	if ui_dir.is_empty():
		ui_dir = DEFAULT_CAD_UI
	var scene_path := "%s/CADPanel.tscn" % ui_dir.trim_suffix("/")
	var packed := ResourceLoader.load(
		scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	_check("CAD scene loads", packed != null)
	if packed == null:
		quit(1)
		return

	var panel := packed.instantiate()
	_check("CAD scene instantiates", panel != null)
	if panel == null:
		quit(1)
		return
	root.add_child(panel)
	await process_frame

	if not panel.has_method("get_geometry_checks") \
			or not panel.has_method("get_evaluation_state"):
		_check("CAD panel exposes integrity probes", false)
		await _free_panel(panel)
		quit(1)
		return
	var checks: Variant = panel.call("get_geometry_checks")
	_check("geometry checks initialize", checks != null)
	if checks == null:
		await _free_panel(panel)
		quit(1)
		return
	_check("inherited rim_test_count resolves", checks.get("rim_test_count") == 0)
	var evaluation: Variant = panel.call("get_evaluation_state")
	_check("evaluation state remains a Dictionary", evaluation is Dictionary)

	await _free_panel(panel)
	_check("CAD panel unloads cleanly", not is_instance_valid(panel))
	quit(1 if _failed else 0)


func _free_panel(panel: Node) -> void:
	panel.queue_free()
	await process_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		_failed = true
		printerr("FAIL: %s" % label)
