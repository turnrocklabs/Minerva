extends SceneTree
func _init() -> void:
	await process_frame
	var script: Script = load("res://test/helpers/plugin_dependencies_test_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: dependency test body did not compile")
		quit(1)
		return
	var body: Node = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
