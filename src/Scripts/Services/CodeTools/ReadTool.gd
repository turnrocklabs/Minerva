## Port of CodeTools read.py to GDScript.
## Reads file contents with optional offset (0-based line number) and limit (max lines).
##
## Ported from: https://github.com/imran/CodeTools/src/codetools/tools/read.py
class_name ReadTool extends RefCounted


## Read a file and return its contents with line numbers.
##
## Args:
##   path: Absolute or relative file path to read
##   offset: 0-based line number to start from (default: 0)
##   limit: Maximum number of lines to return (default: 0 = all, capped at 2000)
##
## Returns:
##   Dictionary with keys:
##     - success: bool (true if read succeeded)
##     - content: str (formatted lines with numbers, or error message)
##     - lines_read: int (number of lines in selected range)
##     - total_lines: int (total lines in file)
##     - truncated: bool (true if output was truncated)
##     - binary: bool (true if file is binary)
##     - error: str (error message if success=false)
static func read_file(path: String, offset: int = 0, limit: int = 0) -> Dictionary:
	# Resolve Godot virtual paths to absolute OS paths. Relative paths are
	# left for the caller to join with cwd — this tool only owns the virtual
	# → absolute expansion.
	var file_path := path
	if path.begins_with("user://") or path.begins_with("res://"):
		file_path = ProjectSettings.globalize_path(path)

	# Check if file exists
	if not FileAccess.file_exists(file_path):
		return {
			"success": false,
			"error": "File not found: %s" % file_path,
			"content": "",
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": false,
		}

	# Check if path is a directory (Godot's FileAccess can't easily check this)
	# We'll try to open it; if it fails, assume it's a directory
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		# Could be a directory or permission denied
		var error := FileAccess.get_open_error()
		return {
			"success": false,
			"error": "Cannot read file (directory or permission denied): %s (error code: %d)" % [file_path, error],
			"content": "",
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": false,
		}

	# Read entire file as bytes first to check for binary content
	var content_bytes: PackedByteArray = file.get_buffer(file.get_length())
	file = null  # Close file

	# Check for null bytes in first 8192 bytes (binary indicator)
	var check_len: int = mini(8192, content_bytes.size())
	var is_binary: bool = false
	for i in range(check_len):
		if content_bytes[i] == 0:
			is_binary = true
			break

	if is_binary:
		return {
			"success": true,
			"content": "[Binary file: %d bytes]" % content_bytes.size(),
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": true,
		}

	# Decode as UTF-8
	var text := content_bytes.get_string_from_utf8()
	if text.is_empty() and content_bytes.size() > 0:
		# Likely a binary file (UTF-8 decode failed)
		return {
			"success": true,
			"content": "[Binary file: %d bytes]" % content_bytes.size(),
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": true,
		}

	# Split into lines (keeping newlines for now)
	var lines := text.split("\n")
	var total_lines := lines.size()

	# Handle empty file
	if text.is_empty():
		return {
			"success": true,
			"content": "",
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": false,
		}

	# Apply offset (0-based, but clamped to valid range)
	var start := clampi(offset, 0, total_lines)

	# Apply limit (default 2000 if not specified or 0)
	var max_lines := limit if limit > 0 else 2000
	var end := mini(start + max_lines, total_lines)

	# Extract selected lines
	var selected_lines: Array[String] = []
	for i in range(start, end):
		selected_lines.append(lines[i])

	var lines_read := selected_lines.size()
	var truncated := end < total_lines

	# Format with line numbers (cat -n style)
	var max_line_width := len(str(start + lines_read))
	var formatted_lines: Array[String] = []

	for i in range(lines_read):
		var line := selected_lines[i]
		var line_number := start + i + 1

		# Remove trailing newlines
		line = line.trim_suffix("\r").trim_suffix("\n")

		# Truncate long lines (>2000 chars)
		if len(line) > 2000:
			line = line.substr(0, 2000) + "... [truncated]"

		# Format: "  1\tline content" (right-aligned line number)
		var formatted := "%*d\t%s" % [max_line_width, line_number, line]
		formatted_lines.append(formatted)

	var formatted_content := "\n".join(formatted_lines)

	return {
		"success": true,
		"content": formatted_content,
		"lines_read": lines_read,
		"total_lines": total_lines,
		"truncated": truncated,
		"binary": false,
	}


## Format an in-memory text string with line numbers / offset / limit, returning
## the same response shape as read_file but without doing any disk IO.
##
## Used by minerva_doc_read after pulling text via DocumentRegistry, so the
## response shape (numbered lines, offset/limit semantics) stays consistent
## with disk-backed read_file calls.
static func format_text(text: String, offset: int = 0, limit: int = 0) -> Dictionary:
	if text.is_empty():
		return {
			"success": true,
			"content": "",
			"lines_read": 0,
			"total_lines": 0,
			"truncated": false,
			"binary": false,
		}

	var lines := text.split("\n")
	var total_lines := lines.size()
	var start := clampi(offset, 0, total_lines)
	var max_lines := limit if limit > 0 else 2000
	var end := mini(start + max_lines, total_lines)

	var selected_lines: Array[String] = []
	for i in range(start, end):
		selected_lines.append(lines[i])

	var lines_read := selected_lines.size()
	var truncated := end < total_lines

	var max_line_width := len(str(start + lines_read))
	var formatted_lines: Array[String] = []
	for i in range(lines_read):
		var line := selected_lines[i]
		var line_number := start + i + 1
		line = line.trim_suffix("\r").trim_suffix("\n")
		if len(line) > 2000:
			line = line.substr(0, 2000) + "... [truncated]"
		var formatted := "%s\t%s" % [_format_padded(line_number, max_line_width), line]
		formatted_lines.append(formatted)

	return {
		"success": true,
		"content": "\n".join(formatted_lines),
		"lines_read": lines_read,
		"total_lines": total_lines,
		"truncated": truncated,
		"binary": false,
	}


## Helper: format a number with right-alignment padding.
## Godot's % operator doesn't support *N width, so we do it manually.
static func _format_padded(number: int, width: int) -> String:
	var s := str(number)
	var padding := width - len(s)
	if padding > 0:
		s = " ".repeat(padding) + s
	return s
