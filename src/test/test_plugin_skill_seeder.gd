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
	test_resolve_deps_own_namespace_satisfied_without_manifest_tools()
	test_resolve_deps_other_plugin_namespace_not_credited()
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

	print("\n-- unseed (T6) --")
	test_unseed_no_records_returns_zero()
	test_unseed_pristine_records_deleted()
	test_unseed_customised_records_converted_to_user()
	test_unseed_mixed_pristine_and_customised()
	test_unseed_clears_pristine_metadata_on_kept()
	test_unseed_distinguishes_plugins()

	print("\n-- recompute_unsatisfied (T7) --")
	test_recompute_no_skills_returns_zero()
	test_recompute_clears_now_satisfied()
	test_recompute_marks_now_unsatisfied()
	test_recompute_no_op_when_unchanged()
	test_recompute_partial_dep_satisfaction()

	print("\n-- plan_reconcile / apply_reconcile (T4) --")
	test_plan_seeds_new_skills()
	test_plan_no_change_on_matching_hash()
	test_plan_silent_update_on_pristine_hash_change()
	test_plan_prompt_required_on_customised_hash_change()
	test_plan_deprecates_records_absent_from_new_manifest()
	test_plan_does_not_re_deprecate_already_deprecated()
	test_apply_silent_update_writes_new_content()
	test_apply_prompted_accept_overwrites()
	test_apply_prompted_decline_keeps_user_edits()
	test_apply_prompted_missing_decision_declines()
	test_apply_deprecate_marks_records()

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


func test_resolve_deps_own_namespace_satisfied_without_manifest_tools() -> void:
	print("test_resolve_deps_own_namespace_satisfied_without_manifest_tools")
	# Backend-driven plugin: manifest tools[] is EMPTY, but the skill depends on
	# the plugin's own minerva_<id>_* tools (published by the backend at runtime).
	# resolve_deps must credit them via the namespace prefix, not the (empty)
	# manifest list. Without this, such a plugin's skills seed all-unsatisfied and
	# stay hidden. (codetools, 2026-06-08.)
	var def := _make_def("demo",
		[_skill("demo", "eps", ["minerva_demo_file_read", "minerva_demo_explore"])])
	# Note: NO tools[] passed -> manifest tools[] is empty; available_tools empty too.
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	check("own-namespace deps satisfied despite empty manifest tools[]",
		(resolved[0].get("unsatisfied", []) as Array).is_empty())


func test_resolve_deps_other_plugin_namespace_not_credited() -> void:
	print("test_resolve_deps_other_plugin_namespace_not_credited")
	# A dep in ANOTHER plugin's namespace is not this plugin's own tool — it must
	# stay unsatisfied (the namespace credit is scoped to minerva_<this_id>_*).
	var def := _make_def("demo", [_skill("demo", "zeta", ["minerva_otherplugin_thing"])])
	var resolved: Array = PluginSkillSeederScript.resolve_deps(def, {})
	var uns: Array = resolved[0].get("unsatisfied", [])
	check("foreign-namespace dep stays unsatisfied",
		uns.size() == 1 and uns[0] == "minerva_otherplugin_thing")


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


# ---------------------------------------------------------------------------
# unseed (T6)
# ---------------------------------------------------------------------------

func test_unseed_no_records_returns_zero() -> void:
	print("test_unseed_no_records_returns_zero")
	var ctx := _new_docket()
	var r: Dictionary = PluginSkillSeederScript.unseed("nonexistent_plugin", ctx.registry)
	check("deleted 0", r.get("deleted", 0) == 0)
	check("kept 0", r.get("kept", 0) == 0)
	check("kept_skill_ids empty", (r.get("kept_skill_ids", []) as Array).is_empty())
	ctx.db.close()


func test_unseed_pristine_records_deleted() -> void:
	print("test_unseed_pristine_records_deleted")
	var ctx := _new_docket()
	var def := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
	])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)
	# Both records are pristine (customised=false default).
	var r: Dictionary = PluginSkillSeederScript.unseed("demo", ctx.registry)
	check("deleted 2", r.get("deleted", 0) == 2)
	check("kept 0", r.get("kept", 0) == 0)

	# Verify records are gone.
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("alpha record gone", found.is_empty())
	ctx.db.close()


func test_unseed_customised_records_converted_to_user() -> void:
	print("test_unseed_customised_records_converted_to_user")
	var ctx := _new_docket()
	var def := _make_def("demo", [_skill("demo", "alpha", [])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)
	# Mark customised via update.
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	var record_id := str(found.get("id", ""))
	ctx.registry.call_tool("docket_update", {"id": record_id, "customised": true, "steps": "user-edited"})

	var r: Dictionary = PluginSkillSeederScript.unseed("demo", ctx.registry)
	check("deleted 0 (customised, not pristine)", r.get("deleted", 0) == 0)
	check("kept 1", r.get("kept", 1) == 1)
	check("kept_skill_ids has the record id",
		(r.get("kept_skill_ids", []) as Array).has(record_id))

	# Record still exists, source flipped to "user", edits preserved.
	var post = ctx.registry.call_tool("docket_get", {"id": record_id})
	check("record still exists", not post.has("error"))
	check("source flipped to 'user'", str(post.get("source", "")) == "user")
	check("user edits preserved", str(post.get("steps", "")) == "user-edited")
	ctx.db.close()


func test_unseed_mixed_pristine_and_customised() -> void:
	print("test_unseed_mixed_pristine_and_customised")
	var ctx := _new_docket()
	var def := _make_def("demo", [
		_skill("demo", "alpha", []),  # will stay pristine
		_skill("demo", "beta", []),   # will be customised
		_skill("demo", "gamma", []),  # will stay pristine
		_skill("demo", "delta", []),  # will be customised
		_skill("demo", "epsilon", []),# will stay pristine
	])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)

	# Mark beta and delta as customised.
	for short in ["beta", "delta"]:
		var f := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_%s" % short, ctx.registry)
		ctx.registry.call_tool("docket_update", {"id": str(f.get("id", "")), "customised": true})

	var r: Dictionary = PluginSkillSeederScript.unseed("demo", ctx.registry)
	check("deleted 3 pristines", r.get("deleted", 0) == 3)
	check("kept 2 customised", r.get("kept", 0) == 2)


func test_unseed_clears_pristine_metadata_on_kept() -> void:
	print("test_unseed_clears_pristine_metadata_on_kept")
	var ctx := _new_docket()
	var def := _make_def("demo", [_skill("demo", "alpha", [])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	var record_id := str(found.get("id", ""))
	ctx.registry.call_tool("docket_update", {"id": record_id, "customised": true})

	# Pre-condition: pristine_hash is non-empty.
	check("pre: pristine_hash non-empty", not str(found.get("pristine_hash", "")).is_empty())

	PluginSkillSeederScript.unseed("demo", ctx.registry)

	var post = ctx.registry.call_tool("docket_get", {"id": record_id})
	check("post: pristine_hash cleared", str(post.get("pristine_hash", "")).is_empty())
	check("post: pristine_content cleared",
		(post.get("pristine_content") is Dictionary)
		and (post.get("pristine_content") as Dictionary).is_empty())
	ctx.db.close()


func test_unseed_distinguishes_plugins() -> void:
	print("test_unseed_distinguishes_plugins")
	var ctx := _new_docket()
	# Install two plugins.
	var def_a := _make_def("plugin_a", [_skill("plugin_a", "alpha", [])])
	var def_b := _make_def("plugin_b", [_skill("plugin_b", "beta", [])])
	PluginSkillSeederScript.materialize("plugin_a",
		PluginSkillSeederScript.resolve_deps(def_a, {}), ctx.registry)
	PluginSkillSeederScript.materialize("plugin_b",
		PluginSkillSeederScript.resolve_deps(def_b, {}), ctx.registry)

	# Uninstall only plugin_a.
	var r: Dictionary = PluginSkillSeederScript.unseed("plugin_a", ctx.registry)
	check("plugin_a's 1 skill deleted", r.get("deleted", 0) == 1)

	# plugin_b's skill must still be there.
	var still := PluginSkillSeederScript.find_existing_record("plugin_b", "minerva_plugin_b_beta", ctx.registry)
	check("plugin_b's skill still exists", not still.is_empty())
	check("plugin_b's source unchanged", str(still.get("source", "")) == "plugin:plugin_b")
	ctx.db.close()


# ---------------------------------------------------------------------------
# recompute_unsatisfied (T7)
# ---------------------------------------------------------------------------

func test_recompute_no_skills_returns_zero() -> void:
	print("test_recompute_no_skills_returns_zero")
	var ctx := _new_docket()
	var r: Dictionary = PluginSkillSeederScript.recompute_unsatisfied({}, ctx.registry)
	check("updated 0", r.get("updated", 0) == 0)
	check("now_satisfied 0", r.get("now_satisfied", 0) == 0)
	check("now_unsatisfied 0", r.get("now_unsatisfied", 0) == 0)
	ctx.db.close()


func test_recompute_clears_now_satisfied() -> void:
	print("test_recompute_clears_now_satisfied")
	var ctx := _new_docket()
	# Install a skill with one missing dep.
	var def := _make_def("demo", [_skill("demo", "alpha", ["minerva_other_dep"])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)

	# Pre-condition: unsatisfied_deps has the missing dep.
	var pre := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("pre: unsatisfied has 1 entry",
		(pre.get("unsatisfied_deps", []) as Array).size() == 1)

	# Now the dep becomes available (e.g. another plugin installed).
	var r: Dictionary = PluginSkillSeederScript.recompute_unsatisfied(
		{"minerva_other_dep": true}, ctx.registry)
	check("updated 1", r.get("updated", 0) == 1)
	check("now_satisfied 1", r.get("now_satisfied", 0) == 1)

	# Post-condition: unsatisfied_deps cleared.
	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("post: unsatisfied is empty",
		(post.get("unsatisfied_deps", []) as Array).is_empty())
	ctx.db.close()


func test_recompute_marks_now_unsatisfied() -> void:
	print("test_recompute_marks_now_unsatisfied")
	var ctx := _new_docket()
	# Install a skill with all deps initially satisfied.
	var def := _make_def("demo", [_skill("demo", "alpha", ["minerva_external_dep"])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {"minerva_external_dep": true}),
		ctx.registry)

	# Pre-condition: unsatisfied is empty.
	var pre := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("pre: unsatisfied empty",
		(pre.get("unsatisfied_deps", []) as Array).is_empty())

	# External dep disappears (the providing plugin uninstalled).
	var r: Dictionary = PluginSkillSeederScript.recompute_unsatisfied({}, ctx.registry)
	check("updated 1", r.get("updated", 0) == 1)
	check("now_unsatisfied 1", r.get("now_unsatisfied", 0) == 1)

	# Post-condition: unsatisfied lists the now-missing dep.
	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("post: unsatisfied has the missing dep",
		(post.get("unsatisfied_deps", []) as Array).has("minerva_external_dep"))
	ctx.db.close()


func test_recompute_no_op_when_unchanged() -> void:
	print("test_recompute_no_op_when_unchanged")
	var ctx := _new_docket()
	var def := _make_def("demo", [_skill("demo", "alpha", ["minerva_dep"])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {"minerva_dep": true}),
		ctx.registry)
	# Same available_tools — nothing should change.
	var r: Dictionary = PluginSkillSeederScript.recompute_unsatisfied(
		{"minerva_dep": true}, ctx.registry)
	check("updated 0 when set unchanged", r.get("updated", 0) == 0)
	ctx.db.close()


func test_plan_seeds_new_skills() -> void:
	print("test_plan_seeds_new_skills")
	var ctx := _new_docket()
	# Empty docket; new manifest has 2 skills.
	var def := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
	])
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(def, {}, ctx.registry)
	var actions: Array = plan.get("actions", [])
	check("2 actions planned", actions.size() == 2)
	check("both are 'seed' actions",
		actions[0].action == PluginSkillSeederScript.RECONCILE_SEED
		and actions[1].action == PluginSkillSeederScript.RECONCILE_SEED)
	check("no deprecations", (plan.get("deprecate_record_ids", []) as Array).is_empty())
	ctx.db.close()


func test_plan_no_change_on_matching_hash() -> void:
	print("test_plan_no_change_on_matching_hash")
	var ctx := _new_docket()
	var skill := _skill("demo", "alpha", [])
	var def := _make_def("demo", [skill])
	# Install once.
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)
	# Plan re-install with identical content.
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(def, {}, ctx.registry)
	var actions: Array = plan.get("actions", [])
	check("1 action", actions.size() == 1)
	check("action is no_change",
		actions[0].action == PluginSkillSeederScript.RECONCILE_NO_CHANGE)
	ctx.db.close()


func test_plan_silent_update_on_pristine_hash_change() -> void:
	print("test_plan_silent_update_on_pristine_hash_change")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	# New version: changed steps, record stays pristine (customised=false).
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "v2 steps"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	var actions: Array = plan.get("actions", [])
	check("1 action", actions.size() == 1)
	check("action is silent_update",
		actions[0].action == PluginSkillSeederScript.RECONCILE_SILENT_UPDATE)
	ctx.db.close()


func test_plan_prompt_required_on_customised_hash_change() -> void:
	print("test_plan_prompt_required_on_customised_hash_change")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	# Mark customised.
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	ctx.registry.call_tool("docket_update", {"id": str(found.get("id", "")), "customised": true})

	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "v2 steps"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	var actions: Array = plan.get("actions", [])
	check("1 action", actions.size() == 1)
	check("action is prompt_required",
		actions[0].action == PluginSkillSeederScript.RECONCILE_PROMPT_REQUIRED)
	check("action carries existing record",
		actions[0].has("existing")
		and (actions[0].existing as Dictionary).get("customised") == true)
	ctx.db.close()


func test_plan_deprecates_records_absent_from_new_manifest() -> void:
	print("test_plan_deprecates_records_absent_from_new_manifest")
	var ctx := _new_docket()
	var def_v1 := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
	])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_v1, {}), ctx.registry)
	# v2 drops beta.
	var def_v2 := _make_def("demo", [_skill("demo", "alpha", [])])
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(def_v2, {}, ctx.registry)
	var deprecate_ids: Array = plan.get("deprecate_record_ids", [])
	check("1 record to deprecate", deprecate_ids.size() == 1)
	# Verify it's beta's record.
	var beta := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_beta", ctx.registry)
	check("deprecate id matches beta",
		deprecate_ids[0] == str(beta.get("id", "")))
	ctx.db.close()


func test_plan_does_not_re_deprecate_already_deprecated() -> void:
	print("test_plan_does_not_re_deprecate_already_deprecated")
	var ctx := _new_docket()
	var def_v1 := _make_def("demo", [_skill("demo", "alpha", [])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_v1, {}), ctx.registry)
	# Mark already-deprecated.
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	ctx.registry.call_tool("docket_update", {"id": str(found.get("id", "")), "deprecated": true})
	# v2 also drops alpha (it's gone from manifest).
	var def_v2 := _make_def("demo", [])
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(def_v2, {}, ctx.registry)
	check("already-deprecated not re-listed",
		(plan.get("deprecate_record_ids", []) as Array).is_empty())
	ctx.db.close()


func test_apply_silent_update_writes_new_content() -> void:
	print("test_apply_silent_update_writes_new_content")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "v2 steps"
	skill_v2["title"] = "Alpha v2"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	var result: Dictionary = PluginSkillSeederScript.apply_reconcile(plan, {}, ctx.registry)
	check("silent_updated 1", result.get("silent_updated", 0) == 1)
	# Verify new content + new hash.
	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("steps updated", str(post.get("steps", "")) == "v2 steps")
	check("title updated", str(post.get("title", "")) == "Alpha v2")
	check("pristine_hash matches new",
		str(post.get("pristine_hash", ""))
		== PluginSkillRecordScript.compute_hash(skill_v2))
	ctx.db.close()


func test_apply_prompted_accept_overwrites() -> void:
	print("test_apply_prompted_accept_overwrites")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	# Mark customised + edit steps.
	ctx.registry.call_tool("docket_update", {
		"id": str(found.get("id", "")),
		"customised": true,
		"steps": "user-edited steps",
	})
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "upstream v2 steps"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	# Accept the prompt.
	var decisions: Dictionary = {"minerva_demo_alpha": true}
	var result: Dictionary = PluginSkillSeederScript.apply_reconcile(plan, decisions, ctx.registry)
	check("prompted_accepted 1", result.get("prompted_accepted", 0) == 1)
	# User edits gone, upstream content in.
	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("user edits overwritten", str(post.get("steps", "")) == "upstream v2 steps")
	check("customised flag preserved (user fork lineage)", post.get("customised") == true)
	ctx.db.close()


func test_apply_prompted_decline_keeps_user_edits() -> void:
	print("test_apply_prompted_decline_keeps_user_edits")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	ctx.registry.call_tool("docket_update", {
		"id": str(found.get("id", "")),
		"customised": true,
		"steps": "user-edited steps",
	})
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "upstream v2 steps"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	var decisions: Dictionary = {"minerva_demo_alpha": false}
	var result: Dictionary = PluginSkillSeederScript.apply_reconcile(plan, decisions, ctx.registry)
	check("prompted_declined 1", result.get("prompted_declined", 0) == 1)
	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("user edits intact", str(post.get("steps", "")) == "user-edited steps")
	# pristine_content refreshed for later diff.
	check("pristine_content has upstream's new steps",
		str((post.get("pristine_content", {}) as Dictionary).get("steps", "")) == "upstream v2 steps")
	ctx.db.close()


func test_apply_prompted_missing_decision_declines() -> void:
	print("test_apply_prompted_missing_decision_declines")
	var ctx := _new_docket()
	var skill_v1 := _skill("demo", "alpha", [])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(_make_def("demo", [skill_v1]), {}), ctx.registry)
	var found := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	ctx.registry.call_tool("docket_update", {
		"id": str(found.get("id", "")),
		"customised": true,
		"steps": "user-edited",
	})
	var skill_v2 := _skill("demo", "alpha", [])
	skill_v2["steps"] = "upstream v2"
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(
		_make_def("demo", [skill_v2]), {}, ctx.registry)
	# No decision provided — defaults to decline.
	var result: Dictionary = PluginSkillSeederScript.apply_reconcile(plan, {}, ctx.registry)
	check("missing decision counts as declined",
		result.get("prompted_declined", 0) == 1
		and result.get("prompted_accepted", 0) == 0)
	ctx.db.close()


func test_apply_deprecate_marks_records() -> void:
	print("test_apply_deprecate_marks_records")
	var ctx := _new_docket()
	var def_v1 := _make_def("demo", [
		_skill("demo", "alpha", []),
		_skill("demo", "beta", []),
	])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def_v1, {}), ctx.registry)
	var def_v2 := _make_def("demo", [_skill("demo", "alpha", [])])
	var plan: Dictionary = PluginSkillSeederScript.plan_reconcile(def_v2, {}, ctx.registry)
	var result: Dictionary = PluginSkillSeederScript.apply_reconcile(plan, {}, ctx.registry)
	check("deprecated count 1", result.get("deprecated", 0) == 1)
	var beta := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_beta", ctx.registry)
	check("beta marked deprecated", beta.get("deprecated") == true)
	check("beta record still exists (not deleted)", not beta.is_empty())
	ctx.db.close()


func test_recompute_partial_dep_satisfaction() -> void:
	print("test_recompute_partial_dep_satisfaction")
	var ctx := _new_docket()
	# Skill needs two deps.  Install with both missing.
	var def := _make_def("demo",
		[_skill("demo", "alpha", ["minerva_a", "minerva_b"])])
	PluginSkillSeederScript.materialize("demo",
		PluginSkillSeederScript.resolve_deps(def, {}), ctx.registry)
	# Pre: both unsatisfied.
	var pre := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("pre: 2 unsatisfied", (pre.get("unsatisfied_deps", []) as Array).size() == 2)

	# Only one becomes available — skill is still hidden but unsatisfied list shrinks.
	var r: Dictionary = PluginSkillSeederScript.recompute_unsatisfied(
		{"minerva_a": true}, ctx.registry)
	check("updated 1 (list shrunk but still non-empty)", r.get("updated", 0) == 1)
	# Neither now_satisfied nor now_unsatisfied — went from non-empty to non-empty.
	check("now_satisfied 0 (still has unsat)", r.get("now_satisfied", 0) == 0)
	check("now_unsatisfied 0 (still has unsat)", r.get("now_unsatisfied", 0) == 0)

	var post := PluginSkillSeederScript.find_existing_record("demo", "minerva_demo_alpha", ctx.registry)
	check("post: only 'minerva_b' remains unsatisfied",
		(post.get("unsatisfied_deps", []) as Array).size() == 1
		and (post.get("unsatisfied_deps", []) as Array)[0] == "minerva_b")
	ctx.db.close()
