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
