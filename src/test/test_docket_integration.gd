extends SceneTree
## Integration tests for native docket in Minerva.
## Run: godot --headless --script test/test_docket_integration.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""

func _init():
	print("=== Docket Integration Tests ===\n")

	_tmp_dir = OS.get_cache_dir().path_join("minerva_docket_test_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)

	test_schema_loads()
	test_docket_db_create_and_open()
	test_docket_db_crud()
	test_tool_registry_init()
	test_tool_registry_call()
	test_skill_list_and_get()
	test_hint_set_and_get()
	test_quality_scoring()
	test_state_machine_enforcement()
	test_policy_type_exists()
	test_jsonl_roundtrip()
	test_plugin_skills_metadata_roundtrip()
	test_plugin_skills_jsonl_roundtrip()
	test_plugin_skills_skill_get_lean_view()
	test_plugin_skills_alter_table_migration()
	test_master_dct_exists()

	# Cleanup
	_cleanup_tmp()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % desc)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % desc)


func _cleanup_tmp() -> void:
	if _tmp_dir.is_empty():
		return
	var dir := DirAccess.open(_tmp_dir)
	if dir:
		dir.list_dir_begin()
		var f := dir.get_next()
		while not f.is_empty():
			DirAccess.remove_absolute(_tmp_dir.path_join(f))
			f = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


# -- Tests --------------------------------------------------------------------

func test_schema_loads() -> void:
	var f := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	check("schema.json opens", f != null)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	check("schema parses as Dictionary", parsed is Dictionary)
	check("schema has types", parsed.has("types"))
	check("schema has bug type", parsed.types.has("bug"))
	check("schema has skill type", parsed.types.has("skill"))
	check("schema has policy type", parsed.types.has("policy"))


func test_docket_db_create_and_open() -> void:
	var db_path := _tmp_dir.path_join("test.db")
	var db := DocketDB.create_new(db_path)
	check("DocketDB.create_new returns non-null", db != null)
	check("DocketDB is open", db.is_open())
	check("project name defaults", not db.get_project_name().is_empty())
	db.close()
	check("DocketDB closes cleanly", not db.is_open())

	# Re-open
	var db2 := DocketDB.new()
	check("DocketDB re-opens", db2.open(db_path))
	db2.close()


func test_docket_db_crud() -> void:
	var db_path := _tmp_dir.path_join("crud.db")
	var db := DocketDB.create_new(db_path)

	# Load schema for DataModel
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	# Create item
	var id := db.next_uuid7_id()
	var item := DataModel.create_item(schema, "work_item", {"title": "Test Item", "description": "A test"})
	var err := db.insert_item(id, item)
	check("insert_item succeeds", err.is_empty())

	# Read
	var fetched := db.get_item(id)
	check("get_item returns item", not fetched.is_empty())
	check("title matches", str(fetched.get("title", "")) == "Test Item")

	# Update
	db.update_item_fields(id, {"title": "Updated Title"})
	var updated := db.get_item(id)
	check("update changes title", str(updated.get("title", "")) == "Updated Title")

	# Query
	var results := db.execute_query({"filter": {"type": "work_item"}})
	check("query returns 1 result", results.size() == 1)

	# Delete
	db.delete_item(id)
	check("item deleted", db.get_item(id).is_empty())

	db.close()


func test_tool_registry_init() -> void:
	var db_path := _tmp_dir.path_join("registry.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)
	check("ToolRegistry has docket_create", registry.has_tool("docket_create"))
	check("ToolRegistry has docket_query", registry.has_tool("docket_query"))
	check("ToolRegistry has docket_skill_list", registry.has_tool("docket_skill_list"))
	check("ToolRegistry has docket_quality", registry.has_tool("docket_quality"))

	var tools := registry.list_tools()
	check("list_tools returns 30+ tools", tools.size() >= 30)

	db.close()


func test_tool_registry_call() -> void:
	var db_path := _tmp_dir.path_join("toolcall.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	# Create via tool
	var result := registry.call_tool("docket_create", {"type": "bug", "title": "Test Bug", "severity": 2})
	check("docket_create succeeds", not result.has("error"))
	check("docket_create returns id", result.has("id"))

	# Query via tool
	var q_result := registry.call_tool("docket_query", {})
	check("docket_query succeeds", not q_result.has("error"))
	check("docket_query returns items", q_result.has("items") or q_result.has("count"))

	# Transition
	var item_id: String = str(result.get("id", ""))
	var t_result := registry.call_tool("docket_transition", {"id": item_id, "to": "triaged"})
	check("docket_transition succeeds", not t_result.has("error"))

	db.close()


func test_skill_list_and_get() -> void:
	var db_path := _tmp_dir.path_join("skills.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	# Create a skill
	registry.call_tool("docket_create", {
		"type": "skill", "title": "Test Skill",
		"description": "A test skill", "steps": "Step 1\nStep 2",
	})
	# Activate it
	var q := registry.call_tool("docket_query", {"filter": {"type": "skill"}})
	var items: Array = q.get("items", [])
	if items.size() > 0:
		var skill_id: String = str(items[0].get("id", ""))
		registry.call_tool("docket_transition", {"id": skill_id, "to": "active"})

	# List skills
	var list_result := registry.call_tool("docket_skill_list", {})
	check("skill_list succeeds", not list_result.has("error"))
	check("skill_list has skills", list_result.has("skills"))

	# Get skill by title
	var get_result := registry.call_tool("docket_skill_get", {"title": "Test Skill"})
	check("skill_get succeeds", not get_result.has("error"))
	check("skill_get has steps", get_result.has("steps"))

	db.close()


func test_hint_set_and_get() -> void:
	var db_path := _tmp_dir.path_join("hints.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	# Set a hint
	var set_result := registry.call_tool("docket_hint_set", {
		"component": "test-component",
		"key": "test-key",
		"value": "test-value",
		"tags": ["test"]
	})
	check("hint_set succeeds", not set_result.has("error"))

	# Get the hint
	var get_result := registry.call_tool("docket_hint_get", {
		"component": "test-component",
		"key": "test-key",
	})
	check("hint_get succeeds", not get_result.has("error"))
	check("hint_get returns value", str(get_result.get("value", "")) == "test-value")

	# Query hints
	var q_result := registry.call_tool("docket_hint_query", {"component": "test-component"})
	check("hint_query succeeds", not q_result.has("error"))
	check("hint_query returns items", q_result.has("items") or q_result.has("count"))

	db.close()


func test_quality_scoring() -> void:
	var db_path := _tmp_dir.path_join("quality.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	# Create a hint to score
	var hint_result := registry.call_tool("docket_hint_set", {
		"component": "quality-test", "key": "test", "value": "test-value"
	})
	var hint_id: String = str(hint_result.get("id", ""))
	check("hint created for quality test", not hint_id.is_empty())

	# Score it
	var score_result := registry.call_tool("docket_quality", {
		"id": hint_id, "score": 4, "reason": "Very helpful"
	})
	check("quality scoring succeeds", not score_result.has("error"))
	check("quality score set to 4", int(score_result.get("quality", 0)) == 4)

	db.close()


func test_state_machine_enforcement() -> void:
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	# Valid transition
	var valid := StateMachine.get_valid_transitions(schema, "bug", "new")
	check("bug 'new' can go to 'triaged'", "triaged" in valid)

	# Invalid transition
	check("bug 'new' cannot go to 'closed'", "closed" not in valid)

	# DCR transitions
	var dcr_valid := StateMachine.get_valid_transitions(schema, "dcr", "proposed")
	check("dcr 'proposed' can go to 'approved'", "approved" in dcr_valid)

	# Policy transitions
	var policy_valid := StateMachine.get_valid_transitions(schema, "policy", "draft")
	check("policy 'draft' can go to 'proposed'", "proposed" in policy_valid)
	check("policy 'draft' cannot skip to 'active'", "active" not in policy_valid)


func test_policy_type_exists() -> void:
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	check("policy type in schema", schema.types.has("policy"))
	var policy: Dictionary = schema.types["policy"]
	check("policy has 5 states", policy.states.size() == 5)
	check("policy initial state is draft", policy.initial_state == "draft")
	check("policy has steps in optional_fields", "steps" in policy.optional_fields)


func test_jsonl_roundtrip() -> void:
	# Create a DB, add items, serialize to JSONL, rebuild cache, verify
	var db_path := _tmp_dir.path_join("roundtrip.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	# Add test items
	var id1 := db.next_uuid7_id()
	db.insert_item(id1, DataModel.create_item(schema, "work_item", {"title": "Roundtrip Item 1"}))
	var id2 := db.next_uuid7_id()
	db.insert_item(id2, DataModel.create_item(schema, "hint", {"title": "test/key", "component": "test", "key": "key", "value": "val"}))

	# Serialize
	var jsonl := JSONLSerializer.serialize_all(db)
	check("JSONL serialization non-empty", not jsonl.is_empty())
	check("JSONL contains items", jsonl.contains("\"_type\":\"item\""))

	# Write to file
	var dct_path := _tmp_dir.path_join("roundtrip.dct")
	var f := FileAccess.open(dct_path, FileAccess.WRITE)
	f.store_string(jsonl)
	f.close()
	db.close()

	# Rebuild from JSONL
	var db2 := JSONLCache.open_or_rebuild(dct_path)
	check("JSONL cache rebuilds", db2 != null)
	if db2:
		var item1 := db2.get_item(id1)
		check("roundtrip preserves item 1", not item1.is_empty())
		check("roundtrip preserves title", str(item1.get("title", "")) == "Roundtrip Item 1")
		var item2 := db2.get_item(id2)
		check("roundtrip preserves hint", not item2.is_empty())
		db2.close()


func test_master_dct_exists() -> void:
	check("master.dct exists at res://Data/master.dct", FileAccess.file_exists("res://Data/master.dct"))
	var f := FileAccess.open("res://Data/master.dct", FileAccess.READ)
	check("master.dct opens", f != null)
	if f:
		var first_line := f.get_line()
		f.close()
		var meta = JSON.parse_string(first_line)
		check("master.dct first line is meta", meta is Dictionary and meta.get("_type", "") == "meta")
		check("master.dct project is 'master'", str(meta.get("project", "")) == "master")


# -- Plugin-shipped skills metadata (DCR 019df57b) ----------------------------

func test_plugin_skills_metadata_roundtrip() -> void:
	# SQLite round-trip: create a skill with all 6 new fields populated; fetch
	# back via docket_skill_get + docket_query and verify each field shape.
	var db_path := _tmp_dir.path_join("skill_metadata.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	var pristine := {
		"id": "minerva_demo_make_thing",
		"title": "Make a thing",
		"steps": "1. Read input. 2. Make.",
	}
	var create_result := registry.call_tool("docket_create", {
		"type": "skill",
		"title": "Make a thing",
		"steps": "1. Read input. 2. Make.",
		"source": "plugin:demo",
		"customised": false,
		"pristine_hash": "abc123def456",
		"pristine_content": pristine,
		"unsatisfied_deps": ["minerva_other_dep"],
		"deprecated": false,
	})
	check("skill create with new fields succeeds", not create_result.has("error"))
	var skill_id: String = str(create_result.get("id", ""))

	# Read back via get_item (full record).
	var fetched := db.get_item(skill_id)
	check("source round-trips", str(fetched.get("source", "")) == "plugin:demo")
	check("customised round-trips as bool", fetched.get("customised") == false)
	check("pristine_hash round-trips", str(fetched.get("pristine_hash", "")) == "abc123def456")
	check("pristine_content round-trips as Dictionary",
		fetched.get("pristine_content") is Dictionary
		and (fetched.get("pristine_content") as Dictionary).get("id") == "minerva_demo_make_thing")
	check("unsatisfied_deps round-trips as Array",
		fetched.get("unsatisfied_deps") is Array
		and (fetched.get("unsatisfied_deps") as Array).size() == 1)
	check("deprecated round-trips as bool", fetched.get("deprecated") == false)

	# Toggle the booleans via update; confirm read reflects.
	registry.call_tool("docket_update", {
		"id": skill_id,
		"customised": true,
		"deprecated": true,
		"unsatisfied_deps": [],
	})
	var refetched := db.get_item(skill_id)
	check("customised flipped to true", refetched.get("customised") == true)
	check("deprecated flipped to true", refetched.get("deprecated") == true)
	check("unsatisfied_deps cleared", (refetched.get("unsatisfied_deps") as Array).is_empty())

	db.close()


func test_plugin_skills_jsonl_roundtrip() -> void:
	# Create a skill with all new fields, serialize → JSONL file → rebuild DB
	# from JSONL → confirm fields survive.
	var db_path := _tmp_dir.path_join("skill_jsonl.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	var pristine := {"id": "minerva_demo_make", "title": "Make"}
	var create_result := registry.call_tool("docket_create", {
		"type": "skill",
		"title": "JSONL Skill",
		"steps": "do thing",
		"source": "plugin:demo",
		"customised": true,
		"pristine_hash": "deadbeef",
		"pristine_content": pristine,
		"unsatisfied_deps": ["minerva_demo_missing"],
		"deprecated": true,
	})
	var skill_id: String = str(create_result.get("id", ""))

	var jsonl := JSONLSerializer.serialize_all(db)
	check("JSONL contains source field", jsonl.contains("\"source\":\"plugin:demo\""))
	check("JSONL contains pristine_hash", jsonl.contains("\"pristine_hash\":\"deadbeef\""))
	check("JSONL contains pristine_content as Dictionary", jsonl.contains("\"pristine_content\":"))
	check("JSONL contains customised int", jsonl.contains("\"customised\":1"))
	check("JSONL contains deprecated int", jsonl.contains("\"deprecated\":1"))

	var dct_path := _tmp_dir.path_join("skill_jsonl.dct")
	var f := FileAccess.open(dct_path, FileAccess.WRITE)
	f.store_string(jsonl)
	f.close()
	db.close()

	var db2 := JSONLCache.open_or_rebuild(dct_path)
	check("JSONL cache rebuilds with new fields", db2 != null)
	if db2:
		var item := db2.get_item(skill_id)
		check("source survives JSONL→SQLite", str(item.get("source", "")) == "plugin:demo")
		check("pristine_hash survives JSONL→SQLite", str(item.get("pristine_hash", "")) == "deadbeef")
		check("pristine_content dict survives",
			item.get("pristine_content") is Dictionary
			and (item.get("pristine_content") as Dictionary).get("id") == "minerva_demo_make")
		check("unsatisfied_deps survives",
			item.get("unsatisfied_deps") is Array
			and (item.get("unsatisfied_deps") as Array).size() == 1)
		check("customised true survives", item.get("customised") == true)
		check("deprecated true survives", item.get("deprecated") == true)
		db2.close()


func test_plugin_skills_skill_get_lean_view() -> void:
	# docket_skill_get's lean _format_skill should expose source + deprecated
	# (T5 picker reads them) but NOT pristine_hash / pristine_content /
	# unsatisfied_deps / customised (reconciliation-only, would bloat).
	var db_path := _tmp_dir.path_join("skill_lean.db")
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()

	var registry := ToolRegistry.new()
	registry.init(schema, db)

	registry.call_tool("docket_create", {
		"type": "skill",
		"title": "Lean View Skill",
		"steps": "step",
		"source": "plugin:demo",
		"customised": true,
		"pristine_hash": "abcd",
		"pristine_content": {"x": 1},
		"unsatisfied_deps": ["minerva_demo_missing"],
		"deprecated": true,
	})

	# Activate and fetch
	var q := registry.call_tool("docket_query", {"filter": {"type": "skill"}})
	var items: Array = q.get("items", [])
	if items.size() > 0:
		var sid: String = str(items[0].get("id", ""))
		registry.call_tool("docket_transition", {"id": sid, "to": "active"})
		var lean := registry.call_tool("docket_skill_get", {"id": sid})
		check("lean view exposes source", lean.get("source", "") == "plugin:demo")
		check("lean view exposes deprecated when true", lean.get("deprecated", false) == true)
		check("lean view exposes unsatisfied_deps for picker filter",
			lean.has("unsatisfied_deps")
			and (lean.get("unsatisfied_deps", []) as Array).size() == 1)
		check("lean view OMITS pristine_hash", not lean.has("pristine_hash"))
		check("lean view OMITS pristine_content", not lean.has("pristine_content"))
		check("lean view OMITS customised", not lean.has("customised"))

	db.close()


func test_plugin_skills_alter_table_migration() -> void:
	# Simulate an "old" .dct that pre-dates the 6 new columns by:
	#   1. Creating a fresh DB (init_schema runs migrate already, so columns exist).
	#   2. Manually dropping the new columns via a schema reset is non-trivial in
	#      SQLite (no DROP COLUMN until 3.35; binding may be older).
	# Instead, verify the migration helper is idempotent: calling migrate_schema
	# on an already-migrated DB does NOT fail and does NOT corrupt data.
	var db_path := _tmp_dir.path_join("skill_migration.db")
	var db := DocketDB.create_new(db_path)

	# Insert a baseline record.
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()
	var id := db.next_uuid7_id()
	db.insert_item(id, DataModel.create_item(schema, "skill", {
		"title": "Pre-existing skill",
		"steps": "step",
	}))

	# Re-run migration; should be no-op.
	DocketDBSchema.migrate_schema(db)
	var fetched := db.get_item(id)
	check("data intact after re-running migrate_schema", str(fetched.get("title", "")) == "Pre-existing skill")

	# Confirm new columns are queryable on the existing DB.
	var rows := db._exec_select("PRAGMA table_info(items);")
	var col_names: Array = []
	for row in rows:
		col_names.append(str(row.get("name", "")))
	for new_col in ["source", "customised", "pristine_hash", "pristine_content", "unsatisfied_deps", "deprecated"]:
		check("column '%s' present after migration" % new_col, col_names.has(new_col))

	db.close()
