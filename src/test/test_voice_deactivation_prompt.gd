extends SceneTree

var passed := 0
var failed := 0


func _init() -> void:
	await process_frame
	var Prompt = load("res://Scripts/Services/Voice/VoiceDeactivationPrompt.gd")
	var prompt = Prompt.new()
	root.add_child(prompt)
	var accepted := {}
	_capture(prompt, accepted)
	await process_frame
	prompt.dialog.get_ok_button().pressed.emit()
	await process_frame
	check("real dialog OK resolves accepted despite hiding first", accepted.get("value") == true)
	prompt.free()
	prompt = Prompt.new()
	root.add_child(prompt)
	var canceled := {}
	_capture(prompt, canceled)
	await process_frame
	prompt.dialog.get_cancel_button().pressed.emit()
	await process_frame
	check("real dialog Cancel resolves rejected", canceled.get("value") == false)
	prompt.free()
	print("Voice deactivation prompt: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)


func _capture(prompt, output: Dictionary) -> void:
	output.value = await prompt.ask(root)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)
