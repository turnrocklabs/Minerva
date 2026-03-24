class_name CwdTool
extends RefCounted
## GDScript port of CodeTools cwd.py
## Manages current working directory for file operations.
## Note: GDScript doesn't support os.chdir(), so we track cwd as a class variable.

var _current_cwd: String = ""

func _init():
	# Initialize with default directory (project root)
	_current_cwd = ProjectSettings.globalize_path("res://")


## Get the current working directory
func get_cwd() -> String:
	if _current_cwd.is_empty():
		return ProjectSettings.globalize_path("res://")
	return _current_cwd


## Set the current working directory
## Returns {success: bool, directory: string, action: string} or {success: false, error: string}
func set_cwd(path: String) -> Dictionary:
	# Expand ~ to home directory
	if path.begins_with("~"):
		path = path.replace("~", OS.get_environment("HOME"))

	# Check if path is absolute, if not make it absolute relative to current cwd
	if not path.begins_with("/"):
		var current = get_cwd()
		path = current.path_join(path)

	# Normalize the path
	path = path.simplify_path()

	# Validate directory exists
	if not DirAccess.dir_exists_absolute(path):
		return {
			"success": false,
			"error": "Directory does not exist: %s" % path
		}

	# Set the current directory
	_current_cwd = path

	return {
		"success": true,
		"directory": path,
		"action": "change"
	}
