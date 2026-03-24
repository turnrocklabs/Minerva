class_name WriteTool
extends RefCounted
## GDScript port of CodeTools write.py
## Writes content to files, creating directories as needed.

var _cwd_tool: CwdTool


func _init(cwd_tool: CwdTool = null):
	_cwd_tool = cwd_tool if cwd_tool else CwdTool.new()


## Write content to a file
## Returns {success: true, path: string, bytes_written: int}
## or {success: false, error: string}
func write_file(path: String, content: String) -> Dictionary:
	# If path is not absolute, resolve it relative to current working directory
	if not path.begins_with("/"):
		var cwd = _cwd_tool.get_cwd()
		path = cwd.path_join(path)

	# Normalize the path
	path = path.simplify_path()

	# Validate path is within workdir (prevent path traversal)
	# For now, we allow any absolute path since we don't enforce a strict workdir
	# In a stricter implementation, you could check against a configured base directory

	# Create parent directories if they don't exist
	var parent_dir = path.get_base_dir()
	if not parent_dir.is_empty():
		var dir_access = DirAccess.open(parent_dir)
		if dir_access == null:
			# Directory doesn't exist, create it recursively
			var result = DirAccess.make_dir_recursive_absolute(parent_dir)
			if result != OK:
				return {
					"success": false,
					"error": "Failed to create directories: %s" % parent_dir
				}

	# Write content
	var file_access = FileAccess.open(path, FileAccess.WRITE)
	if file_access == null:
		return {
			"success": false,
			"error": "Failed to open file for writing: %s" % path
		}

	file_access.store_string(content)
	var bytes_written = content.length()

	return {
		"success": true,
		"path": path,
		"bytes_written": bytes_written
	}
