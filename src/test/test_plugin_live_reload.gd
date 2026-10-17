extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if "--live-integration-child" not in OS.get_cmdline_user_args():
		var evidence := OS.get_environment("MINERVA_TEST_LOG_DIR")
		if evidence.is_empty():
			evidence = ProjectSettings.globalize_path("user://live-integration-evidence")
		elif not evidence.is_absolute_path():
			evidence = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join(evidence)
		var output: Array = []
		var python := "python" if OS.get_name() == "Windows" else "python3"
		var code := OS.execute(python, PackedStringArray([
			ProjectSettings.globalize_path("res://test/helpers/plugin_live_reload_driver.py"),
			"--godot", OS.get_executable_path(), "--project", ProjectSettings.globalize_path("res://"),
			"--evidence", evidence, "--seed-user-dir", ProjectSettings.globalize_path("user://")]), output, true)
		for line: Variant in output:
			print(str(line))
		quit(0 if code == 0 else 1)
		return
	var script: Script = load("res://test/helpers/plugin_live_reload_test_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: live-reload integration test body did not compile")
		quit(1)
		return
	var body = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
