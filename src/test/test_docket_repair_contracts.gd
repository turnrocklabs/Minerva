extends SceneTree
## Real MCP moves and refusal-cache invalidation; executor uses isolated caches.
const MANAGER := "res://Scripts/Services/Docket/DocketManager.gd"
const MCP_MODULE := "res://Scripts/Services/MCP/Modules/MCPDocketTools.gd"
const UUID := "019d5c00000000000000000000000001"
var _failed := 0
var _dir: String

func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func check(label: String, ok: bool) -> void:
	print("PASS: " + label if ok else "FAIL: " + label)
	if not ok:
		_failed += 1

func write_project(name: String, id: String = "", version: String = "1.0.0") -> String:
	var path := _dir.path_join(name + ".dct")
	var text := JSON.stringify({"_type":"meta", "version":version, "counter":0, "id_prefix":"TST", "project":name}) + "\n"
	if not id.is_empty():
		text += JSON.stringify({"_type":"item", "id":id, "type":"chore", "status":"open", "title":"Keep me", "description":"literal\\n", "created_at":"2026-10-03", "updated_at":"2026-10-03"}) + "\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return path

func _run() -> void:
	_dir = OS.get_cache_dir().path_join("docket_repairs_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_dir)
	var singleton: Node = root.get_node("SingletonObject")
	var prior: Node = singleton.docket_manager
	var module: RefCounted = load(MCP_MODULE).new()
	# A legacy move must not be blocked by an unrelated future-format project.
	var source := write_project("source", "OLD-0001")
	var target := write_project("target")
	var future := write_project("future", "FUT-0001", "3.0.0")
	var future_bytes := FileAccess.get_file_as_bytes(future)
	var dm: Node = load(MANAGER).new()
	dm._load_schema()
	for path in [source, target, future]:
		check("project opens: " + path.get_file(), not dm.open_project(path).has("error"))
	dm._master_db = dm.get_db("source")
	dm._init_tool_registry()
	singleton.docket_manager = dm
	var result: Dictionary = await module.handle("minerva_docket_move", {"id":"OLD-0001", "target_project":"target"})
	check("legacy move ignores unrelated read-only project", not result.has("error"))
	check("successful import precedes source deletion", not dm.get_db("source").has_item("OLD-0001") and dm.get_db("target").has_item(str(result.get("new_id", ""))))
	check("move retains stored literal text", dm.get_db("target").get_item(str(result.get("new_id", ""))).get("description") == "literal\\n")
	check("move saves without unrelated refusal", dm.close_all().is_empty())
	check("unrelated complete canonical file unchanged", FileAccess.get_file_as_bytes(future) == future_bytes)
	dm.free()
	# A genuine SQL import failure (duplicate UUID) must keep the source intact.
	source = write_project("source", UUID)
	target = write_project("target", UUID)
	var source_bytes := FileAccess.get_file_as_bytes(source)
	var target_bytes := FileAccess.get_file_as_bytes(target)
	dm = load(MANAGER).new()
	dm._load_schema()
	dm.open_project(source)
	dm.open_project(target)
	dm._master_db = dm.get_db("source")
	dm._init_tool_registry()
	singleton.docket_manager = dm
	result = await module.handle("minerva_docket_move", {"id":UUID, "target_project":"target"})
	check("failed import reports MCP error", result.has("error") and JSON.stringify(result).contains("import failed"))
	check("failed import preserves source item", dm.get_db("source").has_item(UUID))
	check("failed import rolls back destination", not dm.get_db("target").dirty and dm.get_db("target").get_events(UUID).is_empty())
	dm.close_all()
	check("failed move preserves full source bytes", FileAccess.get_file_as_bytes(source) == source_bytes)
	check("failed move preserves full target bytes", FileAccess.get_file_as_bytes(target) == target_bytes)
	dm.free()
	# Same stamp reuses the decision; a size change triggers the authoritative guard.
	var path := write_project("cache", "CACHE-1")
	var db := JSONLCache.open_or_rebuild(path)
	check("initial refusal cache grants known writable file", db.mutation_refusal().is_empty() and not db._refusal_stamp.is_empty())
	var stamp := db._refusal_stamp
	check("unchanged file reuses stamp", db.mutation_refusal().is_empty() and db._refusal_stamp == stamp)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_string('{"_type":"future_record","payload":"keep"}\n')
	file.close()
	var changed_bytes := FileAccess.get_file_as_bytes(path)
	db.update_item_fields("CACHE-1", {"title":"Must be refused"})
	check("external change refuses before changing cache", not db.dirty and db.get_item("CACHE-1").title == "Keep me" and db.write_error.contains("changed on disk"))
	check("refused edit preserves full externally changed file", FileAccess.get_file_as_bytes(path) == changed_bytes)
	db.close()
	singleton.docket_manager = prior
	for filename in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(filename))
	DirAccess.remove_absolute(_dir)
	print("ALL TESTS PASSED" if _failed == 0 else "SOME TESTS FAILED")
	quit(0 if _failed == 0 else 1)
