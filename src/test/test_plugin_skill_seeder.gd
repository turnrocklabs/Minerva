extends SceneTree
## Unit tests for PluginSkillSeeder (DCR 019df57b T3).
##
## Run: godot --headless --path src --script test/test_plugin_skill_seeder.gd
##
## Coverage:
##   resolve_deps:
##     - all deps satisfied via available_tools → empty unsatisfied
##     - missing dep → captured in unsatisfied
##     - plugin's own declared tools are satisfied even if not in available_tools
##     - empty / null tool_deps tolerated
##     - parallel structure preserved (one entry per skill in original order)
##
##   build_install_record:
##     - all 6 lifecycle fields populated correctly
##     - key = manifest skill id
##     - source = "plugin:<plugin_id>"
##     - pristine_hash matches PluginSkillRecord.compute_hash
##     - pristine_content is a deep copy (mutating original doesn't shift record)
##
##   find_existing_record:
##     - returns {} when no record exists
##     - returns full record when match exists
##     - distinguishes by source (different plugin → no match)
##
##   materialize:
##     - fresh install → seeded count matches skill count
##     - re-install with identical hash → skipped count matches (idempotent)
##     - re-install with content changed → deferred_to_update (does NOT overwrite)
##     - skill with empty manifest id → silently skipped
##     - empty resolved → all-zeros result

const PluginSkillSeederScript := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const PluginSkillRecordScript := preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")
const PluginDefinitionScript := preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


func _init() -> void:
	print("=== PluginSkillSeeder Tests ===\n")
	_tmp_dir = OS.get_cache_dir().path_join("minerva_seeder_test_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)

	print("-- resolve_deps --")
	test_resolve_deps_all_satisfied()
	test_resolve_deps_missing_external()
	test_resolve_deps_own_plugin_tools_satisfied()
	test_resolve_deps_empty_tool_deps()
	test_resolve_deps_preserves_skill_order()

	print("\n-- build_install_record --")
	test_build_install_record_shape()
	test_build_install_record_key_is_manifest_id()
	test_build_install_record_source_format()
	test_build_install_record_pristine_hash_matches_helper()
	test_build_install_record_pristine_content_is_deep_copy()

	print("\n-- find_existing_record / materialize --")
	test_find_existing_returns_empty_when_none()
	test_materialize_fresh_install_creates_records()
	test_materialize_idempotent_on_same_hash()
	test_materialize_defers_when_content_changed()
	test_materialize_distinguishes_plugins()
	test_materialize_skips_skill_without_id()
	test_materialize_empty_resolved()

	_cleanup_tmp()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


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


func _new_docket() -> Dictionary:
	# Returns {db, registry} — a self-contained in-memory docket for one test.
	var db_path := _tmp_dir.path_join("seeder_%d.db" % randi())
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()
	var registry := ToolRegistry.new()
	registry.init(schema, db)
	return {"db": db, "registry": registry}


func _make_def(plugin_id: String, skills: Array, tools: Array = []) -> PluginDefinitionScript:
	var manifest := {
		"id": plugin_id,
		"name": "%s plugin" % plugin_id,
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "x"},
		"ui": {"panels": [], "ipc_messages": []},
		"tools": tools,
		"skills": skills,
	}
	return PluginDefinitionScript.from_dict(manifest)


func _skill(plugin_id: String, short_id: String, deps: Array = ["minerva_core_anchor"]) -> Dictionary:
	return {
		"id": "minerva_%s_%s" % [plugin_id, short_id],
		"title": "%s %s" % [plugin_id, short_id],
		"summary": "Test skill.",
		"system_prompt": "You are testing.",
		"outcome": "Test passes.",
		"preconditions": "DocketDB available.",
		"steps": "1. Run.",
		"tool_deps": deps,
		"target": "all",
	}


# ---------------------------------------------------------------------------
# resolve_deps
# ---------------------------------------------------------------------------

func test_resolve_deps_all_satisfied() -> void:
	print("test_resolve_deps_all_satisfied")
	var def := _make_def("demo", [_skill("demo", "alpha", ["minerva_core_x"])])
	var available := {"minerva_core_x": true}
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, available)
	check("one entry returned", resolved.size() == 1)
	check("unsatisfied is empty", (resolved[0].get("unsatisfied", []) as Array).is_empty())


func test_resolve_deps_missing_external() -> void:
	print("test_resolve_deps_missing_external")
	var def := _make_def("demo", [_skill("demo", "beta", ["minerva_missing_tool"])])
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	check("unsatisfied has one entry", (resolved[0].get("unsatisfied", []) as Array).size() == 1)
	check("unsatisfied lists missing tool",
		(resolved[0].get("unsatisfied", []) as Array)[0] == "minerva_missing_tool")


func test_resolve_deps_own_plugin_tools_satisfied() -> void:
	print("test_resolve_deps_own_plugin_tools_satisfied")
	var def := _make_def("demo",
		[_skill("demo", "gamma", ["minerva_demo_own_tool"])],
		[{"name": "minerva_demo_own_tool", "description": "x", "input_schema": {}}])
	# available_tools is empty — this plugin's process isn't started yet.
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	check("plugin's own tool counts as satisfied",
		(resolved[0].get("unsatisfied", []) as Array).is_empty())


func test_resolve_deps_empty_tool_deps() -> void:
	print("test_resolve_deps_empty_tool_deps")
	var def := _make_def("demo", [_skill("demo", "delta", [])])
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	check("empty tool_deps yields empty unsatisfied",
		(resolved[0].get("unsatisfied", []) as Array).is_empty())


func test_resolve_deps_preserves_skill_order() -> void:
	print("test_resolve_deps_preserves_skill_order")
	var def := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
		_skill("demo", "gamma", []),
	])
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	check("3 entries", resolved.size() == 3)
	check("order alpha/beta/gamma preserved",
		(resolved[0].skill as Dictionary).get("id") == "minerva_demo_alpha"
		and (resolved[1].skill as Dictionary).get("id") == "minerva_demo_beta"
		and (resolved[2].skill as Dictionary).get("id") == "minerva_demo_gamma")


# ---------------------------------------------------------------------------
# build_install_record
# ---------------------------------------------------------------------------

func test_build_install_record_shape() -> void:
	print("test_build_install_record_shape")
	var skill := _skill("demo", "alpha")
	var record: Dictionary = PluginSkillSeederScript.build_install_record("demo", skill, [])
	check("type is skill", record.get("type") == "skill")
	check("source begins with plugin:", str(record.get("source", "")).begins_with("plugin:"))
	check("customised is false", record.get("customised") == false)
	check("deprecated is false", record.get("deprecated") == false)
	check("unsatisfied_deps is Array", record.get("unsatisfied_deps") is Array)
	check("pristine_content is Dictionary", record.get("pristine_content") is Dictionary)
	check("pristine_hash is non-empty", not str(record.get("pristine_hash", "")).is_empty())


func test_build_install_record_key_is_manifest_id() -> void:
	print("test_build_install_record_key_is_manifest_id")
	var skill := _skill("demo", "alpha")
	var record: Dictionary = PluginSkillSeederScript.build_install_record("demo", skill, [])
	check("key matches manifest skill id",
		record.get("key") == "minerva_demo_alpha")


func test_build_install_record_source_format() -> void:
	print("test_build_install_record_source_format")
	var skill := _skill("demo", "alpha")
	var record: Dictionary = PluginSkillSeederScript.build_install_record("demo", skill, [])
	check("source is 'plugin:demo'", record.get("source") == "plugin:demo")


func test_build_install_record_pristine_hash_matches_helper() -> void:
	print("test_build_install_record_pristine_hash_matches_helper")
	var skill := _skill("demo", "alpha")
	var record: Dictionary = PluginSkillSeederScript.build_install_record("demo", skill, [])
	var direct_hash := PluginSkillRecordScript.compute_hash(skill)
	check("record's pristine_hash matches direct compute_hash",
		record.get("pristine_hash") == direct_hash)


func test_build_install_record_pristine_content_is_deep_copy() -> void:
	print("test_build_install_record_pristine_content_is_deep_copy")
	var skill := _skill("demo", "alpha")
	var record: Dictionary = PluginSkillSeederScript.build_install_record("demo", skill, [])
	# Mutate the original after build; the record's pristine_content must NOT shift.
	skill["title"] = "MUTATED"
	(skill.get("tool_deps") as Array).append("minerva_demo_added_after")
	check("pristine_content title unchanged",
		(record.get("pristine_content") as Dictionary).get("title") != "MUTATED")
	check("pristine_content tool_deps unchanged",
		((record.get("pristine_content") as Dictionary).get("tool_deps") as Array).size() == 1)


# ---------------------------------------------------------------------------
# find_existing_record / materialize
# ---------------------------------------------------------------------------

func test_find_existing_returns_empty_when_none() -> void:
	print("test_find_existing_returns_empty_when_none")
	var ctx := _new_docket()
	var found: Dictionary = PluginSkillSeederScript.find_existing_record(
		"demo", "minerva_demo_nonexistent", ctx.registry)
	check("empty dict when no match", found.is_empty())
	ctx.db.close()


func test_materialize_fresh_install_creates_records() -> void:
	print("test_materialize_fresh_install_creates_records")
	var ctx := _new_docket()
	var def := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
	])
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	var result: Dictionary = PluginSkillSeederScript.materialize("demo", resolved, ctx.registry)
	check("seeded count is 2", result.get("seeded", 0) == 2)
	check("skipped count is 0", result.get("skipped", 0) == 0)
	check("deferred count is 0", result.get("deferred_to_update", 0) == 0)

	# Verify records actually exist.
	var found_alpha := PluginSkillSeederScript.find_existing_record(
		"demo", "minerva_demo_alpha", ctx.registry)
	check("alpha record found", not found_alpha.is_empty())
	check("alpha source is 'plugin:demo'", str(found_alpha.get("source", "")) == "plugin:demo")
	ctx.db.close()


func test_materialize_idempotent_on_same_hash() -> void:
	print("test_materialize_idempotent_on_same_hash")
	var ctx := _new_docket()
	var skills := [_skill("demo", "alpha", [])]
	var def := _make_def("demo", skills)

	# First install.
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	var first := PluginSkillSeederScript.materialize("demo", resolved, ctx.registry)
	check("first install seeds 1", first.get("seeded", 0) == 1)

	# Re-install with identical content.
	var second := PluginSkillSeederScript.materialize("demo", resolved, ctx.registry)
	check("re-install seeds 0", second.get("seeded", 0) == 0)
	check("re-install skips 1 (idempotent)", second.get("skipped", 0) == 1)
	check("re-install defers 0", second.get("deferred_to_update", 0) == 0)
	ctx.db.close()


func test_materialize_defers_when_content_changed() -> void:
	print("test_materialize_defers_when_content_changed")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	var def_v1 := _make_def("demo", [skill_v1])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_v1, {}), ctx.registry)

	# Same skill id, different content (steps changed → hash differs).
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "CHANGED"
	var def_v2 := _make_def("demo", [skill_v2])
	var second := PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_v2, {}), ctx.registry)
	check("content change defers (T4 owns)", second.get("deferred_to_update", 0) == 1)
	check("content change does NOT seed", second.get("seeded", 0) == 0)
	check("content change does NOT skip", second.get("skipped", 0) == 0)

	# Original record should still have the old content (NOT silently overwritten).
	var found := PluginSkillSeederScript.find_existing_record(
		"demo", "minerva_demo_alpha", ctx.registry)
	check("original record's steps unchanged",
		str(found.get("steps", "")) != "CHANGED")
	ctx.db.close()


func test_materialize_distinguishes_plugins() -> void:
	print("test_materialize_distinguishes_plugins")
	var ctx := _new_docket()
	# Two plugins with same short skill id — but the manifest ids are prefixed
	# (minerva_demo_alpha vs minerva_other_alpha) so they don't collide.
	var def_demo := _make_def("demo", [_skill("demo", "alpha", [])])
	var def_other := _make_def("other", [_skill("other", "alpha", [])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_demo, {}), ctx.registry)
	PluginSkillSeederScript.materialize("other",
		PluginSkillSeederScript.resolve_deps(def_other, {}), ctx.registry)

	# Querying for "demo's alpha" must NOT return "other's alpha".
	var found_demo := PluginSkillSeederScript.find_existing_record(
		"demo", "minerva_demo_alpha", ctx.registry)
	var found_other := PluginSkillSeederScript.find_existing_record(
		"other", "minerva_other_alpha", ctx.registry)
	check("demo record found", not found_demo.is_empty())
	check("other record found", not found_other.is_empty())
	check("source distinguishes",
		str(found_demo.get("source")) == "plugin:demo"
		and str(found_other.get("source")) == "plugin:other")

	# Cross-plugin lookup must miss (demo plugin asking for other's skill).
	var cross := PluginSkillSeederScript.find_existing_record(
		"demo", "minerva_other_alpha", ctx.registry)
	check("cross-plugin lookup misses", cross.is_empty())
	ctx.db.close()


func test_materialize_skips_skill_without_id() -> void:
	print("test_materialize_skips_skill_without_id")
	var ctx := _new_docket()
	# Construct a malformed resolved entry where skill has no id.  This shouldn't
	# happen in practice (T1 manifest validation rejects it) but the seeder
	# should be defensive — skip silently rather than crash or write a bad record.
	var resolved: Array = [{"skill": {"title": "no id"}, "unsatisfied": []}]
	var result: Dictionary = PluginSkillSeederScript.materialize("demo", resolved, ctx.registry)
	check("seeded 0 when skill id empty", result.get("seeded", 0) == 0)
	check("no error raised", not result.has("error"))
	ctx.db.close()


func test_materialize_empty_resolved() -> void:
	print("test_materialize_empty_resolved")
	var ctx := _new_docket()
	var result: Dictionary = PluginSkillSeederScript.materialize("demo", [], ctx.registry)
	check("seeded 0", result.get("seeded", 0) == 0)
	check("skipped 0", result.get("skipped", 0) == 0)
	check("deferred 0", result.get("deferred_to_update", 0) == 0)
	ctx.db.close()
