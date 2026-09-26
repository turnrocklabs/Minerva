extends SceneTree
## Round-trip test for a text note's entry log (NoteEntryLog behind
## NoteTextControls), driven through the same Note.serialize / JSON /
## Note.deserialize path a project save and load uses.
##
## ORACLE: the entry ids captured right after the three appends, before any
## save. After a JSON round-trip the reloaded note must report exactly those
## ids, in the same order, with the same texts, body and revision. Ids are
## random per entry, so a store that regenerates ids on load (or drops the
## index and falls back to one entry) cannot reproduce them and fails.
## The same test also checks that a note saved before entries existed loads
## as one entry with identical text, and that a whole-body edit bumps the
## revision while untouched entries keep their ids.
##
## Run:
##   godot --headless --path ~/github/Minerva/src --script test/test_note_entry_log.gd

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	print("=== note entry log round trip ===\n")
	await test_entries_survive_save_and_reload()
	await test_mcp_append_read_since_and_if_revision()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s" % description)


func _ids(entry_log: NoteEntryLog) -> PackedStringArray:
	var ids: = PackedStringArray()
	for e: NoteEntryLog.Entry in entry_log.get_entries():
		ids.append(e.id)
	return ids


func _add(note: Note) -> Note:
	root.add_child(note)
	await process_frame
	return note


func _reload(note: Note) -> Note:
	var parsed: Variant = JSON.parse_string(JSON.stringify(note.serialize()))
	return await _add(Note.deserialize(parsed as Dictionary, false))


func test_entries_survive_save_and_reload() -> void:
	print("test_entries_survive_save_and_reload:")

	# A note saved before entry logs existed: no Entries / Revision keys.
	var legacy_body: = "line one\nline two"
	var legacy_dict: = {"Title": "legacy", "UUID": "entry-log-test-uuid", "ContentType": "text", "Content": legacy_body}
	var note: Note = await _add(Note.deserialize(legacy_dict, false))
	var controls: = note.get_controls_container() as NoteTextControls
	_check("legacy note shows identical text", controls.content == legacy_body)
	_check("legacy note loads as one entry", controls.entry_log.get_entries().size() == 1)

	controls.append_entry("first", "agent-a")
	controls.append_entry("second\nspans two lines", "agent-b")
	controls.append_entry("third", "agent-a")
	var ids_before: = _ids(controls.entry_log)
	var texts_before: = controls.entry_log.get_entry_texts()
	var revision_before: = controls.entry_log.revision
	_check("four distinct ids", ids_before.size() == 4 and Array(ids_before).all(func(i: String) -> bool: return ids_before.count(i) == 1))
	_check("texts in append order", texts_before == PackedStringArray([legacy_body, "first", "second\nspans two lines", "third"]))
	_check("body is the entries joined", controls.content == "\n".join(texts_before))

	var reloaded: Note = await _reload(note)
	var reloaded_controls: = reloaded.get_controls_container() as NoteTextControls
	_check("ids and order survive save + reload", _ids(reloaded_controls.entry_log) == ids_before)
	_check("texts survive save + reload", reloaded_controls.entry_log.get_entry_texts() == texts_before)
	_check("body survives save + reload", reloaded_controls.content == controls.content)
	_check("revision survives save + reload", reloaded_controls.entry_log.revision == revision_before)
	_check("authors survive save + reload", reloaded_controls.entry_log.get_entries()[2].author == "agent-b")

	# A human edit of the body, as the notes-tab editor writes it.
	reloaded_controls.content = reloaded_controls.content.replace("second\nspans two lines", "edited")
	var ids_after: = _ids(reloaded_controls.entry_log)
	_check("body edit bumps the revision", reloaded_controls.entry_log.revision == revision_before + 1)
	_check("untouched entries keep their ids",
		ids_after.size() == 4 and ids_after[0] == ids_before[0] and ids_after[1] == ids_before[1]
		and ids_after[3] == ids_before[3] and ids_after[2] != ids_before[2])

	note.queue_free()
	reloaded.queue_free()


## MCP verbs over one note, called through the tool modules' handle() as the
## MCP server dispatches them (errors are {"error": ...}, which the wire turns
## into isError:true).
##
## ORACLE: the entry_ids the append calls returned, captured in call order.
## Two appenders interleave five appends each (one retried with the same
## request_id); the note must then hold the seed entry plus exactly those ten
## ids, all distinct. Three read_since pages (limit 4) must concatenate to that
## same id list with no gap or overlap. A stale if_revision must leave the
## serialized note byte-identical. Editing an entry the reader has already seen
## must make the next read reset, and re-reading from "" must return the edited
## log.
func test_mcp_append_read_since_and_if_revision() -> void:
	print("test_mcp_append_read_since_and_if_revision:")
	var entry_tools: = MCPNoteEntryTools.new(null)
	var notes_tools: = MCPNotesTools.new(null)
	var note: Note = await _add(Note.create_text_note("mcp verbs", "seed"))
	var id: = note.uuid
	var controls: = note.get_controls_container() as NoteTextControls

	var returned: = PackedStringArray()
	for i: int in 5:
		for who: String in ["a", "b"]:
			var args: = {"note_id": id, "text": "%s-%d" % [who, i], "request_id": "%s-%d" % [who, i], "author": who}
			var res: Dictionary = entry_tools.handle("minerva_append_note", args)
			returned.append(str(res.get("entry_id", "")))
			if who == "a" and i == 2:
				var retry: Dictionary = entry_tools.handle("minerva_append_note", args)
				_check("retry returns the same entry_id", retry.get("entry_id") == res.get("entry_id"))
				_check("retry reports deduplicated", retry.get("deduplicated") == true and retry.get("revision") == res.get("revision"))
	var ids: = _ids(controls.entry_log)
	_check("seed + 2N entries, retry added none", ids.size() == 11)
	_check("log holds exactly the returned ids in order", ids.slice(1) == returned)
	_check("all ids distinct", Array(ids).all(func(i: String) -> bool: return ids.count(i) == 1))

	var paged: = PackedStringArray()
	var cursor: = ""
	var sizes: Array[int] = []
	for page: int in 3:
		var res: Dictionary = entry_tools.handle("minerva_read_note_since", {"note_id": id, "cursor": cursor, "limit": 4})
		_check("page %d is not a reset" % page, res.get("reset") == false)
		for e: Dictionary in res.get("entries", []):
			paged.append(str(e["id"]))
		sizes.append((res.get("entries", []) as Array).size())
		cursor = str(res.get("next_cursor", ""))
	_check("three pages of 4, 4, 3", sizes == [4, 4, 3])
	_check("pages concatenate to the log with no gap or overlap", paged == ids)
	var tail_read: Dictionary = entry_tools.handle("minerva_read_note_since", {"note_id": id, "cursor": cursor, "limit": 4})
	_check("read at the end returns nothing and keeps the cursor",
		(tail_read.get("entries", []) as Array).is_empty() and tail_read.get("next_cursor") == cursor and tail_read.get("reset") == false)

	var stale_revision: = controls.entry_log.revision
	entry_tools.handle("minerva_append_note", {"note_id": id, "text": "late", "request_id": "c-0"})
	var before: = JSON.stringify(note.serialize())
	var stale: Dictionary = notes_tools.handle("minerva_update_note",
		{"note_id": id, "content": "overwrite", "title": "overwrite", "if_revision": stale_revision})
	_check("stale if_revision is an error", stale.has("error") and stale.get("success") == false)
	_check("stale if_revision leaves the note byte-identical", JSON.stringify(note.serialize()) == before)
	var fresh: Dictionary = notes_tools.handle("minerva_update_note",
		{"note_id": id, "content": controls.content.replace("a-1", "a-1 edited"), "if_revision": controls.entry_log.revision})
	_check("current if_revision applies", fresh.get("success") == true and controls.content.contains("a-1 edited"))

	var reset: Dictionary = entry_tools.handle("minerva_read_note_since", {"note_id": id, "cursor": cursor})
	_check("read after an edit of seen entries resets", reset.get("reset") == true and not str(reset.get("reset_reason", "")).is_empty())
	_check("reset returns no entries and cursor \"\"", (reset.get("entries", []) as Array).is_empty() and reset.get("next_cursor") == "")
	var recovered: Dictionary = entry_tools.handle("minerva_read_note_since", {"note_id": id, "cursor": ""})
	var texts: = PackedStringArray()
	for e: Dictionary in recovered.get("entries", []):
		texts.append(str(e["text"]))
	_check("re-read from \"\" returns the edited log", "\n".join(texts) == controls.content and texts.has("a-1 edited"))

	note.queue_free()
