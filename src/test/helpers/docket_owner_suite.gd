extends Node
## Scene-hosted suite: use the project's SceneTree and its live autoloads.
var root: Window:
	get:
		return get_tree().root
var process_frame: Signal:
	get:
		return get_tree().process_frame


func quit(code: int) -> void:
	get_tree().quit(code)
