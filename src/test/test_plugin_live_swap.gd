extends SceneTree
## Autoload-backed host types must load after the project context is ready.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if "--live-swap-child" not in OS.get_cmdline_user_args():
		var output: Array = []
		var python := OS.get_environment("PYTHON")
		if python.is_empty():
			python = "python" if OS.get_name() == "Windows" else "python3"
		var evidence := OS.get_environment("MINERVA_TEST_LOG_DIR")
		if evidence.is_empty():
			evidence = ProjectSettings.globalize_path("user://live-swap-evidence")
		elif not evidence.is_absolute_path():
			evidence = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join(evidence)
		var code := OS.execute(python, PackedStringArray([
			ProjectSettings.globalize_path("res://test/helpers/plugin_live_swap_driver.py"),
			"--godot", OS.get_executable_path(), "--project", ProjectSettings.globalize_path("res://"),
			"--evidence", evidence]), output, true)
		print("PASS: isolated negative-case driver" if code == 0 else "FAIL: isolated negative-case driver")
		for line: Variant in output:
			print(str(line))
		quit(0 if code == 0 else 1)
		return
	var script: Script = load("res://test/helpers/plugin_live_swap_test_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: live-swap test body did not compile")
		quit(1)
		return
	var body = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
