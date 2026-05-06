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
