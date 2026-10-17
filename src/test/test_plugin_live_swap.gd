extends SceneTree
## Autoload-backed host types must load after the project context is ready.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var script: Script = load("res://test/helpers/plugin_live_swap_test_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: live-swap test body did not compile")
		quit(1)
		return
	var body = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
