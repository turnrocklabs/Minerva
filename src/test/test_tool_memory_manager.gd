extends SceneTree
## Unit tests for ToolMemoryManager.
## Run: godot --headless --path src --script test/test_tool_memory_manager.gd


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	# Runtime loading lets project autoload classes register before the suite compiles.
	await process_frame
	await process_frame
	var suite = load("res://test/fixtures/tool_memory_manager_suite.gd").new()
	var result: Dictionary = suite.run()
	var passed := int(result.get("passed", 0))
	var failed := int(result.get("failed", 0))
	var skipped := int(result.get("skipped", 0))
	var expected := passed == 53 and failed == 0 and skipped == 0
	if not expected:
		printerr("ToolMemoryManager expected 53/0/0, got %d/%d/%d" % [passed, failed, skipped])
	quit(0 if expected else 1)
