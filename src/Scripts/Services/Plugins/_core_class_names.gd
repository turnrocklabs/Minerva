class_name CoreClassNames
extends RefCounted
## Lazy cache of class_name identifiers declared in Minerva's core GDScript files.
##
## Scans res://Scripts/**/*.gd recursively on first call and caches the result
## for the lifetime of the process.  Does NOT scan at import time.
##
## Design §6.2 — used by PluginDB.install() to reject plugins whose class_names
## collide with core identifiers.

# Populated on first call to get(), then reused.
static var _cached: Array[String] = []
static var _loaded: bool = false

## Return the Array[String] of core class_names.
## Scans res://Scripts/**/*.gd on the first call; subsequent calls return the
## cached array.  Safe to call from the main thread only.
static func get() -> Array[String]:
	if _loaded:
		return _cached
	_cached = _scan_dir("res://Scripts")
	_loaded = true
	return _cached


## Force a re-scan on the next call to get().
## Useful in tests where the virtual filesystem has been modified.
static func invalidate() -> void:
	_loaded = false
	_cached.clear()


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Recursively scan `dir_path` for *.gd files and collect class_name identifiers.
static func _scan_dir(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result

	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue

		var full: String = dir_path.path_join(entry)

		if dir.current_is_dir():
			var sub := _scan_dir(full)
			for cn in sub:
				result.append(cn)
		elif entry.ends_with(".gd"):
			var cn: String = _scan_file(full)
			if not cn.is_empty():
				result.append(cn)

		entry = dir.get_next()
	dir.list_dir_end()

	return result


## Scan a single .gd file for a top-level class_name declaration.
## Mirrors PluginDefinition._scan_script_for_class_name() but operates on
## res:// paths (which FileAccess handles directly in Godot).
static func _scan_file(res_path: String) -> String:
	var file := FileAccess.open(res_path, FileAccess.READ)
	if not file:
		return ""
	var lines_checked := 0
	while not file.eof_reached() and lines_checked < 40:
		var line: String = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		lines_checked += 1
		if line.begins_with("class_name"):
			var rest: String = line.substr(len("class_name")).strip_edges()
			var space_pos: int = rest.find(" ")
			var cn: String = rest.substr(0, space_pos) if space_pos != -1 else rest
			cn = cn.strip_edges()
			if not cn.is_empty() and cn[0] == cn[0].to_upper() and cn[0] != cn[0].to_lower():
				return cn
		if not line.begins_with("@tool") and not line.begins_with("@icon"):
			break
	return ""
