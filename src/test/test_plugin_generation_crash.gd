extends SceneTree
## The external driver owns the random SIGKILL; this process never kills itself.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var script: Script = load("res://test/helpers/plugin_generation_crash_body.gd")
	var body = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
