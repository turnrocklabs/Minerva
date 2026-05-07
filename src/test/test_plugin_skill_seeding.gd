extends SceneTree
## Full round-trip integration test for plugin-shipped skills (DCR 019df57b T8).
##
## Run: godot --headless --path src --script test/test_plugin_skill_seeding.gd
##
## Walks the lifecycle described in the DCR's acceptance test (#8):
##   1. Install plugin v1 with one skill   → record materialised, source=plugin, hash captured
##   2. Edit one field via user_edit       → customised flag flips, source preserved
##   3. Update plugin v2 with same content → no prompt (hash matches), no change
##   4. Update plugin v3 with content edit → prompt path, accept-decision overwrites correctly
##   5. Update plugin v4 removing the skill → record marked deprecated (NOT deleted)
##   6. Uninstall plugin                    → customised record converts to source=user
##                                             (deprecated stays true; record kept for user)
##
## Hits every component: PluginDefinition (T1), PluginSkillRecord (T2),
## PluginSkillSeeder.materialize (T3), reconcile plan + apply (T4), unseed (T6),
## reactivity (T7).  T5 picker integration is visual-only — covered by HITL.

const PluginDefinitionScript := preload("res://Scripts/Services/Plugins/PluginDefinition.gd")
const PluginSkillSeederScript := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const PluginSkillRecordScript := preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


func _init() -> void:
	print("=== Plugin-shipped skills T8 round-trip ===\n")
	_tmp_dir = OS.get_cache_dir().path_join("minerva_dcr_019df57b_t8_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)

	test_full_lifecycle()

	_cleanup_tmp()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


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


func _make_def(plugin_id: String, skills: Array) -> PluginDefinitionScript:
	var manifest := {
		"id": plugin_id,
		"name": "%s plugin" % plugin_id,
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "x"},
		"ui": {"panels": [], "ipc_messages": []},
		"tools": [],
		"skills": skills,
	}
	return PluginDefinitionScript.from_dict(manifest)


func _slide_deck_skill(plugin_id: String = "presentation_demo", version_marker: String = "v1") -> Dictionary:
	# Models the DCR's example skill ("Make a slide deck"), parameterised so we
	# can produce hash-stable / hash-shifting variants per lifecycle phase.
	return {
		"id": "minerva_%s_make_slide_deck" % plugin_id,
		"title": "Make a slide deck",
		"summary": "Compose a multi-slide presentation from notes or chat context.",
		"system_prompt": "You are a presentation author working on Minerva.",
		"outcome": "A .mdeck deck with at least one slide is open in a panel.",
		"preconditions": "The presentation plugin is installed and a panel can be opened.",
		"steps": "1. Read context. 2. Plan slides. 3. Add slides. 4. Refine. (%s)" % version_marker,
		"tool_deps": ["presentation_create_deck", "presentation_add_slide"],
		"target": "all",
		"optimization": {"tool_budget": 30000, "context_window": "default"},
	}


func _new_docket() -> Dictionary:
	var db_path := _tmp_dir.path_join("t8_%d.db" % randi())
	var db := DocketDB.create_new(db_path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	var schema: Dictionary = JSON.parse_string(sf.get_as_text())
	sf.close()
	var registry := ToolRegistry.new()
	registry.init(schema, db)
	return {"db": db, "registry": registry}


# ---------------------------------------------------------------------------
# Full round-trip
# ---------------------------------------------------------------------------

func test_full_lifecycle() -> void:
	print("test_full_lifecycle (DCR 019df57b T8 round-trip)")
	var ctx := _new_docket()
	var registry = ctx.registry
	var plugin_id := "presentation_demo"

	# ---- Phase 1: install plugin v1 ----
	print("  -- phase 1: install v1 --")
	var skill_v1 := _slide_deck_skill(plugin_id, "v1")
	var def_v1 := _make_def(plugin_id, [skill_v1])
	var resolved := PluginSkillSeederScript.resolve_deps(def_v1,
		{"presentation_create_deck": true, "presentation_add_slide": true})
	var install_result: Dictionary = PluginSkillSeederScript.materialize(plugin_id, resolved, registry)
	check("v1 seeded 1 record", install_result.get("seeded", 0) == 1)
	check("v1 nothing skipped or deferred",
		install_result.get("skipped", 0) == 0 and install_result.get("deferred_to_update", 0) == 0)

	var record := PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, registry)
	check("record exists", not record.is_empty())
	check("source is 'plugin:<id>'", str(record.get("source", "")) == "plugin:%s" % plugin_id)
	check("customised is false on fresh install", record.get("customised") == false)
	check("pristine_hash is non-empty", not str(record.get("pristine_hash", "")).is_empty())
	var v1_hash := str(record.get("pristine_hash", ""))
	check("pristine_content captures the manifest entry",
		(record.get("pristine_content", {}) as Dictionary).get("id") == skill_v1.id)

	# ---- Phase 2: user edits the skill ----
	print("  -- phase 2: user edit --")
	var edit_result := PluginSkillRecordScript.apply_user_edit(
		str(record.get("id", "")),
		{"steps": "USER-EDITED 1. Read 2. Make"},
		registry)
	check("user edit succeeded", not edit_result.has("error"))

	var after_edit := PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, registry)
	check("steps reflect user edit", str(after_edit.get("steps", "")) == "USER-EDITED 1. Read 2. Make")
	check("customised auto-flipped to true", after_edit.get("customised") == true)
	check("source preserved as plugin:<id>",
		str(after_edit.get("source", "")) == "plugin:%s" % plugin_id)
	check("pristine_hash unchanged after user edit",
		str(after_edit.get("pristine_hash", "")) == v1_hash)

	# ---- Phase 3: re-install identical version → no prompt, no change ----
	print("  -- phase 3: re-install identical version --")
	var plan_v1_again := PluginSkillSeederScript.plan_reconcile(def_v1, {}, registry)
	var actions_v1_again: Array = plan_v1_again.get("actions", [])
	check("v1 re-install has 1 action", actions_v1_again.size() == 1)
	check("action is no_change (hash matches even though customised)",
		str(actions_v1_again[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_NO_CHANGE)

	# ---- Phase 4: update to v3 (content changed) → prompt path ----
	print("  -- phase 4: update v3 with changed content --")
	var skill_v3 := _slide_deck_skill(plugin_id, "v3")  # different version_marker → hash shift
	var def_v3 := _make_def(plugin_id, [skill_v3])
	var plan_v3 := PluginSkillSeederScript.plan_reconcile(def_v3, {}, registry)
	var actions_v3: Array = plan_v3.get("actions", [])
	check("v3 plan has 1 action", actions_v3.size() == 1)
	check("v3 action is prompt_required (customised + hash differs)",
		str(actions_v3[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_PROMPT_REQUIRED)

	# 4a: decline → user edits preserved, pristine_content refreshed.
	var decline_result := PluginSkillSeederScript.apply_reconcile(
		plan_v3, {("minerva_%s_make_slide_deck" % plugin_id): false}, registry)
	check("v3 decline counted", decline_result.get("prompted_declined", 0) == 1)
	var after_decline := PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, registry)
	check("user edit STILL intact after decline",
		str(after_decline.get("steps", "")) == "USER-EDITED 1. Read 2. Make")
	check("pristine_content refreshed to v3 (so user can diff later)",
		str((after_decline.get("pristine_content", {}) as Dictionary).get("steps", "")).contains("v3"))

	# 4b: accept the SAME prompt → user edits get overwritten.
	var plan_v3_again := PluginSkillSeederScript.plan_reconcile(def_v3, {}, registry)
	# Note: pristine_content was refreshed but pristine_hash wasn't (decline doesn't
	# touch hash).  So plan still classifies as prompt_required.
	check("v3 still classified as prompt_required after decline",
		str((plan_v3_again.actions as Array)[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_PROMPT_REQUIRED)
	var accept_result := PluginSkillSeederScript.apply_reconcile(
		plan_v3_again, {("minerva_%s_make_slide_deck" % plugin_id): true}, registry)
	check("v3 accept counted", accept_result.get("prompted_accepted", 0) == 1)
	var after_accept := PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, registry)
	check("upstream v3 content now in record",
		str(after_accept.get("steps", "")).contains("v3"))
	check("customised stays true after accept (user lineage preserved)",
		after_accept.get("customised") == true)
	check("pristine_hash updated to v3", str(after_accept.get("pristine_hash", "")) != v1_hash)

	# ---- Phase 5: v4 manifest drops the skill → mark deprecated ----
	print("  -- phase 5: v4 removes the skill --")
	var def_v4 := _make_def(plugin_id, [])  # no skills
	var plan_v4 := PluginSkillSeederScript.plan_reconcile(def_v4, {}, registry)
	var deprecate_ids: Array = plan_v4.get("deprecate_record_ids", [])
	check("v4 has 1 record to deprecate", deprecate_ids.size() == 1)
	var v4_apply := PluginSkillSeederScript.apply_reconcile(plan_v4, {}, registry)
	check("v4 marked 1 record deprecated", v4_apply.get("deprecated", 0) == 1)
	var after_deprecate := PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, registry)
	check("record still exists (deprecated, not deleted)",
		not after_deprecate.is_empty())
	check("deprecated flag is true", after_deprecate.get("deprecated") == true)

	# ---- Phase 6: uninstall ----
	print("  -- phase 6: uninstall --")
	var unseed_result := PluginSkillSeederScript.unseed(plugin_id, registry)
	check("uninstall kept 1 customised record",
		unseed_result.get("kept", 0) == 1)
	check("uninstall deleted 0 (only one was customised)",
		unseed_result.get("deleted", 0) == 0)

	var orphan: Dictionary = registry.call_tool("docket_get",
		{"id": str(after_deprecate.get("id", ""))})
	check("orphan record still readable", not orphan.has("error"))
	check("orphan source flipped to 'user'", str(orphan.get("source", "")) == "user")
	check("orphan deprecated flag preserved",
		orphan.get("deprecated") == true)
	check("orphan pristine_hash cleared", str(orphan.get("pristine_hash", "")).is_empty())

	# ---- Bonus: T7 reactivity smoke ----
	print("  -- bonus: T7 reactivity --")
	# Orphan now has tool_deps that don't resolve (presentation_create_deck etc.
	# went away with the plugin).  Reset unsatisfied_deps to [] first so the
	# now_unsatisfied counter reflects the lifecycle event we're testing rather
	# than residual state from phase 4's plan_reconcile (which ran with empty
	# available_tools and pre-populated unsatisfied_deps).
	registry.call_tool("docket_update", {
		"id": str(after_deprecate.get("id", "")),
		"unsatisfied_deps": [],
	})
	var reactivity := PluginSkillSeederScript.recompute_unsatisfied({}, registry)
	check("reactivity catches orphan's now-broken tool_deps",
		reactivity.get("now_unsatisfied", 0) >= 1)
	var after_react: Dictionary = registry.call_tool("docket_get",
		{"id": str(after_deprecate.get("id", ""))})
	check("orphan unsatisfied_deps populated",
		(after_react.get("unsatisfied_deps", []) as Array).size() >= 1)

	ctx.db.close()
