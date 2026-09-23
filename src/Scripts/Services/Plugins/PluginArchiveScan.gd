extends RefCounted
## Reads a .tar.gz plugin archive's headers without extracting it, so an
## archive that would escape its extraction directory or fill the disk is
## refused before `tar` writes anything.
##
## Accepted: regular files, directories, and links whose target stays inside
## the archive root, under names that are relative and free of "..". pax
## ("x"/"g") and GNU long-name ("L"/"K") records are honoured, since they
## replace the next entry's name, link target, or size. Anything else
## (devices, FIFOs, sparse files, absolute or escaping names, or data on an
## entry that is not a file) is refused.
##
## Runs on PluginArchive's worker thread; `op.cancelled` is read between
## chunks.

const READ_CHUNK := 1 << 16
const BLOCK := 512

var _pending := PackedByteArray()
var _skip := 0          # data bytes of the current entry still to discard
var _capture := -1      # bytes of a pax / long-name record still to collect
var _captured := PackedByteArray()
var _capture_type := ""
var _next := {}         # overrides for the next entry: path, linkpath, size
var _zero_blocks := 0
var total_bytes := 0
var entries := 0


## {ok:true} after the whole archive has been read, else
## {ok:false, error, detail} with archive_unsafe / archive_too_large /
## archive_corrupt / cancelled.
func scan(archive_abs: String, max_bytes: int, op) -> Dictionary:
	var src := FileAccess.open(archive_abs, FileAccess.READ)
	if src == null:
		return _err("archive_corrupt", {"reason": "unreadable archive"})
	var gz := StreamPeerGZIP.new()
	if gz.start_decompression(false, READ_CHUNK) != OK:
		return _err("archive_corrupt", {"reason": "gzip stream could not start"})
	while not src.eof_reached():
		if op.cancelled:
			return _err("cancelled", {})
		var chunk := src.get_buffer(READ_CHUNK)
		var fed := 0
		while fed < chunk.size():
			var put: Array = gz.put_partial_data(chunk.slice(fed))
			if put[0] != OK:
				return _err("archive_corrupt", {"reason": "not a gzip stream"})
			fed += put[1]
			var problem := _drain(gz, max_bytes)
			if not problem.is_empty():
				return problem
	gz.finish()
	var problem := _drain(gz, max_bytes)
	if not problem.is_empty():
		return problem
	if _zero_blocks < 1:
		return _err("archive_corrupt", {"reason": "archive ends before its end-of-archive marker"})
	return {"ok": true}


func _drain(gz: StreamPeerGZIP, max_bytes: int) -> Dictionary:
	while gz.get_available_bytes() > 0:
		var got: Array = gz.get_partial_data(gz.get_available_bytes())
		if got[0] != OK:
			return _err("archive_corrupt", {"reason": "gzip data is damaged"})
		_pending.append_array(got[1])
		var problem := _consume(max_bytes)
		if not problem.is_empty():
			return problem
	return {}


## Walk whole 512-byte blocks of `_pending`, keeping any partial block.
func _consume(max_bytes: int) -> Dictionary:
	var at := 0
	while at + BLOCK <= _pending.size() or (_skip > 0 and at < _pending.size()):
		if _skip > 0:
			var n := mini(_skip, _pending.size() - at)
			if _capture > 0:
				var take := mini(n, _capture)
				_captured.append_array(_pending.slice(at, at + take))
				_capture -= take
				if _capture == 0:
					_apply_record()
			_skip -= n
			at += n
			continue
		var header := _pending.slice(at, at + BLOCK)
		at += BLOCK
		if _zero_blocks > 0 or header.count(0) == BLOCK:
			_zero_blocks += 1
			continue
		var problem := _header(header, max_bytes)
		if not problem.is_empty():
			return problem
	_pending = _pending.slice(at)
	return {}


func _header(h: PackedByteArray, max_bytes: int) -> Dictionary:
	var type := char(h[156]) if h[156] != 0 else "0"
	if h[124] & 0x80:
		return _err("archive_too_large", {"reason": "an entry is larger than 8 GiB", "limit": max_bytes})
	var size := _octal(h.slice(124, 136))
	var name := _cstr(h.slice(0, 100))
	# POSIX ustar ("ustar\0") has a name prefix; old GNU ("ustar  ") reuses
	# those bytes for times.
	if _cstr(h.slice(257, 263)) == "ustar" and h[262] == 0:
		var prefix := _cstr(h.slice(345, 500))
		if not prefix.is_empty():
			name = prefix + "/" + name
	var link := _cstr(h.slice(157, 257))
	if type in ["x", "g", "L", "K"]:
		_skip = _padded(size)
		# A global pax header applies to the whole archive; only its size matters.
		_capture = size if type != "g" else 0
		_captured = PackedByteArray()
		_capture_type = type
		return {}
	name = _next.get("path", name)
	link = _next.get("linkpath", link)
	size = _next.get("size", size)
	var sparse: bool = _next.get("sparse", false)
	_next = {}
	entries += 1
	if sparse:
		return _err("archive_unsafe", {"entry": name, "reason": "sparse file records are not supported"})
	# tar skips a header's data whatever its type; data on a non-file entry
	# could hide headers from this scan.
	if not type in ["0", "7"] and size > 0:
		return _err("archive_unsafe", {"entry": name, "reason": "a non-file entry carries data"})
	var path := name.trim_prefix("./")
	if path.is_empty() or path == "." or path == "./":
		if type == "5":
			return {}  # the archive root itself
		return _err("archive_unsafe", {"entry": name, "reason": "an entry replaces the archive root"})
	if not _contained(path):
		return _err("archive_unsafe", {"entry": name, "reason": "absolute or escaping path"})
	match type:
		"0", "7":
			total_bytes += size
			if total_bytes > max_bytes:
				return _err("archive_too_large", {"bytes": total_bytes, "limit": max_bytes})
			_skip = _padded(size)
		"5":
			pass
		"2":
			if link.is_absolute_path() or link.begins_with("\\") \
					or not _contained(path.get_base_dir().path_join(link)):
				return _err("archive_unsafe", {"entry": name, "reason": "symlink leaves the archive: " + link})
		"1":
			if not _contained(link.trim_prefix("./")):
				return _err("archive_unsafe", {"entry": name, "reason": "hard link leaves the archive: " + link})
		_:
			return _err("archive_unsafe", {"entry": name, "reason": "unsupported entry type '%s'" % type})
	return {}


## Apply a finished pax or GNU long-name record to the next entry.
func _apply_record() -> void:
	var text := _captured.get_string_from_utf8()
	match _capture_type:
		"L":
			_next["path"] = text.strip_edges(false, true).trim_suffix(char(0))
		"K":
			_next["linkpath"] = text.strip_edges(false, true).trim_suffix(char(0))
		"x":
			# Records are "<length> <key>=<value>\n".
			for line in text.split("\n", false):
				var body := line.substr(line.find(" ") + 1)
				var eq := body.find("=")
				if eq <= 0:
					continue
				var key := body.substr(0, eq)
				var value := body.substr(eq + 1)
				if key == "path" or key == "linkpath":
					_next[key] = value
				elif key.begins_with("GNU.sparse"):
					_next["sparse"] = true
				elif key == "size":
					_next["size"] = int(value)


## A relative path whose ".." components never climb above the archive root.
static func _contained(path: String) -> bool:
	if path.is_absolute_path() or path.begins_with("\\") or path.contains(":"):
		return false
	var depth := 0
	for part in path.replace("\\", "/").split("/", false):
		if part == "..":
			depth -= 1
			if depth < 0:
				return false
		elif part != ".":
			depth += 1
	return true


static func _octal(field: PackedByteArray) -> int:
	var value := 0
	for b in field:
		if b >= 0x30 and b <= 0x37:
			value = value * 8 + (b - 0x30)
		elif value > 0 or b == 0:
			break
	return value


static func _cstr(field: PackedByteArray) -> String:
	var end := field.find(0)
	return (field if end < 0 else field.slice(0, end)).get_string_from_utf8()


static func _padded(size: int) -> int:
	return (size + BLOCK - 1) / BLOCK * BLOCK


static func _err(code: String, detail: Dictionary) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}
