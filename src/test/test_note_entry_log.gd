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
