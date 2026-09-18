extends SceneTree
## Load the typed panel-broker test body after project autoloads register.
##
## Run: godot --headless --path src --script test/test_plugin_scene_panel_keying.gd
##      (registered in scripts/run-functional-tests.sh PCB_GUARD_TESTS.)

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var body = load("res://test/helpers/plugin_scene_panel_keying_test_body.gd").new()
	body.completed.connect(func(exit_code: int) -> void: quit(exit_code))
	root.add_child(body)
