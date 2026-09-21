extends SceneTree
## Load the PluginManager-dependent test body after project autoloads register.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var body_script: Script = load("res://test/helpers/plugin_manager_hot_reload_test_body.gd")
	if body_script == null or not body_script.can_instantiate():
		printerr("FAIL: plugin manager hot-reload test body did not compile")
		quit(1)
		return
	var body = body_script.new()
	body.completed.connect(func(exit_code: int) -> void: quit(exit_code))
	root.add_child(body)
