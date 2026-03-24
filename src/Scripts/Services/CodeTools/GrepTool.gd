class_name GrepTool
extends RefCounted
## Search file contents using regex patterns. Ported from CodeTools grep.py.

const SKIP_DIRS: Array[String] = [
	".git", "node_modules", "__pycache__", ".venv", "venv",
	".tox", ".mypy_cache", ".pytest_cache", ".godot", ".zig-cache",
]

const TYPE_EXTENSIONS: Dictionary = {
	"py": [".py", ".pyi"],
	"js": [".js", ".mjs", ".cjs"],
	"ts": [".ts", ".tsx"],
	"go": [".go"],
	"rust": [".rs"],
	"java": [".java"],
	"c": [".c", ".h"],
	"cpp": [".cpp", ".cc", ".cxx", ".hpp", ".hh"],
	"gd": [".gd"],
	"gdscript": [".gd"],
	"sh": [".sh", ".bash"],
	"md": [".md", ".markdown"],
	"json": [".json"],
	"yaml": [".yaml", ".yml"],
	"toml": [".toml"],
	"html": [".html", ".htm"],
	"css": [".css", ".scss", ".sass"],
	"zig": [".zig"],
}


static func grep_files(pattern: String, path: String = "", file_glob: String = "",
		type_filter: String = "", ignore_case: bool = false,
		context_lines: int = 0, limit: int = 100) -> Dictionary:
	## Search for regex pattern in files.
	## Returns {matches: [{file, line, content, context_before?, context_after?}], total_matches, truncated}

	# Compile regex
	var regex := RegEx.new()
	var regex_pattern := pattern
	if ignore_case:
		regex_pattern = "(?i)" + regex_pattern
	var err := regex.compile(regex_pattern)
	if err != OK:
		return {"success": false, "error": "Invalid regex: %s" % pattern}

	if path.is_empty():
		path = OS.get_environment("PWD")
		if path.is_empty():
			path = "."

	# Determine files to search
	var files: Array[String] = []
	if FileAccess.file_exists(path):
		files.append(path)
	elif DirAccess.dir_exists_absolute(path):
		files = _collect_files(path, file_glob, type_filter)
	else:
		return {"success": false, "error": "Path not found: %s" % path}

	# Search
	var matches: Array[Dictionary] = []
	var total: int = 0

	for file_path in files:
		if _is_binary(file_path):
			continue

		var file := FileAccess.open(file_path, FileAccess.READ)
		if not file:
			continue

		var content := file.get_as_text()
		file.close()

		var lines := content.split("\n")

		for line_num in range(lines.size()):
			var line: String = lines[line_num]
			if regex.search(line):
				total += 1

				if matches.size() < limit:
					var match_data: Dictionary = {
						"file": file_path,
						"line": line_num + 1,
						"content": line,
					}

					if context_lines > 0:
						var start := maxi(0, line_num - context_lines)
						var end := mini(lines.size(), line_num + context_lines + 1)
						match_data["context_before"] = lines.slice(start, line_num)
						match_data["context_after"] = lines.slice(line_num + 1, end)

					matches.append(match_data)

	return {
		"success": true,
		"matches": matches,
		"total_matches": total,
		"truncated": total > limit,
	}


static func _collect_files(dir_path: String, file_glob: String, type_filter: String) -> Array[String]:
	## Recursively collect files, respecting skip dirs and filters.
	var results: Array[String] = []
	_walk_dir(dir_path, dir_path, file_glob, type_filter, results, 0)
	return results


static func _walk_dir(base: String, current: String, file_glob: String,
		type_filter: String, results: Array[String], depth: int) -> void:
	if depth > 20:  # max recursion guard
		return

	var dir := DirAccess.open(current)
	if not dir:
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with(".") and name != ".":
			name = dir.get_next()
			continue

		var full_path := current.path_join(name)

		if dir.current_is_dir():
			if name not in SKIP_DIRS:
				_walk_dir(base, full_path, file_glob, type_filter, results, depth + 1)
		else:
			# Type filter
			if not type_filter.is_empty() and type_filter in TYPE_EXTENSIONS:
				var exts: Array = TYPE_EXTENSIONS[type_filter]
				var matches_type := false
				for ext in exts:
					if name.ends_with(ext):
						matches_type = true
						break
				if not matches_type:
					name = dir.get_next()
					continue

			# Glob filter (simple: match filename against pattern)
			if not file_glob.is_empty():
				if not name.matchn(file_glob) and not full_path.matchn(file_glob):
					name = dir.get_next()
					continue

			results.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()


static func _is_binary(path: String) -> bool:
	## Check if file is binary by looking for null bytes in first 8KB.
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return true
	var chunk := file.get_buffer(8192)
	file.close()
	for i in range(chunk.size()):
		if chunk[i] == 0:
			return true
	return false
