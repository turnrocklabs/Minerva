## DiskAccess — single home for filesystem read/write/exists.
##
## All operations route through PathResolver for normalization and policy.
## This is the only module that should call FileAccess directly for document
## bytes; everything else (DocumentRegistry, MCP tools, plugins) goes through
## DiskAccess so policy/normalization stays consistent.
class_name DiskAccess extends RefCounted

## Read a file's UTF-8 contents.
##
## Returns:
##   {ok: true, text: String} on success,
##   {ok: false, error: String} on failure (path empty, not_found, cannot_open).
static func read(path: String) -> Dictionary:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"ok": false, "error": resolved.error}

	var abs_path: String = resolved.path
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "error": "not_found: %s" % abs_path}

	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		var code := FileAccess.get_open_error()
		return {"ok": false, "error": "cannot_open: %s (code=%d)" % [abs_path, code]}

	var text := f.get_as_text()
	f.close()
	return {"ok": true, "text": text}


## Write text to a file (replaces existing contents).
##
## Returns:
##   {ok: true} on success,
##   {ok: false, error: String} on failure.
static func write(path: String, text: String) -> Dictionary:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"ok": false, "error": resolved.error}

	var abs_path: String = resolved.path
	# Create parent directories so writing a NEW file in a NEW dir works (parity
	# with the old WriteTool; benefits doc_save + disk_write). work item 019ea035bb28.
	var base_dir := abs_path.get_base_dir()
	if not base_dir.is_empty() and not DirAccess.dir_exists_absolute(base_dir):
		var mk := DirAccess.make_dir_recursive_absolute(base_dir)
		if mk != OK:
			return {"ok": false, "error": "cannot_create_dir: %s (code=%d)" % [base_dir, mk]}
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		var code := FileAccess.get_open_error()
		return {"ok": false, "error": "cannot_open_for_write: %s (code=%d)" % [abs_path, code]}

	f.store_string(text)
	f.close()
	return {"ok": true}


## Whether a file exists at the given path. Returns false on resolve failure.
static func exists(path: String) -> bool:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return false
	return FileAccess.file_exists(resolved.path)


## Filesystem metadata snapshot for change detection.
##
## Returns:
##   {ok: true, mtime: int, size: int} on success (mtime=0/size=0 if not found),
##   {ok: false, error: String} on resolve failure.
##
## Used by FileWatcherService and DocumentBuffer for external-change detection.
## Returns ok=true even when the file does not exist; the caller treats {0, 0}
## as the "not present" snapshot.
static func stat(path: String) -> Dictionary:
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"ok": false, "error": resolved.error}
	var abs_path: String = resolved.path
	if not FileAccess.file_exists(abs_path):
		return {"ok": true, "mtime": 0, "size": 0}
	var mtime := int(FileAccess.get_modified_time(abs_path))
	var size := 0
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f != null:
		size = int(f.get_length())
		f.close()
	return {"ok": true, "mtime": mtime, "size": size}
