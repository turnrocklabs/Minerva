extends RefCounted
## Writes a file so that a reader, or a process started after a crash, sees
## its old content or its new content, never a mix: the text goes to
## <path>.tmp, which is then moved over <path> in one step. The file is
## flushed but not synced to disk, so a power loss may still lose it.


## Write `text` to `path` (absolute). False, with `path` untouched, on failure.
static func write(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	var stored := file.store_string(text)
	file.flush()
	file.close()
	return stored and replace(tmp, path)


## Move `from` over `to` in one step, with ProcessFileLock.replace_file.
## Without that native class, Unix rename still does this; Windows has no
## such fallback, so there every write fails.
static func replace(from: String, to: String) -> bool:
	if not ClassDB.class_exists("ProcessFileLock"):
		return OS.get_name() != "Windows" and DirAccess.rename_absolute(from, to) == OK
	# Windows refuses to replace a file another process has open to read
	# (without delete sharing); such a reader is gone in moments.
	for attempt in 10:
		if ClassDB.class_call_static("ProcessFileLock", "replace_file", from, to) == OK:
			return true
		OS.delay_msec(20)
	return false
