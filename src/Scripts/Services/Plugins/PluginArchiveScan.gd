extends RefCounted
## Reads a .tar.gz plugin archive's headers without extracting it, so an
## archive that would escape its extraction directory, fill the disk, or be
## read differently by `tar` than by this scan is refused before `tar` writes
## anything. Deliberately limited to what published packages use (GNU tar
## and bsdtar output): anything it does not fully understand fails closed.
##
## Accepted entries: regular files, directories, and symlinks or hard links
## whose target stays inside the archive, under relative names free of ".."
## escapes and backslashes, never written through an earlier symlink. Symlink
## names and targets are ASCII and compared ignoring case; an archive may hold
## hard links or symlinks but not both.
##
## Accepted metadata: GNU long names ("L"/"K") and pax records ("x" per
## entry, "g" global), parsed exactly by their byte lengths. Of pax keys only
## path, linkpath and size change how an entry is read (each at most once,
## never empty, never in a global record); times, ownership, comments,
## xattrs, ACLs, symlink type and a UTF-8 hdrcharset are ignored as harmless.
## File flags (SCHILY.fflags) are refused: an immutable flag would stop
## Minerva removing the files later. Every other entry type or pax key is
## refused, as are size and checksum fields that are not plain digits and
## headers whose checksum is wrong, which tar implementations read
## differently. Metadata records, entry count, and total decompressed bytes
## are bounded.
##
## Runs on PluginArchive's worker thread; `op.cancelled` is read as data is
## decompressed.

const READ_CHUNK := 1 << 16
const BLOCK := 512
const MAX_RECORD_BYTES := 64 * 1024
const MAX_ENTRIES := 200000
# pax keys that do not change where or what tar writes.
const HARMLESS_PAX_KEYS := ["mtime", "atime", "ctime", "uid", "gid", "uname", "gname", "comment",
	"LIBARCHIVE.creationtime", "LIBARCHIVE.symlinktype"]
const HARMLESS_PAX_PREFIXES := ["SCHILY.xattr.", "LIBARCHIVE.xattr.", "SCHILY.acl."]
const UTF8_HDRCHARSET := "ISO-IR 10646 2000 UTF-8"

var total_bytes := 0      # regular-file data, the expanded size
var entries := 0
var _decompressed := 0    # every byte tar would read, headers and padding included
var _pending := PackedByteArray()
var _skip := 0            # data bytes of the current entry still to discard
var _capture := 0         # bytes of a metadata record still to collect
var _captured := PackedByteArray()
var _capture_type := ""
var _next := {}           # overrides for the next entry: path, linkpath, size
var _zero_blocks := 0
var _symlinks := {}       # lower-cased normalised path -> true, for every symlink so far
var _links := []          # [entry, base dir, raw target] of every symlink, re-checked at the end
var _hard_links := 0
var _error := {}


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
	# Headers and padding on top of the file data, with room for many small files.
	var max_decompressed := max_bytes + MAX_ENTRIES * 2 * BLOCK
	while not src.eof_reached():
		var chunk := src.get_buffer(READ_CHUNK)
		var fed := 0
		while fed < chunk.size():
			var put: Array = gz.put_partial_data(chunk.slice(fed))
			if put[0] != OK:
				return _err("archive_corrupt", {"reason": "not a gzip stream"})
			# Nothing taken and nothing to read: the stream ended with input left
			# (a second gzip member or junk), which tar may still read.
			if put[1] == 0 and gz.get_available_bytes() == 0:
				return _err("archive_corrupt", {"reason": "data after the end of the gzip stream"})
			fed += put[1]
			if not _drain(gz, max_bytes, max_decompressed, op):
				return _error
	gz.finish()
	if not _drain(gz, max_bytes, max_decompressed, op):
		return _error
	if _zero_blocks < 1:
		return _err("archive_corrupt", {"reason": "archive ends before its end-of-archive marker"})
	# A filesystem may reach a symlink by other spellings of its name (short
	# names, Unicode case folding), and tar copies a symlink a hard link names
	# to the hard link's place, where its relative target means something
	# else. So hard links are accepted only in archives with no symlinks.
	if _hard_links > 0 and not _symlinks.is_empty():
		return _err("archive_unsafe", {"reason": "hard links and symlinks in one archive"})
	# A link may name a path that only later became a symlink.
	for link in _links:
		if not _link_ok(link[0], link[1], link[2]):
			return _err("archive_unsafe", {"entry": link[0], "reason": "link leaves the archive: " + link[2]})
	return {"ok": true}


## Pull decompressed data through the parser. Returns false with _error set.
func _drain(gz: StreamPeerGZIP, max_bytes: int, max_decompressed: int, op) -> bool:
	while gz.get_available_bytes() > 0:
		if op.cancelled:
			return _fail("cancelled", {})
		var got: Array = gz.get_partial_data(mini(gz.get_available_bytes(), READ_CHUNK))
		if got[0] != OK:
			return _fail("archive_corrupt", {"reason": "gzip data is damaged"})
		_decompressed += got[1].size()
		if _decompressed > max_decompressed:
			return _fail("archive_too_large", {"reason": "the archive decompresses to too much data", "limit": max_bytes})
		_pending.append_array(got[1])
		if not _consume(max_bytes):
			return false
	return true


## Walk whole 512-byte blocks of `_pending`, keeping any partial block.
func _consume(max_bytes: int) -> bool:
	var at := 0
	while at + BLOCK <= _pending.size() or (_skip > 0 and at < _pending.size()):
		if _skip > 0:
			var n := mini(_skip, _pending.size() - at)
			if _capture > 0:
				var take := mini(n, _capture)
				_captured.append_array(_pending.slice(at, at + take))
				_capture -= take
				if _capture == 0 and not _apply_record():
					return false
			_skip -= n
			at += n
			continue
		var header := _pending.slice(at, at + BLOCK)
		at += BLOCK
		if _zero_blocks > 0 or header.count(0) == BLOCK:
			_zero_blocks += 1
			continue
		if not _header(header, max_bytes):
			return false
	_pending = _pending.slice(at)
	return true


func _header(h: PackedByteArray, max_bytes: int) -> bool:
	# The checksum field counts as spaces in its own sum; like tar, accept the
	# sum of the bytes read as unsigned or as signed.
	var unsigned_sum := 8 * 0x20
	var signed_sum := 8 * 0x20
	for i in BLOCK:
		if i < 148 or i >= 156:
			unsigned_sum += h[i]
			signed_sum += h[i] - 256 if h[i] >= 128 else h[i]
	var recorded := _octal(h.slice(148, 156))
	if recorded != unsigned_sum and recorded != signed_sum:
		return _fail("archive_corrupt", {"reason": "a tar header's checksum is wrong"})
	var type := char(h[156]) if h[156] != 0 else "0"
	if h[124] & 0x80:
		return _fail("archive_too_large", {"reason": "an entry is larger than 8 GiB", "limit": max_bytes})
	var size := _octal(h.slice(124, 136))
	if size < 0:
		return _fail("archive_corrupt", {"reason": "a tar header's size is not an octal number"})
	var name := _cstr(h.slice(0, 100))
	# POSIX ustar ("ustar\0") has a name prefix; old GNU ("ustar  ") reuses
	# those bytes for times.
	if _cstr(h.slice(257, 263)) == "ustar" and h[262] == 0:
		var prefix := _cstr(h.slice(345, 500))
		if not prefix.is_empty():
			name = prefix + "/" + name
	var link := _cstr(h.slice(157, 257))
	entries += 1
	if entries > MAX_ENTRIES:
		return _fail("archive_too_large", {"reason": "more than %d entries" % MAX_ENTRIES, "limit": max_bytes})
	if type in ["x", "g", "L", "K"]:
		if size > MAX_RECORD_BYTES:
			return _fail("archive_unsafe", {"entry": name, "reason": "a metadata record larger than %d bytes" % MAX_RECORD_BYTES})
		_skip = _padded(size)
		_capture = size
		_captured = PackedByteArray()
		_capture_type = type
		return true
	name = _next.get("path", name)
	link = _next.get("linkpath", link)
	size = _next.get("size", size)
	_next = {}
	# tar skips a header's data whatever its type; data on a non-file entry
	# could hide headers from this scan.
	if not type in ["0", "7"] and size > 0:
		return _fail("archive_unsafe", {"entry": name, "reason": "a non-file entry carries data"})
	# Godot decodes names as UTF-8, marking bytes it cannot decode with
	# U+FFFD; tar uses the raw bytes, so such a name could differ between them.
	if name.contains("\uFFFD") or link.contains("\uFFFD"):
		return _fail("archive_unsafe", {"entry": name, "reason": "a name that is not valid UTF-8"})
	# Windows tar reads a backslash as a separator, other tars as a plain character.
	if name.contains("\\") or link.contains("\\"):
		return _fail("archive_unsafe", {"entry": name, "reason": "a backslash in a name"})
	# Judged on the raw name, before normalising could hide a leading "/".
	if _raw_unsafe(name):
		return _fail("archive_unsafe", {"entry": name, "reason": "an absolute name or one containing \":\""})
	var path := _member(name)
	if path == PARENT:
		return _fail("archive_unsafe", {"entry": name, "reason": "a \"..\" component in a member name"})
	if path.is_empty():
		if type == "5":
			return true  # the archive root itself
		return _fail("archive_unsafe", {"entry": name, "reason": "an entry replaces the archive root"})
	if _under_symlink(path):
		return _fail("archive_unsafe", {"entry": name, "reason": "written through or over a symlink"})
	match type:
		"0", "7":
			# bsdtar reads a file named "x/" as a directory and its data as headers.
			if name.ends_with("/"):
				return _fail("archive_unsafe", {"entry": name, "reason": "a file named as a directory"})
			total_bytes += size
			if total_bytes > max_bytes:
				return _fail("archive_too_large", {"bytes": total_bytes, "limit": max_bytes})
			_skip = _padded(size)
		"5":
			pass
		"2":
			# macOS and Windows filesystems ignore case (and macOS normalises
			# Unicode), so symlinks are compared case-folded and must be ASCII.
			if not (_ascii(path) and _ascii(link)):
				return _fail("archive_unsafe", {"entry": name, "reason": "non-ASCII symlink name or target"})
			if not _link_ok(path, path.get_base_dir(), link):
				return _fail("archive_unsafe", {"entry": name, "reason": "symlink leaves the archive: " + link})
			_symlinks[path.to_lower()] = true
			_links.append([path, path.get_base_dir(), link])
		"1":
			# Hard link targets name members, which never contain "..".
			if _member(link) == PARENT or not _link_ok(path, "", link):
				return _fail("archive_unsafe", {"entry": name, "reason": "hard link leaves the archive: " + link})
			_hard_links += 1
		_:
			return _fail("archive_unsafe", {"entry": name, "reason": "unsupported entry type '%s'" % type})
	return true


## Apply a finished metadata record to the next entry (or, for a global pax
## record, check it changes nothing that matters). False with _error set.
func _apply_record() -> bool:
	match _capture_type:
		"L", "K":
			return _override("path" if _capture_type == "L" else "linkpath", _cstr(_captured))
	# pax: "<length> <key>=<value>\n", where <length> counts the whole record
	# in bytes; values may themselves contain newlines.
	var at := 0
	while at < _captured.size():
		var space := _captured.find(0x20, at)
		if space < 0:
			return _fail("archive_unsafe", {"reason": "malformed pax record"})
		var length_text := _captured.slice(at, space).get_string_from_ascii()
		if not _decimal(length_text) or int(length_text) <= space - at or at + int(length_text) > _captured.size():
			return _fail("archive_unsafe", {"reason": "malformed pax record"})
		var record := _captured.slice(space + 1, at + int(length_text))
		at += int(length_text)
		if record.is_empty() or record[record.size() - 1] != 0x0A:
			return _fail("archive_unsafe", {"reason": "malformed pax record"})
		var eq := record.find(0x3D)
		if eq <= 0:
			return _fail("archive_unsafe", {"reason": "malformed pax record"})
		var key := record.slice(0, eq).get_string_from_utf8()
		var value := record.slice(eq + 1, record.size() - 1).get_string_from_utf8()
		if key in ["path", "linkpath", "size"] and _capture_type == "x":
			if key == "size" and not _decimal(value):
				return _fail("archive_unsafe", {"reason": "pax size is not a non-negative number"})
			if not _override(key, int(value) if key == "size" else value):
				return false
		elif key == "hdrcharset" and value == UTF8_HDRCHARSET:
			pass
		elif not (key in HARMLESS_PAX_KEYS or HARMLESS_PAX_PREFIXES.any(func(p: String) -> bool: return key.begins_with(p))):
			return _fail("archive_unsafe", {"reason": "unsupported pax key '%s'%s" % [key, " in a global record" if _capture_type == "g" else ""]})
	return true


## A link at `path` to `target`, read from directory `base`, is safe when
## the target resolves inside the archive to something other than the root or
## the link itself (see _resolve).
func _link_ok(path: String, base: String, target: String) -> bool:
	var resolved := "" if _raw_unsafe(target) else _resolve(base, target)
	return not resolved.is_empty() and resolved != path


## Whether `path` is, or lies below, a symlink declared so far.
func _under_symlink(path: String) -> bool:
	var parts := path.split("/")
	for i in range(1, parts.size() + 1):
		if _symlinks.has("/".join(parts.slice(0, i)).to_lower()):
			return true
	return false


## Marks a name with a ".." component (see _member).
const PARENT := ".."


## The one spelling this scan compares member paths in: "./a//b/./c/" ->
## "a/b/c", "" for the root, and PARENT for any name with a ".." component.
## Member names never need "..", and allowing it would give one file several
## spellings, so a symlink prefix check could be dodged.
static func _member(path: String) -> String:
	var parts := PackedStringArray()
	for part in path.replace("\\", "/").split("/", false):
		if part == "..":
			return PARENT
		if part != ".":
			parts.append(part)
	return "/".join(parts)


## A link `target` as seen from directory `base` (in _member form), resolved
## to _member form: "" when it climbs above the archive root or passes through
## a symlink declared so far, since the OS would follow that symlink and this
## scan cannot tell where to.
func _resolve(base: String, target: String) -> String:
	var parts := []
	for part in Array(base.split("/", false)) + Array(target.split("/", false)):
		if not parts.is_empty() and _symlinks.has("/".join(parts).to_lower()):
			return ""
		if part == "..":
			if parts.is_empty():
				return ""
			parts.pop_back()
		elif part != ".":
			parts.append(part)
	return "/".join(parts)


static func _ascii(text: String) -> bool:
	return text.to_utf8_buffer().size() == text.length()


## Absolute ("/x", "\\x"), UNC, or containing ":" (a Windows drive or an
## alternate data stream, so any colon), judged unnormalised.
static func _raw_unsafe(path: String) -> bool:
	return path.begins_with("/") or path.begins_with("\\") or path.contains(":")


## A relative path with no "..": used for SHA256SUMS entries and the
## entrypoint, which must name files inside the extracted plugin.
static func _contained(path: String) -> bool:
	return not _raw_unsafe(path) and _member(path) != PARENT


## Set an override for the next entry. Refused when one is already set: GNU
## tar and bsdtar may not agree on which of two names wins.
func _override(key: String, value) -> bool:
	if _next.has(key):
		return _fail("archive_unsafe", {"reason": "the next entry's %s is set twice" % key})
	# bsdtar ignores an empty path or linkpath and keeps the header's.
	if value is String and value.is_empty():
		return _fail("archive_unsafe", {"reason": "the next entry's %s is empty" % key})
	_next[key] = value
	return true


## A tar numeric field: optional leading spaces, octal digits, then only NULs
## or spaces. -1 for anything else, which tar implementations read
## differently from each other.
static func _octal(field: PackedByteArray) -> int:
	var i := 0
	while i < field.size() and field[i] == 0x20:
		i += 1
	var start := i
	var value := 0
	while i < field.size() and field[i] >= 0x30 and field[i] <= 0x37:
		value = value * 8 + (field[i] - 0x30)
		i += 1
	if i == start:
		return -1
	for rest in field.slice(i):
		if rest != 0 and rest != 0x20:
			return -1
	return value


## Plain decimal digits, no sign, short enough not to overflow.
static func _decimal(text: String) -> bool:
	return not text.is_empty() and text.length() <= 18 and text.lstrip("0123456789").is_empty()


static func _cstr(field: PackedByteArray) -> String:
	var end := field.find(0)
	return (field if end < 0 else field.slice(0, end)).get_string_from_utf8()


static func _padded(size: int) -> int:
	return (size + BLOCK - 1) / BLOCK * BLOCK


func _fail(code: String, detail: Dictionary) -> bool:
	_error = _err(code, detail)
	return false


static func _err(code: String, detail: Dictionary) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}
