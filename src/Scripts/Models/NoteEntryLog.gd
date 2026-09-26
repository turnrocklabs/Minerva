class_name NoteEntryLog
extends RefCounted
## Ordered entry log behind a text note's body.
##
## The body a human sees is the entries' texts joined with [constant SEPARATOR].
## Each entry has a stable id, a created_at timestamp (UTC ISO-8601), an author
## and its text. [member revision] increases by one on every change to the body,
## whether it came from [method append] or from a whole-body edit
## ([method set_body]).
##
## A whole-body edit keeps the ids of entries it left untouched: leading and
## trailing entries that still appear verbatim (with their separators) keep
## their ids, and whatever changed between them becomes one new entry.
##
## ON-DISK FORMAT (inside a serialized text note, see Note.serialize):
##   "Content":  the body, exactly as before.
##   "Entries":  [{"id": String, "created_at": String, "author": String,
##                 "length": int}, ...] in order. Lengths are in characters and
##                describe how Content splits into entries; entry text is never
##                stored twice.
##   "Revision": int.
## A note saved without "Entries", or whose index does not describe its Content
## exactly, loads as a single entry holding the whole body; created_at of that
## entry is the time it was first loaded.

const SEPARATOR: String = "\n"

## One entry's identity. Its text lives in the log's body; use
## [method NoteEntryLog.get_entry_texts] to read it.
class Entry:
	var id: String
	var created_at: String
	var author: String
	var length: int

	func _init(p_id: String, p_created_at: String, p_author: String, p_length: int) -> void:
		id = p_id
		created_at = p_created_at
		author = p_author
		length = p_length


var revision: int = 0

var _body: String = ""
var _entries: Array[Entry] = []


func get_body() -> String:
	return _body


func get_entries() -> Array[Entry]:
	return _entries.duplicate()


func get_entry_texts() -> PackedStringArray:
	var texts: = PackedStringArray()
	var offset: = 0
	for e: Entry in _entries:
		texts.append(_body.substr(offset, e.length))
		offset += e.length + SEPARATOR.length()
	return texts


## Appends [param text] as a new entry at the end and returns it.
func append(text: String, author: String) -> Entry:
	var e: = Entry.new(_new_id(), _now(), author, text.length())
	if _entries.is_empty():
		_body = text
	else:
		_body += SEPARATOR + text
	_entries.append(e)
	revision += 1
	return e


## Replaces the whole body. Returns false when [param new_body] equals the
## current body (nothing changes, revision stays). An empty body has no entries.
func set_body(new_body: String, author: String = "") -> bool:
	if new_body == _body:
		return false
	revision += 1
	if new_body.is_empty():
		_entries.clear()
		_body = ""
		return true

	var sep_len: = SEPARATOR.length()
	var new_len: = new_body.length()

	# Leading entries that survive verbatim, each followed by a separator
	# (or ending the new body exactly).
	var head: Array[Entry] = []
	var p: = 0 # read position in new_body
	var o: = 0 # matching position in the old body
	var closed: = false
	while head.size() < _entries.size():
		var e: Entry = _entries[head.size()]
		if new_len - p < e.length or new_body.substr(p, e.length) != _body.substr(o, e.length):
			break
		var after: = p + e.length
		if after == new_len:
			head.append(e)
			p = after
			closed = true
			break
		if new_body.substr(after, sep_len) != SEPARATOR:
			break
		head.append(e)
		p = after + sep_len
		o += e.length + sep_len

	# Trailing entries that survive verbatim, each preceded by a separator
	# (or starting exactly where the head ended).
	var tail: Array[Entry] = []
	var q: = new_len # end of the unmatched region in new_body
	if not closed:
		var oe: = _body.length() # end of entry j in the old body
		var j: = _entries.size() - 1
		while j >= head.size():
			var e: Entry = _entries[j]
			var s: = q - e.length
			if s < p or new_body.substr(s, e.length) != _body.substr(oe - e.length, e.length):
				break
			if s == p:
				tail.push_front(e)
				q = p
				closed = true
				break
			if s - sep_len < p or new_body.substr(s - sep_len, sep_len) != SEPARATOR:
				break
			tail.push_front(e)
			q = s - sep_len
			oe -= e.length + sep_len
			j -= 1

	var rebuilt: Array[Entry] = head
	if not closed:
		rebuilt.append(Entry.new(_new_id(), _now(), author, q - p))
	rebuilt.append_array(tail)
	_entries = rebuilt
	_body = new_body
	return true


## The "Entries" value written to disk (see the header comment).
func to_index() -> Array[Dictionary]:
	var index: Array[Dictionary] = []
	for e: Entry in _entries:
		index.append({"id": e.id, "created_at": e.created_at, "author": e.author, "length": e.length})
	return index


## Re-applies a saved index to the current body. Returns false, leaving the log
## unchanged, when [param index] does not describe the body exactly (missing,
## malformed, duplicate ids, or lengths/separators that do not line up).
func restore(index: Array, saved_revision: int) -> bool:
	var parsed: Array[Entry] = []
	var seen: Dictionary[String, bool] = {}
	for item: Variant in index:
		if not (item is Dictionary):
			return false
		var d: Dictionary = item
		var id: = str(d.get("id", ""))
		var length_v: Variant = d.get("length")
		if id.is_empty() or seen.has(id) or not (length_v is int or length_v is float):
			return false
		var length: = int(length_v)
		if length < 0:
			return false
		seen[id] = true
		parsed.append(Entry.new(id, str(d.get("created_at", "")), str(d.get("author", "")), length))

	var sep_len: = SEPARATOR.length()
	var offset: = 0
	for k: int in parsed.size():
		offset += parsed[k].length
		if k < parsed.size() - 1:
			if _body.substr(offset, sep_len) != SEPARATOR:
				return false
			offset += sep_len
	if offset != _body.length():
		return false

	_entries = parsed
	revision = saved_revision
	return true


static func _new_id() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()


static func _now() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"
