## Port of CodeTools glob.py to GDScript.
## Finds files matching a glob pattern, walking directories via DirAccess.
##
## Ported from: https://github.com/imran/CodeTools/src/codetools/tools/glob.py
class_name GlobTool extends RefCounted


## Directories always skipped during traversal (mirrors the Python implementation).
const EXCLUDE_DIRS: Array[String] = [
	".git",
	"node_modules",
	"__pycache__",
	".venv",
	"venv",
	".tox",
	".mypy_cache",
	".pytest_cache",
	"dist",
	"build",
	".egg-info",
]

## Maximum directory recursion depth to prevent symlink loops.
const MAX_DEPTH: int = 64


## Find files matching a glob pattern under base_dir.
##
## Args:
##   pattern: Glob pattern, e.g. "**/*.gd" or "src/*.py" or "file?.txt"
##            Supports: * (any filename chars), ** (any path including /), ? (single char)
##   base_dir: Root directory to search (default: "" uses OS.get_executable_path() dir,
##             or falls back to the path embedded in an absolute pattern)
##   limit: Maximum number of results to return (default: 100, 0 = unlimited)
##
## Returns a Dictionary:
##   On success: {success: true, files: Array[String], total_matches: int, truncated: bool}
##     files contains paths relative to base_dir, sorted alphabetically.
##   On error:   {success: false, error: String}
static func glob_files(pattern: String, base_dir: String = "", limit: int = 100) -> Dictionary:
	# Resolve base directory.
	var root: String
	if base_dir != "":
		root = base_dir
	else:
		# Default to the directory of the running executable (mirrors Python's Path.cwd()).
		root = OS.get_executable_path().get_base_dir()

	# Normalise: remove trailing slash so path arithmetic is consistent.
	root = root.rstrip("/")

	# Validate that the root exists.
	if not DirAccess.dir_exists_absolute(root):
		return {
			"success": false,
			"error": "Directory not found: %s" % root,
		}

	# Convert the glob pattern to a RegEx that matches a full relative path.
	# The regex itself encodes depth constraints:
	#   *.gd        → ^[^/]*\.gd$      (only matches names with no slash, i.e. top-level)
	#   **/*.gd     → ^.*[^/]*\.gd$    (matches across any depth)
	#   src/*.gd    → ^src/[^/]*\.gd$  (matches exactly one level under src/)
	# We always recurse into subdirectories so that patterns with directory
	# prefixes (e.g. "Scripts/Services/CodeTools/GlobTool.gd") work correctly.
	var regex_str := _glob_to_regex(pattern)
	var rx := RegEx.new()
	var compile_err := rx.compile(regex_str)
	if compile_err != OK:
		return {
			"success": false,
			"error": "Invalid glob pattern (regex compile failed): %s" % pattern,
		}

	# Walk the directory tree and collect matching file paths.
	var all_matches: Array[String] = []
	_walk(root, root, rx, 0, all_matches)

	# Sort alphabetically (Python sorts by mtime; GDScript has no cheap mtime — alpha is cleaner).
	all_matches.sort()

	var total_matches := all_matches.size()
	var truncated := false
	if limit > 0 and total_matches > limit:
		truncated = true
		all_matches = all_matches.slice(0, limit)

	return {
		"success": true,
		"files": all_matches,
		"total_matches": total_matches,
		"truncated": truncated,
	}


# ── Internal helpers ──────────────────────────────────────────────────────────

## Recursively walk dir_path, collecting file paths (relative to root) that
## match rx.  Always descends into subdirectories; the regex itself determines
## whether paths at various depths are matched.
static func _walk(
	root: String,
	dir_path: String,
	rx: RegEx,
	depth: int,
	results: Array[String],
) -> void:
	if depth > MAX_DEPTH:
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return  # Permission denied or other error — skip silently.

	dir.include_hidden = true
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry == "":
			break
		if entry == "." or entry == "..":
			continue

		var full_path := dir_path.path_join(entry)
		var rel_path := full_path.substr(root.length() + 1)  # Strip "root/" prefix.

		if dir.current_is_dir():
			# Skip excluded directory names.
			if entry in EXCLUDE_DIRS:
				continue
			_walk(root, full_path, rx, depth + 1, results)
		else:
			# It is a file — test against the compiled regex.
			if rx.search(rel_path) != null:
				results.append(rel_path)

	dir.list_dir_end()


## Convert a glob pattern to a full-match RegEx string.
##
## Conversion rules:
##   **   → .*          (matches anything including directory separators)
##   *    → [^/]*       (matches any filename characters, no slash)
##   ?    → [^/]        (matches exactly one filename character, no slash)
##   .    → \.          (literal dot)
##   other special regex chars → escaped
##
## The result is anchored with ^ and $ so it must match the entire relative path.
static func _glob_to_regex(pattern: String) -> String:
	var result := ""
	var i := 0
	var n := pattern.length()

	while i < n:
		var ch := pattern[i]

		if ch == "*":
			if i + 1 < n and pattern[i + 1] == "*":
				# "**" — match any sequence of characters including slashes.
				result += ".*"
				i += 2
				# Consume an optional following slash so "**/" works as expected.
				if i < n and pattern[i] == "/":
					result += "(/|$)"
					i += 1
			else:
				# Single "*" — match anything except a slash.
				result += "[^/]*"
				i += 1
		elif ch == "?":
			result += "[^/]"
			i += 1
		elif ch == ".":
			result += "\\."
			i += 1
		elif ch in ["+", "^", "$", "{", "}", "[", "]", "(", ")", "|", "\\"]:
			result += "\\" + ch
			i += 1
		else:
			result += ch
			i += 1

	return "^" + result + "$"
