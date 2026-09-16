extends SceneTree
## Load the typed identity test body only after project autoloads are available.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var body = load("res://test/helpers/document_identity_test_body.gd").new()
	body.completed.connect(func(exit_code: int) -> void: quit(exit_code))
	root.add_child(body)
