class_name EditTool
extends RefCounted
## Targeted string replacement in files. Ported from CodeTools edit.py.

static func edit_file(path: String, old_string: String, new_string: String, replace_all: bool = false) -> Dictionary:
	## Replace old_string with new_string in the file at path.
	## If replace_all is false (default), old_string must be unique in the file.
	## Returns {success, replacements, path} or {success: false, error}.

	if old_string == new_string:
		return {"success": false, "error": "old_string and new_string are identical"}

	if old_string.is_empty():
		return {"success": false, "error": "old_string cannot be empty"}

	if not FileAccess.file_exists(path):
		return {"success": false, "error": "File not found: %s" % path}

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"success": false, "error": "Cannot open file: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}

	var content := file.get_as_text()
	file.close()

	# Count occurrences
	var count := content.count(old_string)

	if count == 0:
		return {"success": false, "error": "String not found in file: %s" % old_string.substr(0, 100)}

	if count > 1 and not replace_all:
		return {"success": false, "error": "Found %d occurrences. Use replace_all=true or provide more context." % count}

	# Perform replacement
	var new_content: String
	var replacements: int
	if replace_all:
		new_content = content.replace(old_string, new_string)
		replacements = count
	else:
		# Replace first occurrence only
		var idx := content.find(old_string)
		new_content = content.substr(0, idx) + new_string + content.substr(idx + old_string.length())
		replacements = 1

	# Write back
	file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return {"success": false, "error": "Cannot write file: %s" % path}
	file.store_string(new_content)
	file.close()

	return {"success": true, "replacements": replacements, "path": path}
