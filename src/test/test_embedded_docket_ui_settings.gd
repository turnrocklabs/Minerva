extends SceneTree
## Opening Minerva's embedded Docket panel must not restore standalone
## whole-window UI settings over the host's global scale or font.

var _pass_count: int = 0
var _fail_count: int = 0
var _zoom_in_calls: int = 0
var _tmp_dir: String = ""


class EmbeddedDocketProbe extends DocketPanel:
	# Keep the fixture from persisting session/last-query state on teardown.
	func _exit_tree() -> void:
		pass


func _initialize() -> void:
	print("=== Embedded Docket UI Settings Test ===\n")
	await process_frame

	_tmp_dir = OS.get_cache_dir().path_join("minerva_docket_ui_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)
	var db := DocketDB.create_new(_tmp_dir.path_join("embedded.db"))
	if db == null:
		check("fixture database opens", false)
		_finish()
		return
	db.set_project_name("embedded")
	db.set_meta_value("ui_scale", "0.75")
	db.set_meta_value("ui_font_size", "small")

	var dm := DocketManager.new()
	dm._project_dbs["embedded"] = db
	dm._project_paths["embedded"] = db.get_path()

	root.content_scale_factor = 1.6
	root.add_theme_font_size_override("font_size", 23)
	var panel := EmbeddedDocketProbe.new()
	panel.use_host_ui_settings(
		Callable(self, "_host_zoom_in"), Callable(), Callable())
	panel.init(dm)
	root.add_child(panel)
	await process_frame

	check("opening embedded Docket preserves the host scale",
		is_equal_approx(root.content_scale_factor, 1.6))
	check("opening embedded Docket preserves the host font override",
		root.get_theme_font_size("font_size") == 23)
	check("Docket's saved font preset is scoped to its panel",
		panel.get_theme_font_size("font_size") == 12)

	panel._on_menu_action("zoom_in")
	check("Docket Zoom In delegates to the host API",
		_zoom_in_calls == 1 and is_equal_approx(root.content_scale_factor, 1.64))

	panel.free()
	db.close()
	DirAccess.remove_absolute(db.get_path())
	DirAccess.remove_absolute(_tmp_dir)
	_finish()


func _host_zoom_in() -> void:
	_zoom_in_calls += 1
	root.content_scale_factor += 0.04


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)
