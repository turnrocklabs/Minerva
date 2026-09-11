extends Node
var starts := 0
var finishes := 0

func start() -> void:
	pass

func stop() -> void:
	pass

func check_dismiss_phrase(_text: String) -> bool:
	return false

func notify_tts_started() -> void:
	starts += 1

func notify_tts_finished() -> void:
	finishes += 1
