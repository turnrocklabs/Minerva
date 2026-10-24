## PathResolver — single home for path normalization and policy checks.
##
## Resolves Godot virtual paths (res://, user://) to absolute OS paths,
## expands ~ to the home directory, and applies any path-level policy.
##
## Minerva does not currently define a path-deny policy. The policy hook is
## present here as a future extension point so callers do not need to change
## once one is added.
##
## Convention: relative paths are passed through unchanged. Callers are
## expected to provide absolute paths (matches existing CodeTools convention).
class_name PathResolver extends RefCounted

## Resolve a path to an absolute OS path with policy applied.
##
## Returns:
##   {ok: true, path: String} on success,
##   {ok: false, error: String} on failure.
static func resolve(path: String) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "error": "path is empty"}

	var normalized := _normalize(path)

	# Future: path-level policy checks would go here.

	return {"ok": true, "path": normalized}


## Resolve existing symlink components before comparing write scopes. Missing
## directory suffixes remain attached to their resolved existing ancestor.
static func resolve_canonical(path: String) -> Dictionary:
	if path.contains(char(0)) or ".." in path.replace("\\", "/").split("/"):
		return {"ok": false, "error": "path must not contain null bytes or '..' segments"}
	var result: Dictionary = resolve(path)
	if not result.ok:
		return result
	var absolute: String = str(result.path).replace("\\", "/")
	var root: String = _absolute_root(absolute)
	if root.is_empty():
		return {"ok": false, "error": "path must be absolute or user://-prefixed"}
	var current: String = root
	var pending: PackedStringArray = absolute.trim_prefix(root).split("/", false)
	var links: int = 0
	while not pending.is_empty():
		var component: String = pending[0]
		pending.remove_at(0)
		if component == ".":
			continue
		if component == "..":
			# Link targets may contain '..': process it only AFTER resolving the
			# preceding component, rather than lexically collapsing a symlink.
			if current != root:
				current = current.get_base_dir()
				if current == root.trim_suffix("/"):
					current = root
			continue
		var parent: DirAccess = DirAccess.open(current)
		if parent != null and parent.is_link(component):
			links += 1
			if links > 40:
				return {"ok": false, "error": "path contains cyclic or excessive symlinks"}
			var target: String = parent.read_link(component).replace("\\", "/")
			if target.is_empty():
				return {"ok": false, "error": "path contains an unreadable symlink"}
			if target.is_absolute_path():
				root = _absolute_root(target)
				if root.is_empty():
					return {"ok": false, "error": "symlink target is not a supported absolute path"}
				current = root
				target = target.trim_prefix(root)
			var remaining: PackedStringArray = pending
			pending = target.split("/", false)
			pending.append_array(remaining)
		else:
			current = current.path_join(component)
	return {"ok": true, "path": current}


static func _absolute_root(path: String) -> String:
	if OS.get_name() == "Windows":
		if path.begins_with("//"):
			var parts: PackedStringArray = path.split("/", false)
			return "//%s/%s" % [parts[0], parts[1]] if parts.size() >= 2 else ""
		if path.length() >= 3 and path.substr(1, 2) == ":/":
			return path.left(3)
		return "" # Drive-relative paths do not identify a write scope.
	if path.begins_with("/"):
		return "/"
	return ""


## Normalize without policy. Useful for tests; production callers should use resolve().
static func _normalize(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)

	if path.begins_with("~"):
		var home := OS.get_environment("HOME")
		if home.is_empty():
			home = OS.get_environment("USERPROFILE")
		if not home.is_empty():
			return home + path.substr(1)

	return path
