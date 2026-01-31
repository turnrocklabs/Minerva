@tool
extends EditorPlugin

const SYNC_PAIRS = [
	["../README.md", "res://README.md"],
	["../LICENSE.md", "res://LICENSE.md"],
]


func _enter_tree():
	_sync_files()


func _sync_files():
	var project_root = ProjectSettings.globalize_path("res://")
	for pair in SYNC_PAIRS:
		var source_path = project_root.path_join(pair[0]).simplify_path()
		var dest_path = ProjectSettings.globalize_path(pair[1])
		_copy_if_different(source_path, dest_path)


func _copy_if_different(source: String, dest: String):
	var source_file = FileAccess.open(source, FileAccess.READ)
	if not source_file:
		push_warning("FileSync: Cannot read source file: %s" % source)
		return
	var source_content = source_file.get_as_text()
	source_file.close()

	var dest_file = FileAccess.open(dest, FileAccess.READ)
	var dest_content = ""
	if dest_file:
		dest_content = dest_file.get_as_text()
		dest_file.close()

	if source_content != dest_content:
		var write_file = FileAccess.open(dest, FileAccess.WRITE)
		if write_file:
			write_file.store_string(source_content)
			write_file.close()
			print("FileSync: Synced %s" % dest.get_file())
		else:
			push_error("FileSync: Cannot write to %s" % dest)
