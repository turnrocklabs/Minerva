extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var script: Script = load("res://test/helpers/plugin_live_actions_body.gd")
	var body = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
