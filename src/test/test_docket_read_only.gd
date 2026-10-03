extends SceneTree
## Full MCP envelope + direct UI/core edits against real future-format files.
# Load autoload-dependent scripts after the first frame, as in the integration suite.
const MANAGER := "res://Scripts/Services/Docket/DocketManager.gd"
const MCP_MODULE := "res://Scripts/Services/MCP/Modules/MCPDocketTools.gd"
const PANEL := "res://Scripts/UI/Controls/Docket/app_shell_base.gd"
var _failed := 0
var _dir: String

func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func check(label: String, ok: bool) -> void:
	print("PASS: " + label if ok else "FAIL: " + label)
	if not ok:
		_failed += 1

func _run() -> void:
	_dir = OS.get_cache_dir().path_join("docket_read_only_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_dir)
	var singleton: Node = root.get_node("SingletonObject")
	var old_manager: Node = singleton.docket_manager
	var module: RefCounted = load(MCP_MODULE).new()
	for case in ["2.0.0", "3.0.0", "unknown_type", "1.0.0"]:
		var path := _dir.path_join(case + ".dct")
		var version: String = case if case != "unknown_type" else "1.0.0"
		var text := JSON.stringify({"_type":"meta", "version":version, "counter":0, "id_prefix":"TST", "project":"guard"}) + "\n"
		text += JSON.stringify({"_type":"item", "id":"TST-0001", "type":"chore", "status":"open", "title":"Original", "created_at":"2026-10-03", "updated_at":"2026-10-03"}) + "\n"
		if case == "unknown_type":
			text += '{"_type":"future_record","payload":"must survive"}\n'
		var original := text.to_utf8_buffer()
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(original)
		f.close()
		var dm: Node = load(MANAGER).new()
		dm._load_schema()
		check(case + " opens", not dm.open_project(path).has("error"))
		var db: DocketDB = dm.get_db("guard")
		dm._master_db = db
		dm._init_tool_registry()
		singleton.docket_manager = dm
		check(case + " known item readable via MCP", not (await module.handle("minerva_docket_get", {"id":"TST-0001", "project":"guard"})).has("error"))
		var result: Dictionary = await module.handle("minerva_docket_update", {"id":"TST-0001", "project":"guard", "title":"Edited"})
		if case == "1.0.0":
			check("1.0 accepts MCP edit", not result.has("error"))
			check("1.0 saves normally", dm.save_all().is_empty() and FileAccess.get_file_as_string(path).contains("Edited"))
		else:
			var reason: String = version if case != "unknown_type" else "future_record"
			check(case + " precise MCP refusal", result.has("error") and JSON.stringify(result).contains(reason))
			check(case + " rejects before cache changes", not db.dirty and db.get_item("TST-0001").title == "Original")
			# Every mutation family goes through the shared dispatch precheck.
			for tool in ["create", "transition", "delete", "link", "hint_set", "attach", "detach", "comment", "quality", "secret_set", "secret_delete", "persist"]:
				var refused: Dictionary = dm.call_tool("docket_" + tool, {"project":"guard", "id":"TST-0001"})
				check(case + " refuses " + tool, str(refused.get("error", "")).contains(reason))
			for action in [["saved_query", "save"], ["project_meta", "set"]]:
				check(case + " refuses " + action[0], dm.call_tool("docket_" + action[0], {"project":"guard", "action":action[1]}).has("error"))
			for tool in ["move", "mirror"]:
				check(case + " refuses " + tool, dm.call_tool("docket_" + tool, {"id":"TST-0001", "target_project":"guard"}).has("error"))
			# Use the actual existing status surface without constructing a whole UI.
			var panel: Control = load(PANEL).new()
			panel._dm = dm
			panel._file_label = Label.new()
			panel.add_child(panel._file_label)
			panel._update_file_label()
			check(case + " read-only state visible", panel._file_label.text.contains("read-only") and panel._file_label.tooltip_text.contains(reason))
			db.update_item_fields("TST-0001", {"title":"UI attempt"})
			check(case + " UI edit refusal visible", panel._file_label.text.contains("Read-only") and panel._file_label.tooltip_text.contains(reason) and db.get_item("TST-0001").title == "Original")
			check(case + " raw BLOB path also refuses", db.attach_file("TST-0001", "x", "blob".to_utf8_buffer()).has("error") and db.list_attachments("TST-0001").is_empty())
			panel.free()
			check(case + " untouched save is quiet", dm.save_all().is_empty())
			check(case + " bytes after attempts", FileAccess.get_file_as_bytes(path) == original)
		dm.close_all()
		if case != "1.0.0":
			check(case + " bytes after close", FileAccess.get_file_as_bytes(path) == original)
		dm.free()
		if case != "1.0.0":
			var wrapper := DocketDBJsonl.open_jsonl(path)
			check(case + " write-through DB rejects before mutation", not wrapper.insert_item("NEW-1", {"title":"Lost"}).is_empty() and not wrapper.has_item("NEW-1"))
			wrapper.close()
			check(case + " wrapper preserves bytes", FileAccess.get_file_as_bytes(path) == original)
	singleton.docket_manager = old_manager
	for filename in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(filename))
	DirAccess.remove_absolute(_dir)
	print("ALL TESTS PASSED" if _failed == 0 else "SOME TESTS FAILED")
	quit(0 if _failed == 0 else 1)
