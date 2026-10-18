extends SceneTree
## Runtime-loaded body keeps autoload-dependent UI classes out of --script compilation.
func _init() -> void:
	await process_frame
	var script: Script = load("res://test/helpers/plugin_editor_create_test_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: plugin editor create body did not compile")
		quit(1)
		return
	var body: Node = script.new()
	body.completed.connect(func(code: int) -> void: quit(code))
	root.add_child(body)
	create_timer(45.0).timeout.connect(func() -> void:
		printerr("FAIL: plugin editor create characterization stalled")
		quit(1))
