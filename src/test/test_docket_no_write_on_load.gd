extends SceneTree
## Real-file load/save/close oracle. Executor must use isolated user/cache dirs.

const MANAGER := "res://Scripts/Services/Docket/DocketManager.gd"
const FIXTURE := "res://test/fixtures/master_verbatim.jsonl"
const MASTER_HASH := "07c0b10058c98388889d246aa1f82270eef56bef5e304dcb4a806f26377c3431"
const ITEM := "019d5c00000000000000000000000003"
var _dir: String
var _failed := 0

func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func check(label: String, ok: bool) -> void:
	print("PASS: " + label if ok else "FAIL: " + label)
	if not ok:
		_failed += 1

func write_file(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

func _run() -> void:
	_dir = OS.get_cache_dir().path_join("docket_no_write_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_dir)
	var original := FileAccess.get_file_as_bytes(FIXTURE)
	check("fixture is the frozen shipped master", FileAccess.get_sha256(FIXTURE) == MASTER_HASH)
	var master := _dir.path_join("master.dct")
	var personal := _dir.path_join("personal.dct")
	var nameless := _dir.path_join("nameless.dct")
	var named := _dir.path_join("different_filename.dct")
	write_file(master, original)
	var sample := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"DKT","project":"stored-name"}\n' + JSON.stringify({"_type":"item", "id":"KEEP-1", "type":"chore", "status":"open", "title":"Original", "description":"literal\\n\\t", "created_at":"2026-10-03", "updated_at":"2026-10-03"}) + "\n"
	var personal_bytes := sample.to_utf8_buffer()
	var nameless_bytes := sample.replace(',"project":"stored-name"', '').replace('"id_prefix":"DKT"', '"id_prefix":""').to_utf8_buffer()
	write_file(personal, personal_bytes)
	write_file(nameless, nameless_bytes)
	write_file(named, personal_bytes)
	# Force an actual cache dedupe while requiring the source to stay untouched.
	var event := '{"_type":"event","item_id":"KEEP-1","seq":1,"event_type":"created","timestamp":"2026-10-03","note":"same"}\n'
	var duplicate_path := _dir.path_join("duplicate.dct")
	var duplicate_bytes := (sample.replace('stored-name', 'duplicate') + event + event).to_utf8_buffer()
	write_file(duplicate_path, duplicate_bytes)
	for cycle in 2: # Rebuild, then reuse fresh caches.
		var dm: Node = load(MANAGER).new()
		dm._init_master(master, FIXTURE, _dir.path_join("shipped_hash"))
		dm._init_personal(personal)
		check("nameless opens", not dm.open_project(nameless).has("error"))
		check("named project opens with stored name", dm.open_project(named).get("project") == "stored-name")
		dm.open_project(duplicate_path)
		var db: DocketDB = dm.get_db("master")
		check("stored master text is verbatim", str(db.get_item(ITEM).get("steps", "")).contains("\\n"))
		for name in dm.get_loaded_projects():
			check("load leaves %s clean (cycle %d)" % [name, cycle], not dm.get_db(name).dirty)
		dm._merge_shipped_master(FIXTURE, _dir.path_join("force_merge_%d" % cycle))
		check("no-op merge does not dirty master", not db.dirty)
		check("save_all has no refusal", dm.save_all().is_empty())
		check("close_all has no refusal", dm.close_all().is_empty())
		dm.free()
		for pair in [[master, original], [personal, personal_bytes], [nameless, nameless_bytes], [named, personal_bytes], [duplicate_path, duplicate_bytes]]:
			check("untouched bytes: " + str(pair[0]).get_file(), FileAccess.get_file_as_bytes(pair[0]) == pair[1])
	var edit: Node = load(MANAGER).new()
	edit._init_personal(personal)
	edit.open_project(nameless)
	var personal_db: DocketDB = edit.get_db("personal")
	personal_db.update_item_fields("KEEP-1", {"title":"Input\\nnormalized\\t"})
	edit.get_db("nameless").update_item_fields("KEEP-1", {"title":"Saved"})
	check("real edit saves", edit.close_all().is_empty())
	edit.free()
	var saved := JSONLParser.parse_file(personal)
	check("session personal name stays out of canonical metadata", saved.meta.get("project") == "stored-name")
	check("stored DKT prefix is preserved", saved.meta.get("id_prefix") == "DKT")
	check("canonical text survives a later real edit", saved.items[0].description == "literal\\n\\t")
	check("ordinary input still normalizes", saved.items[0].title == "Input\nnormalized\t")
	var missing: Dictionary = JSONLParser.parse_file(nameless).meta
	check("missing name/prefix materialize only on real edit", missing.get("project") == "nameless" and missing.get("id_prefix") == DocketDB._derive_prefix("nameless"))
	# A missing shipped record really merges and persists; its canonical text survives.
	write_file(master, '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"MST","project":"master"}\n'.to_utf8_buffer())
	var merge: Node = load(MANAGER).new()
	merge._init_master(master, FIXTURE, _dir.path_join("missing_merge_hash"))
	check("missing shipped item persists", JSONLParser.parse_file(master).items.size() == JSONLParser.parse_file(FIXTURE).items.size())
	merge.close_all()
	merge.free()
	for filename in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(filename))
	DirAccess.remove_absolute(_dir)
	print("ALL TESTS PASSED" if _failed == 0 else "SOME TESTS FAILED")
	quit(0 if _failed == 0 else 1)
