extends RefCounted
## Only obsolete generation archives and retired cache trees are disposable.
## Call after publication; never touch installed files, selectors or user data.
const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")


static func collect(store: PluginGenerationStore, record: Dictionary, pending_digest: String = "") -> Dictionary:
	var directory := store.directory
	var expected_parent := ProjectSettings.globalize_path("user://plugins/.generations")
	if directory != directory.simplify_path() or directory.get_base_dir() != expected_parent \
		or Store._has_link(directory) or not Store.valid_digest(str(record.get("active", ""))):
		return {"ok": false, "error": "Generation cleanup refused an invalid root or selector"}
	var keep: Array[String] = [str(record.active), str(record.get("lkg", "")), pending_digest]
	var dir := DirAccess.open(directory)
	if dir == null:
		return {"ok": false, "error": "Cannot open generation cleanup root"}
	dir.include_hidden = true
	var targets: Array[String] = []
	for filename: String in dir.get_files():
		if filename.ends_with(".json") and Store.valid_digest(filename.get_basename()) \
			and filename.get_basename() not in keep:
			targets.append(directory.path_join(filename))
	var retired := RegEx.new()
	retired.compile("^retired-[AB]-[0-9]+$")
	for filename: String in dir.get_directories():
		if retired.search(filename) != null:
			targets.append(directory.path_join(filename))
	# Validate the whole plan before the first delete. No link can be followed,
	# including a link in an otherwise obsolete cache tree.
	for path: String in targets:
		if not _safe_tree(path, directory):
			return {"ok": false, "error": "Generation cleanup refused a symlink or path escape: " + path}
	for path: String in targets:
		var error := _remove_tree(path, directory)
		if error != OK:
			return {"ok": false, "error": "Generation cleanup failed: " + path + ": " + error_string(error)}
	return {"ok": true, "removed": targets.size()}


static func _safe_tree(path: String, root: String) -> bool:
	if path != path.simplify_path() or not path.begins_with(root + "/") or Store._has_link(path):
		return false
	if not DirAccess.dir_exists_absolute(path):
		return FileAccess.file_exists(path)
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.include_hidden = true
	for filename: String in dir.get_files() + dir.get_directories():
		if not _safe_tree(path.path_join(filename), root):
			return false
	return true


static func _remove_tree(path: String, root: String) -> Error:
	if not _safe_tree(path, root):
		return ERR_INVALID_PARAMETER
	if DirAccess.dir_exists_absolute(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return ERR_CANT_OPEN
		dir.include_hidden = true
		for filename: String in dir.get_files() + dir.get_directories():
			var error := _remove_tree(path.path_join(filename), root)
			if error != OK:
				return error
	return DirAccess.remove_absolute(path)
