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
## Plugin knowledge[] (PluginKnowledgeSeeder) walks the same lifecycle for a kb
## article and a hint: seeded into the named project with provenance, a
## customised record asked about (declining keeps the person's text and is
## not asked again), a pristine one updated silently, a dropped key
## deprecated, uninstall keeping only what a person changed, and a project
## that is not loaded left untouched. PluginSkillConsent asks one seed
## question for a plugin that ships only knowledge, and keys an update's
## decision about a customised record by its manifest key. When an update the
## person accepted over their customised text is rolled back,
## PluginContentSeeding puts their text back; when an update that moved the
## knowledge to another project is rolled back (from its journal, as crash
## recovery does), the original record, same id, is live again in its
## original project; once such a move commits, the person's record left in
## the old project becomes theirs, live.
##
## Hits every component: PluginDefinition (T1), PluginSkillRecord (T2),
## PluginSkillSeeder.materialize (T3), reconcile plan + apply (T4), unseed (T6),
## reactivity (T7).  T5 picker integration is visual-only — covered by HITL.

const PluginDefinitionScript := preload("res://Scripts/Services/Plugins/PluginDefinition.gd")
const PluginSkillSeederScript := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const PluginSkillRecordScript := preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")
const PluginSkillConsentScript := preload("res://Scripts/Services/Plugins/PluginSkillConsent.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


## The PluginDB questions PluginSkillConsent asks: `plugin_id` is installed,
## with no knowledge in its installed definition.
class InstalledDB extends RefCounted:
	var _id: String

	func _init(plugin_id: String) -> void:
		_id = plugin_id

	func has_plugin(plugin_id: String) -> bool:
		return plugin_id == _id

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return PluginDefinition.new(plugin_id) if plugin_id == _id else null


## A PluginManager as PluginContentSeeding sees it after a rollback: a plugin
## DB holding the restored definition.
class RolledBackManager extends RefCounted:
	var restored: PluginDefinition

	func _init(p_restored: PluginDefinition) -> void:
		restored = p_restored

	func get_db():
		return self

	func get_by_id(_id: String) -> PluginDefinition:
		return restored

	func get_all() -> Array:
		return [restored]


class FailingUpdateDocket extends RefCounted:
	var inner

	func _init(p_inner) -> void:
		inner = p_inner

	func call_tool(tool_name: String, arguments: Dictionary):
		if tool_name == "docket_update":
			return {"error": "injected write failure"}
		return inner.call_tool(tool_name, arguments)


func _init() -> void:
	# PluginSkillConsent references project autoloads; let those globals
	# register before any test work begins.
	await process_frame
	print("=== Plugin-shipped skills T8 round-trip ===\n")
	_tmp_dir = OS.get_cache_dir().path_join("minerva_dcr_019df57b_t8_%d" % randi())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)

	await test_full_lifecycle()
	await test_repair_keeps_customised_skills()
	await test_knowledge_lifecycle()
	await test_knowledge_consent()
	await test_rollback_restores_content()
	await test_unsaved_knowledge_retry()

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


func _manifest(plugin_id: String, skills: Array) -> Dictionary:
	return {
		"id": plugin_id,
		"name": "%s plugin" % plugin_id,
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "x"},
		"ui": {"panels": [], "ipc_messages": []},
		"tools": [],
		"skills": skills,
	}


func _make_def(plugin_id: String, skills: Array) -> PluginDefinitionScript:
	return PluginDefinitionScript.from_dict(_manifest(plugin_id, skills))


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
	registry.init(schema, db, {"master": db})  # loaded as "master", as in Minerva
	return {"db": db, "registry": registry, "docket": PluginSeedingDocket.new(registry, false)}


# ---------------------------------------------------------------------------
# Full round-trip
# ---------------------------------------------------------------------------

func test_full_lifecycle() -> void:
	print("test_full_lifecycle (DCR 019df57b T8 round-trip)")
	var ctx := _new_docket()
	var registry = ctx.registry
	var docket = ctx.docket
	var plugin_id := "presentation_demo"

	# ---- Phase 1: install plugin v1 ----
	print("  -- phase 1: install v1 --")
	var skill_v1 := _slide_deck_skill(plugin_id, "v1")
	var def_v1 := _make_def(plugin_id, [skill_v1])
	var resolved := PluginSkillSeederScript.resolve_deps(def_v1,
		{"presentation_create_deck": true, "presentation_add_slide": true})
	var install_result: Dictionary = await PluginSkillSeederScript.materialize(plugin_id, resolved, docket)
	check("v1 seeded 1 record", install_result.get("seeded", 0) == 1)
	check("v1 nothing skipped or deferred",
		install_result.get("skipped", 0) == 0 and install_result.get("deferred_to_update", 0) == 0)

	var record := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
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

	var after_edit := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
	check("steps reflect user edit", str(after_edit.get("steps", "")) == "USER-EDITED 1. Read 2. Make")
	check("customised auto-flipped to true", after_edit.get("customised") == true)
	check("source preserved as plugin:<id>",
		str(after_edit.get("source", "")) == "plugin:%s" % plugin_id)
	check("pristine_hash unchanged after user edit",
		str(after_edit.get("pristine_hash", "")) == v1_hash)

	# ---- Phase 3: re-install identical version → no prompt, no change ----
	print("  -- phase 3: re-install identical version --")
	var plan_v1_again := await PluginSkillSeederScript.plan_reconcile(def_v1, {}, docket)
	var actions_v1_again: Array = plan_v1_again.get("actions", [])
	check("v1 re-install has 1 action", actions_v1_again.size() == 1)
	check("action is no_change (hash matches even though customised)",
		str(actions_v1_again[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_NO_CHANGE)

	# ---- Phase 4: update to v3 (content changed) → prompt path ----
	print("  -- phase 4: update v3 with changed content --")
	var skill_v3 := _slide_deck_skill(plugin_id, "v3")  # different version_marker → hash shift
	var def_v3 := _make_def(plugin_id, [skill_v3])
	var plan_v3 := await PluginSkillSeederScript.plan_reconcile(def_v3, {}, docket)
	var actions_v3: Array = plan_v3.get("actions", [])
	check("v3 plan has 1 action", actions_v3.size() == 1)
	check("v3 action is prompt_required (customised + hash differs)",
		str(actions_v3[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_PROMPT_REQUIRED)

	# 4a: decline → user edits preserved, pristine_content refreshed.
	var decline_result := await PluginSkillSeederScript.apply_reconcile(
		plan_v3, {("minerva_%s_make_slide_deck" % plugin_id): false}, docket)
	check("v3 decline counted", decline_result.get("prompted_declined", 0) == 1)
	var after_decline := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
	check("user edit STILL intact after decline",
		str(after_decline.get("steps", "")) == "USER-EDITED 1. Read 2. Make")
	check("pristine_content refreshed to v3 (so user can diff later)",
		str((after_decline.get("pristine_content", {}) as Dictionary).get("steps", "")).contains("v3"))

	# 4b: accept the SAME prompt → user edits get overwritten.
	var plan_v3_again := await PluginSkillSeederScript.plan_reconcile(def_v3, {}, docket)
	# Note: pristine_content was refreshed but pristine_hash wasn't (decline doesn't
	# touch hash).  So plan still classifies as prompt_required.
	check("v3 still classified as prompt_required after decline",
		str((plan_v3_again.actions as Array)[0].get("action", "")) == PluginSkillSeederScript.RECONCILE_PROMPT_REQUIRED)
	var accept_result := await PluginSkillSeederScript.apply_reconcile(
		plan_v3_again, {("minerva_%s_make_slide_deck" % plugin_id): true}, docket)
	check("v3 accept counted", accept_result.get("prompted_accepted", 0) == 1)
	var after_accept := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
	check("upstream v3 content now in record",
		str(after_accept.get("steps", "")).contains("v3"))
	check("customised stays true after accept (user lineage preserved)",
		after_accept.get("customised") == true)
	check("pristine_hash updated to v3", str(after_accept.get("pristine_hash", "")) != v1_hash)

	# ---- Phase 5: v4 manifest drops the skill → mark deprecated ----
	print("  -- phase 5: v4 removes the skill --")
	var def_v4 := _make_def(plugin_id, [])  # no skills
	var plan_v4 := await PluginSkillSeederScript.plan_reconcile(def_v4, {}, docket)
	var deprecate_ids: Array = plan_v4.get("deprecate_record_ids", [])
	check("v4 has 1 record to deprecate", deprecate_ids.size() == 1)
	var v4_apply := await PluginSkillSeederScript.apply_reconcile(plan_v4, {}, docket)
	check("v4 marked 1 record deprecated", v4_apply.get("deprecated", 0) == 1)
	var after_deprecate := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
	check("record still exists (deprecated, not deleted)",
		not after_deprecate.is_empty())
	check("deprecated flag is true", after_deprecate.get("deprecated") == true)
	# Shipped again unchanged (as after a rolled-back update): revived, text kept.
	await PluginSkillSeederScript.apply_reconcile(await PluginSkillSeederScript.plan_reconcile(def_v3, {}, docket), {}, docket)
	var revived := await PluginSkillSeederScript.find_existing_record(
		plugin_id, "minerva_%s_make_slide_deck" % plugin_id, docket)
	check("a deprecated skill shipped again is revived with its text kept",
		revived.get("deprecated") == false and str(revived.get("steps", "")) == str(after_deprecate.get("steps", "")))
	await PluginSkillSeederScript.apply_reconcile(plan_v4, {}, docket)

	# ---- Phase 6: uninstall ----
	print("  -- phase 6: uninstall --")
	var unseed_result := await PluginSkillSeederScript.unseed(plugin_id, docket)
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
	var reactivity := await PluginSkillSeederScript.recompute_unsatisfied({}, docket)
	check("reactivity catches orphan's now-broken tool_deps",
		reactivity.get("now_unsatisfied", 0) >= 1)
	var after_react: Dictionary = registry.call_tool("docket_get",
		{"id": str(after_deprecate.get("id", ""))})
	check("orphan unsatisfied_deps populated",
		(after_react.get("unsatisfied_deps", []) as Array).size() >= 1)

	ctx.db.close()


## A required plugin's repair installs over its existing record with
## auto_confirm, yet the skill questions it answers for itself must keep a
## customised skill while shipped (pristine) ones follow the release.
func test_repair_keeps_customised_skills() -> void:
	print("test_repair_keeps_customised_skills")
	var ctx := _new_docket()
	var registry = ctx.registry
	var docket = ctx.docket
	var plugin_id := "agent_relay"
	var custom_v1 := _slide_deck_skill(plugin_id, "custom-v1")
	var pristine_v1 := _slide_deck_skill(plugin_id, "pristine-v1")
	pristine_v1.id = "minerva_agent_relay_pristine"
	var def_v1 := _make_def(plugin_id, [custom_v1, pristine_v1])
	await PluginSkillSeederScript.materialize(
		plugin_id, PluginSkillSeederScript.resolve_deps(def_v1, {}), docket)
	var custom_record := await PluginSkillSeederScript.find_existing_record(
		plugin_id, custom_v1.id, docket)
	PluginSkillRecordScript.apply_user_edit(
		str(custom_record.get("id", "")), {"steps": "user-owned steps"}, registry)

	var custom_v2 := custom_v1.duplicate(true)
	custom_v2.steps = "shipped custom v2"
	var pristine_v2 := pristine_v1.duplicate(true)
	pristine_v2.steps = "shipped pristine v2"
	var def_v2 := _make_def(plugin_id, [custom_v2, pristine_v2])
	var manifest_path := _tmp_dir.path_join("repair_manifest.json")
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_manifest(plugin_id, [custom_v2, pristine_v2])))
	f.close()
	var op = load("res://Scripts/Services/Plugins/PluginInstallOperation.gd").new()
	op.repair_only = true
	var consent: Dictionary = await PluginSkillConsentScript.collect(
		root, InstalledDB.new(plugin_id), {}, docket, manifest_path, true, op)
	await PluginSkillSeederScript.apply_reconcile(await PluginSkillSeederScript.plan_reconcile(def_v2, {}, docket),
		consent.get("update_decisions", {}), docket)
	var custom_after := await PluginSkillSeederScript.find_existing_record(plugin_id, custom_v1.id, docket)
	var pristine_after := await PluginSkillSeederScript.find_existing_record(plugin_id, pristine_v1.id, docket)
	check("a repair keeps the customised skill without asking",
		str(custom_after.get("steps", "")) == "user-owned steps")
	check("a repair updates the pristine shipped skill",
		str(pristine_after.get("steps", "")) == "shipped pristine v2")

	var failure_plan := await PluginSkillSeederScript.plan_reconcile(def_v2, {}, docket)
	var failed: Dictionary = await PluginSkillSeederScript.apply_reconcile(
		failure_plan, {}, PluginSeedingDocket.new(FailingUpdateDocket.new(registry), false))
	check("reconcile reports failed store writes", int(failed.get("failed", 0)) > 0)
	var Seeding = load("res://Scripts/Services/Plugins/PluginContentSeeding.gd")
	Seeding.docket_override = FailingUpdateDocket.new(registry)
	var unseeded: Dictionary = await Seeding.unseed(RolledBackManager.new(def_v2), plugin_id)
	Seeding.docket_override = null
	check("an unseed that cannot hand a customised skill to the person is not complete",
		unseeded.get("skills_failed", 0) > 0 and not Seeding.complete(unseeded))
	ctx.db.close()


## Knowledge written to another project whose file could not be saved is not
## done until that file holds it, even when a retry finds nothing left to
## change (the cache already has it).
func test_unsaved_knowledge_retry() -> void:
	print("test_unsaved_knowledge_retry")
	var ctx := _new_docket()
	var path := _tmp_dir.path_join("notes_%d.dct.jsonl" % randi())
	var notes_db := DocketDBJsonl.create_new_jsonl(path)
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	ctx.registry.init(JSON.parse_string(sf.get_as_text()), ctx.db, {"master": ctx.db, "notes": notes_db})
	sf.close()
	var registry = ctx.registry
	var docket = ctx.docket
	var Knowledge = load("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
	await Knowledge.apply(await Knowledge.plan(_knowledge_def("notes", [_kb("Red to red."), _hint("9600")]), docket), {}, docket)
	# A version that drops both deprecates them, while a directory stands
	# where the project's file goes.
	var dropped := _knowledge_def("notes", [])
	DirAccess.remove_absolute(path)
	DirAccess.make_dir_absolute(path)
	var failed: Dictionary = await Knowledge.apply(await Knowledge.plan(dropped, docket), {}, docket)
	var retry_plan: Dictionary = await Knowledge.plan(dropped, docket)
	var retried: Dictionary = await Knowledge.apply(retry_plan, {}, docket)
	DirAccess.remove_absolute(path)
	var saved: Dictionary = await Knowledge.apply(await Knowledge.plan(dropped, docket), {}, docket)
	var stored_deprecated := 0
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var stored = JSON.parse_string(line)
		if stored is Dictionary and stored.get("deprecated", 0) != 0:
			stored_deprecated += 1
	check("a retry with nothing left to change fails until the project's file holds the change",
		failed.failed > 0 and retry_plan.actions.is_empty() and retry_plan.deprecate_record_ids.is_empty()
		and retried.failed > 0 and saved.failed == 0 and stored_deprecated == 2)
	notes_db.close()
	ctx.db.close()


func _knowledge_def(project: String, entries: Array) -> PluginDefinitionScript:
	var manifest := _manifest("notes_demo", [])
	manifest["knowledge_project"] = project
	manifest["knowledge"] = entries
	return PluginDefinitionScript.from_dict(manifest)


func _kb(article: String) -> Dictionary:
	return {"key": "minerva_notes_demo_wiring", "type": "kb", "title": "Wiring",
		"article": article, "tags": ["wiring", "bench"]}


func _hint(value: String, component: String = "") -> Dictionary:
	var hint := {"key": "minerva_notes_demo_baud", "type": "hint", "title": "Baud", "value": value}
	if not component.is_empty():
		hint["component"] = component
	return hint


func test_knowledge_lifecycle() -> void:
	print("test_knowledge_lifecycle")
	var ctx := _new_docket()
	var registry = ctx.registry
	var docket = ctx.docket
	var Knowledge = load("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
	var find := func(key: String) -> Dictionary:
		for type in ["kb", "hint"]:
			var found: Dictionary = registry.call_tool("docket_query", {"filter": {"type": type, "key": key}})
			for item in found.get("items", []):
				return registry.call_tool("docket_get", {"id": item.id})
		return {}

	var missing = await Knowledge.plan(_knowledge_def("not_loaded", [_kb("Red to red.")]), docket)
	check("a project that is not loaded is reported and nothing is planned",
		missing.get("missing_project", false) and missing.actions.is_empty())

	var v1 := _knowledge_def("master", [_kb("Red to red."), _hint("115200", "serial")])
	var seeded: Dictionary = await Knowledge.apply(await Knowledge.plan(v1, docket), {}, docket)
	var kb: Dictionary = find.call("minerva_notes_demo_wiring")
	var hint: Dictionary = find.call("minerva_notes_demo_baud")
	check("kb and hint are seeded with key, source and pristine provenance",
		seeded.seeded == 2 and kb.get("source") == "plugin:notes_demo" and hint.get("value") == "115200"
		and kb.get("pristine_hash") == Knowledge.content_hash(kb)
		and kb.get("pristine_content", {}).get("article") == "Red to red.")
	check("the kb article is active; the hint stays a draft",
		kb.get("status") == "active" and hint.get("status") == "draft")
	check("seeded records read back unchanged, tags included",
		(await Knowledge.plan(v1, docket)).actions.all(func(a) -> bool: return a.action == "no_change"))

	registry.call_tool("docket_update", {"id": kb.id, "article": "Red to red; black to COM."})
	var v2 := _knowledge_def("master", [_kb("Red to red, always."), _hint("9600")])
	var plan2: Dictionary = await Knowledge.plan(v2, docket)
	var asked: Array = plan2.actions.filter(func(a) -> bool: return a.action == "prompt_required")
	check("an update asks only about the customised kb article",
		asked.size() == 1 and asked[0].id == "minerva_notes_demo_wiring")
	var applied: Dictionary = await Knowledge.apply(plan2, {}, docket)
	check("declining keeps the person's article; the pristine hint is updated silently, its dropped field cleared",
		applied.prompted_declined == 1 and applied.silent_updated == 1
		and find.call("minerva_notes_demo_wiring").get("article") == "Red to red; black to COM."
		and find.call("minerva_notes_demo_baud").get("value") == "9600"
		and str(find.call("minerva_notes_demo_baud").get("component", "")).is_empty())
	check("the same upstream version is not asked about again",
		(await Knowledge.plan(v2, docket)).actions.all(func(a) -> bool: return a.action == "no_change"))

	var v3 := _knowledge_def("master", [_kb("Red to red, always.")])
	var dropped: Dictionary = await Knowledge.apply(await Knowledge.plan(v3, docket), {}, docket)
	check("a key the manifest drops is deprecated, not deleted",
		dropped.deprecated == 1 and find.call("minerva_notes_demo_baud").get("deprecated") == true)
	var back: Dictionary = await Knowledge.apply(await Knowledge.plan(v2, docket), {}, docket)
	check("a dropped key that comes back unchanged is revived",
		back.restored == 1 and find.call("minerva_notes_demo_baud").get("deprecated") == false
		and find.call("minerva_notes_demo_baud").get("value") == "9600")

	var removed: Dictionary = await Knowledge.unseed("notes_demo", "master", docket)
	var kept: Dictionary = find.call("minerva_notes_demo_wiring")
	check("uninstall deletes the unchanged hint and hands the edited article to the user",
		removed.deleted == 1 and removed.kept == 1 and find.call("minerva_notes_demo_baud").is_empty()
		and kept.get("source") == "user" and kept.get("article") == "Red to red; black to COM.")
	ctx.db.close()


func test_knowledge_consent() -> void:
	print("test_knowledge_consent")
	var ctx := _new_docket()
	var registry = ctx.registry
	var docket = ctx.docket
	var Knowledge = load("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
	await Knowledge.apply(await Knowledge.plan(_knowledge_def("master", [_kb("Red to red.")]), docket), {}, docket)
	var found: Dictionary = registry.call_tool("docket_query", {"filter": {"type": "kb", "key": "minerva_notes_demo_wiring"}})
	registry.call_tool("docket_update", {"id": found.items[0].id, "article": "My own wiring notes."})

	var manifest := _manifest("notes_demo", [])
	manifest["knowledge"] = [_kb("Red to red, always.")]
	var manifest_path := _tmp_dir.path_join("knowledge_manifest.json")
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()

	var fresh: Dictionary = await PluginSkillConsentScript.collect(
		root, InstalledDB.new("another_plugin"), {}, docket, manifest_path, true)
	check("a plugin that ships only knowledge gets a seed decision (auto-confirmed here, no dialog)",
		fresh.get("seed") == true)
	var update: Dictionary = await PluginSkillConsentScript.collect(
		root, InstalledDB.new("notes_demo"), {}, docket, manifest_path, true)
	check("an update's decision about the customised kb is keyed by its manifest key",
		update.get("update_decisions", {}) == {"minerva_notes_demo_wiring": true})
	var op = load("res://Scripts/Services/Plugins/PluginInstallOperation.gd").new()
	op.repair_only = true
	var repair: Dictionary = await PluginSkillConsentScript.collect(
		root, InstalledDB.new("notes_demo"), {}, docket, manifest_path, true, op)
	check("a repair keeps the customised kb without asking",
		repair.get("update_decisions", {}) == {"minerva_notes_demo_wiring": false})
	ctx.db.close()


func test_rollback_restores_content() -> void:
	print("test_rollback_restores_content")
	var ctx := _new_docket()
	var notes_db := DocketDB.create_new(_tmp_dir.path_join("t8_notes_%d.db" % randi()))
	var registry = ctx.registry
	var docket = ctx.docket
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	registry.init(JSON.parse_string(sf.get_as_text()), ctx.db, {"master": ctx.db, "notes": notes_db})
	sf.close()
	var Knowledge = load("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
	var Seeding = load("res://Scripts/Services/Plugins/PluginContentSeeding.gd")
	var Txn = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
	Seeding.docket_override = registry

	var v1 := _knowledge_def("master", [_kb("Red to red.")])
	await Knowledge.apply(await Knowledge.plan(v1, docket), {}, docket)
	var found: Dictionary = registry.call_tool("docket_query", {"filter": {"type": "kb", "key": "minerva_notes_demo_wiring"}})
	var original_id: String = found.items[0].id
	registry.call_tool("docket_update", {"id": original_id, "article": "MY NOTES"})

	# While its undo record cannot be saved, an update writes nothing.
	var v2 := _knowledge_def("master", [_kb("Red to red, always.")])
	var blocked_dir := _tmp_dir.path_join("blocked").path_join("op_blocked")
	DirAccess.make_dir_recursive_absolute(blocked_dir)
	FileAccess.open(_tmp_dir.path_join("blocked").path_join(Txn.CONTENT_PENDING), FileAccess.WRITE).close()
	var skipped: Dictionary = await Seeding.reconcile(RolledBackManager.new(v2), v1, v2, {"collected": true,
		"update_decisions": {"minerva_notes_demo_wiring": true}, "journal_dir": blocked_dir}, false)
	check("an update whose undo record cannot be saved leaves the person's text alone",
		skipped.has("content_skipped") and registry.call_tool("docket_get", {"id": original_id}).get("article") == "MY NOTES")

	# The person accepts v2 over their text; v2 then fails and is rolled back.
	var op_dir := _tmp_dir.path_join("op_rollback")
	DirAccess.make_dir_recursive_absolute(op_dir)
	await Seeding.reconcile(RolledBackManager.new(v2), v1, v2, {"collected": true,
		"update_decisions": {"minerva_notes_demo_wiring": true}, "journal_dir": op_dir}, false)
	check("the accepted update overwrote the person's text, saving it first",
		registry.call_tool("docket_get", {"id": original_id}).get("article") == "Red to red, always."
		and Txn.content_journal(op_dir).get("entries", []).size() == 1)
	# Beside it, a journaled record the person has since deleted, and one in a
	# project that is not loaded.
	var rollback_journal: Dictionary = Txn.content_journal(op_dir)
	var unloaded := {"id": "unloaded-record", "fields": {"article": "THEIRS"}, "project": "archive"}
	rollback_journal.entries.append({"id": "deleted-record", "fields": {"article": "GONE"}, "project": "master"})
	rollback_journal.entries.append(unloaded)
	var put_back: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(v1), v2,
		rollback_journal)
	var restored: Dictionary = registry.call_tool("docket_get", {"id": original_id})
	check("after the rollback the person's text is back, and it still counts as customised",
		put_back.get("customised_put_back") == 1 and restored.get("article") == "MY NOTES"
		and Knowledge.content_hash(restored) != str(restored.get("pristine_hash", "")))
	check("only the unloaded project's record is left to put back; a deleted one is done",
		put_back.get("journal_left") == [unloaded] and not Seeding.complete(put_back))

	# An update that moves the knowledge to another project, then rolled back
	# as crash recovery does: from the definition its journal saved.
	var move_dir := _tmp_dir.path_join("op_move")
	DirAccess.make_dir_recursive_absolute(move_dir)
	var v3 := _knowledge_def("notes", [_kb("Red to red.")])
	await Seeding.reconcile(RolledBackManager.new(v3), v1, v3,
		{"collected": true, "update_decisions": {}, "journal_dir": move_dir}, false)
	check("moving the knowledge retires the original record rather than deleting it",
		registry.call_tool("docket_get", {"id": original_id}).get("deprecated") == true)
	var journal: Dictionary = Txn.content_journal(move_dir)
	var moved_back: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(v1),
		PluginDefinition.from_dict(journal.attempted), journal)
	var revived: Dictionary = registry.call_tool("docket_get", {"id": original_id})
	var in_notes: Dictionary = registry.call_tool("docket_query", {"project": "notes",
		"filter": {"type": "kb", "key": "minerva_notes_demo_wiring"}})
	check("after its rollback the original record, same id, is live again with the person's text",
		moved_back.get("knowledge", {}).get("restored", 0) == 1
		and revived.get("deprecated") == false and revived.get("article") == "MY NOTES")
	check("the rolled-back version's copy in the other project is retired",
		in_notes.get("items", []).size() == 1 and registry.call_tool("docket_get",
			{"id": in_notes.items[0].id, "project": "notes"}).get("deprecated") == true)

	# Rolling back an update that wrote knowledge in a project not loaded now
	# repairs the rest, and stays unfinished until that project is loaded.
	var archive_def := _knowledge_def("archive", [_kb("Red to red.")])
	var unloaded_move: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(v1),
		archive_def, {"knowledge_written": true})
	check("a rollback that could not reach a project repairs the rest and is not complete",
		unloaded_move.has("reconcile") and unloaded_move.has("knowledge")
		and unloaded_move.get("knowledge_missing_project") == "archive" and not Seeding.complete(unloaded_move))
	# One whose project was never loaded wrote nothing there to repair.
	var never_written: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(v1),
		archive_def, {"knowledge_written": false})
	check("a rollback of knowledge that was never written does not wait for its project",
		not never_written.has("knowledge_missing_project") and Seeding.complete(never_written))

	# The same move, committed: the old project's customised record becomes
	# the person's, live.
	var commit_dir := _tmp_dir.path_join("op_commit")
	DirAccess.make_dir_recursive_absolute(commit_dir)
	await Seeding.reconcile(RolledBackManager.new(v3), v1, v3,
		{"collected": true, "update_decisions": {}, "journal_dir": commit_dir}, false)
	await Seeding.content_committed(Txn.content_journal(commit_dir))
	var kept: Dictionary = registry.call_tool("docket_get", {"id": original_id})
	check("once the move commits, the person's record in the old project is theirs and live",
		kept.get("source") == "user" and kept.get("deprecated") == false and kept.get("article") == "MY NOTES")

	# A silent update interrupted between writing its text and sealing it
	# leaves the record looking customised; the rollback still puts it back
	# exactly, sealed.
	var h1 := _knowledge_def("master", [_hint("9600")])
	await Knowledge.apply(await Knowledge.plan(h1, docket), {}, docket)
	var seal_dir := _tmp_dir.path_join("op_seal")
	DirAccess.make_dir_recursive_absolute(seal_dir)
	var h2 := _knowledge_def("master", [_hint("115200")])
	await Seeding.reconcile(RolledBackManager.new(h2), h1, h2,
		{"collected": true, "update_decisions": {}, "journal_dir": seal_dir}, false)
	var baud_id: String = registry.call_tool("docket_query",
		{"filter": {"type": "hint", "key": "minerva_notes_demo_baud"}}).items[0].id
	registry.call_tool("docket_update", {"id": baud_id, "pristine_hash": "unsealed"})
	var unsealed_back: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(h1), h2,
		Txn.content_journal(seal_dir))
	var baud: Dictionary = registry.call_tool("docket_get", {"id": baud_id})
	check("a rollback after an interrupted seal restores the pristine record, sealed",
		baud.get("value") == "9600" and Knowledge.content_hash(baud) == str(baud.get("pristine_hash", ""))
		and Seeding.complete(unsealed_back))

	# The person's text is overwritten by an update they accepted; they change
	# the record again before its rollback: their newer text stays, and the
	# text from before the update is held for them to decide on.
	registry.call_tool("docket_update", {"id": baud_id, "value": "4800"})
	var edit_dir := _tmp_dir.path_join("op_edited")
	DirAccess.make_dir_recursive_absolute(edit_dir)
	var h3 := _knowledge_def("master", [_hint("57600")])
	await Seeding.reconcile(RolledBackManager.new(h3), h1, h3, {"collected": true,
		"update_decisions": {"minerva_notes_demo_baud": true}, "journal_dir": edit_dir}, false)
	registry.call_tool("docket_update", {"id": baud_id, "value": "NEWER"})
	var edited_back: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(h1), h3,
		Txn.content_journal(edit_dir))
	var held: Array = edited_back.get("journal_left", [])
	check("a rollback keeps a change made after the update and holds the earlier text",
		registry.call_tool("docket_get", {"id": baud_id}).get("value") == "NEWER"
		and edited_back.get("journal_conflicts", []).size() == 1 and held.size() == 1
		and held[0].get("fields", {}).get("value") == "4800" and not Seeding.complete(edited_back))

	# An accepted skill update, rolled back: what the update wrote is
	# recognised (not taken for a later edit), and the person's steps return.
	var skill_v1 := _slide_deck_skill("notes_demo", "v1")
	var s1 := _make_def("notes_demo", [skill_v1])
	await PluginSkillSeederScript.materialize("notes_demo", PluginSkillSeederScript.resolve_deps(s1, {}), docket)
	var skill_id := str((await PluginSkillSeederScript.find_existing_record("notes_demo", skill_v1.id, docket)).get("id", ""))
	PluginSkillRecordScript.apply_user_edit(skill_id, {"steps": "my own steps"}, registry)
	var s2 := _make_def("notes_demo", [_slide_deck_skill("notes_demo", "v2")])
	var skill_dir := _tmp_dir.path_join("op_skill")
	DirAccess.make_dir_recursive_absolute(skill_dir)
	await Seeding.reconcile(RolledBackManager.new(s2), s1, s2, {"collected": true,
		"update_decisions": {skill_v1.id: true}, "journal_dir": skill_dir}, false)
	var skill_took := str(registry.call_tool("docket_get", {"id": skill_id}).get("steps", ""))
	var skill_back: Dictionary = await Seeding.reconcile_after_rollback(RolledBackManager.new(s1), s2,
		Txn.content_journal(skill_dir))
	check("a rolled-back accepted skill update puts the person's steps back, with no conflict",
		skill_took != "my own steps" and registry.call_tool("docket_get", {"id": skill_id}).get("steps") == "my own steps"
		and not skill_back.has("journal_conflicts") and Seeding.complete(skill_back))
	Seeding.docket_override = null
	notes_db.close()
	ctx.db.close()
