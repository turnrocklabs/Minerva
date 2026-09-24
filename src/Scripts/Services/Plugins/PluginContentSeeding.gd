extends RefCounted
## What a plugin's lifecycle does to the Docket content it ships: its skills
## (PluginSkillSeeder) and its knowledge (PluginKnowledgeSeeder), seeded at
## install, reconciled at update and after a rolled-back update, and unseeded
## at uninstall. Called by PluginManager (`manager`), which asks the user
## through PluginSkillConsent; all Docket access goes through the seeders'
## docket_* calls.

const SkillSeeder := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const Knowledge := preload("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
const SkillConsent := preload("res://Scripts/Services/Plugins/PluginSkillConsent.gd")
const Txn := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")

## The skill record fields an accepted update overwrites (and a rollback puts
## back from the journal).
const SKILL_FIELDS := ["title", "summary", "prompt_text", "outcome", "preconditions", "steps",
	"tool_deps", "target", "optimization", "customised", "pristine_hash"]


## Resolve tool_deps + (optionally) confirm with the user + materialise skill
## and knowledge records for a newly installed `def` (one consent covers
## both). Consent collected before the install began is final: nothing is
## asked now, and a question it did not cover counts as declined.
static func seed_install(manager, def, auto_confirm: bool, consent: Dictionary) -> Dictionary:
	var docket_manager = docket()
	var resolved: Array = SkillSeeder.resolve_deps(def, available_tools(manager))
	var accepted: bool = bool(consent.get("seed", false)) if consent.get("collected", false) else auto_confirm
	if not auto_confirm and not consent.get("collected", false):
		accepted = await SkillConsent.ask_seed(manager, def, resolved)
	if not accepted:
		return {"skills_seeded": 0, "skills_skipped": 0, "skills_deferred_to_update": 0, "skills_declined": true}

	var materialised: Dictionary = SkillSeeder.materialize(def.id, resolved, docket_manager)
	var seeded := {
		"skills_seeded": materialised.get("seeded", 0),
		"skills_skipped": materialised.get("skipped", 0),
		"skills_deferred_to_update": materialised.get("deferred_to_update", 0),
	}
	if not def.knowledge.is_empty():
		var knowledge_plan: Dictionary = Knowledge.plan(def, docket_manager)
		seeded["knowledge"] = Knowledge.apply(knowledge_plan, {}, docket_manager)
		_note_missing_project(def, knowledge_plan, seeded)
	return seeded


## Bring the Docket content of `previous_def`'s plugin in line with `def`:
##   - new skills or knowledge → seeded (not by an unattended update,
##     consent.seed_new false: those wait for one made by hand);
##   - pristine record with content changed → silent overwrite;
##   - customised record with content changed → decided per item
##     (update_decisions);
##   - record absent from `def` → marked deprecated (NOT deleted);
##   - knowledge_project moved → the old project's records retired
##     (deprecated, ids kept) once the new one can take them; unseeded there
##     when the install commits (content_committed).
## Inside an install transaction (consent.journal_dir), `def` and the content
## of every customised record about to take the update are first saved as the
## operation's DOCKET_JOURNAL, so a rollback, even after a crash, can undo it
## all; if that cannot be saved, nothing is written to Docket. A rollback
## itself (consent.rollback) seeds nothing and always moves back.
## Returns the counts to merge into the caller's result.
static func reconcile(manager, previous_def, def, consent: Dictionary, auto_confirm: bool) -> Dictionary:
	var docket_manager = docket()
	var result := {}

	# Phase 1: classify each skill and knowledge action (no docket writes yet).
	var plan: Dictionary = SkillSeeder.plan_reconcile(def, available_tools(manager), docket_manager)
	var has_knowledge: bool = not (def.knowledge.is_empty() and previous_def.knowledge.is_empty())
	var knowledge_plan: Dictionary = Knowledge.plan(def, docket_manager) if has_knowledge else {}

	# Phase 2: collect user decisions for prompt_required actions.
	var decisions: Dictionary = await update_decisions(manager, def,
		plan.get("actions", []) + knowledge_plan.get("actions", []), consent, auto_confirm)
	var rollback: bool = consent.get("rollback", false)
	if rollback or not consent.get("seed_new", true):
		for p in [plan, knowledge_plan]:
			p["actions"] = p.get("actions", []).filter(func(action) -> bool:
				return str(action.get("action", "")) != SkillSeeder.RECONCILE_SEED)

	# Phase 3: commit.
	var moving: bool = previous_def.knowledge_project != def.knowledge_project and has_knowledge \
		and not knowledge_plan.get("missing_project", false) and (rollback or consent.get("seed_new", true))
	var journal_dir := str(consent.get("journal_dir", ""))
	if not journal_dir.is_empty() and not Txn.save_docket_journal(journal_dir,
			_journal(def, plan, knowledge_plan, decisions, previous_def.knowledge_project if moving else "")):
		var skipped := "%s's skills and knowledge were not updated: their undo record could not be saved in %s" % [
			def.id, journal_dir]
		push_warning("[PluginContentSeeding] " + skipped)
		return {"content_skipped": skipped}
	result["reconcile"] = SkillSeeder.apply_reconcile(plan, decisions, docket_manager)
	if moving:
		result["knowledge_retired"] = Knowledge.retire(def.id, previous_def.knowledge_project, docket_manager)
	if has_knowledge:
		result["knowledge"] = Knowledge.apply(knowledge_plan, decisions, docket_manager)
		_note_missing_project(def, knowledge_plan, result)
	result.merge(recompute_reactivity(manager))
	return result


## After an update of `attempted_def`'s plugin was rolled back, put its Docket
## content back in line with what is installed again: the restored definition,
## with no questions and every customised record keeping its text, then the
## text of records the update overwrote with consent put back from `journal`;
## or, when a first install was undone and no record is left, nothing of it.
## journal_left holds the journal entries still to put back: a record whose
## project is not loaded, or whose write failed (one since deleted is done).
static func reconcile_after_rollback(manager, attempted_def, journal: Dictionary) -> Dictionary:
	var restored = manager.get_db().get_by_id(attempted_def.id)
	if restored == null:
		return unseed(manager, attempted_def.id)
	var result: Dictionary = await reconcile(manager, attempted_def, restored,
		{"collected": true, "update_decisions": {}, "rollback": true}, false)
	var docket_manager = docket()
	var put_back := 0
	var left := []
	for before in journal.get("entries", []):
		var changes: Dictionary = before.get("fields", {}).duplicate()
		changes["id"] = before.get("id", "")
		var project := str(before.get("project", ""))
		if not project.is_empty():
			changes["project"] = project
		# docket_update puts an unknown project's write in the primary one.
		var written = docket_manager.call_tool("docket_update", changes) \
			if docket_manager != null and (project.is_empty() or Knowledge.project_loaded(project, docket_manager)) \
			else {"error": "not loaded"}
		if Knowledge._ok(written):
			put_back += 1
		elif not str(written.get("error", "") if written is Dictionary else "").begins_with("Item not found"):
			left.append(before)
	result["customised_put_back"] = put_back
	result["journal_left"] = left
	return result


## Whether each customised skill or knowledge record among `actions` (from
## plan_reconcile / PluginKnowledgeSeeder.plan) takes the update, keyed by its
## manifest id: from consent collected before the install began (an item not
## asked about then keeps its customisation), from auto_confirm, or by asking.
static func update_decisions(manager, def, actions: Array, consent: Dictionary, auto_confirm: bool) -> Dictionary:
	var decisions := {}
	for action in actions:
		if str(action.get("action", "")) != SkillSeeder.RECONCILE_PROMPT_REQUIRED:
			continue
		var item: Dictionary = action.get("entry", action.get("skill", {}))
		var item_id := str(action.get("id", item.get("id", "")))
		if consent.get("collected", false):
			decisions[item_id] = bool(consent.get("update_decisions", {}).get(item_id, false))
		else:
			decisions[item_id] = auto_confirm or await SkillConsent.ask_update(manager, def, action.get("existing", {}), item)
	return decisions


## Whether a reconcile_after_rollback `result` finished: no Docket write
## failed and no journal entry is left to put back.
static func complete(result: Dictionary) -> bool:
	return not result.has("content_skipped") and result.get("reconcile", {}).get("failed", 0) == 0 \
		and result.get("knowledge", {}).get("failed", 0) == 0 and result.get("journal_left", []).is_empty()


## An update's install committed: the records its knowledge_project move
## retired (journal.retired_project) are unseeded there. Returns whether
## that finished (false while the project is not loaded or a write failed).
static func content_committed(journal: Dictionary) -> bool:
	var retired := str(journal.get("retired_project", ""))
	if retired.is_empty() or not journal.get("attempted") is Dictionary:
		return true
	var unseeded: Dictionary = Knowledge.unseed(str(journal.attempted.get("id", "")), retired, docket())
	return unseeded.failed == 0 and not unseeded.has("missing_project")


## Remove `plugin_id`'s skills and knowledge (in every loaded project):
## pristine records are deleted, customised ones become the user's
## (source "user", provenance cleared). Returns the result fields.
static func unseed(manager, plugin_id: String) -> Dictionary:
	var docket_manager = docket()
	var result := {}
	if docket_manager == null:
		return result
	var skills: Dictionary = SkillSeeder.unseed(plugin_id, docket_manager)
	if skills.get("deleted", 0) > 0 or skills.get("kept", 0) > 0:
		result["skills_deleted"] = skills.get("deleted", 0)
		result["skills_kept"] = skills.get("kept", 0)
		result["skills_kept_ids"] = skills.get("kept_skill_ids", [])
	var knowledge: Dictionary = Knowledge.unseed_everywhere(plugin_id, docket_manager)
	if knowledge.get("deleted", 0) > 0 or knowledge.get("kept", 0) > 0 or knowledge.get("failed", 0) > 0:
		result["knowledge"] = knowledge
	result.merge(recompute_reactivity(manager))
	return result


## Recompute unsatisfied_deps for every skill record after a plugin lifecycle
## change; returns the reactivity_* result fields when anything changed.
static func recompute_reactivity(manager) -> Dictionary:
	var docket_manager = docket()
	if docket_manager == null:
		return {}
	var reactivity: Dictionary = SkillSeeder.recompute_unsatisfied(available_tools(manager), docket_manager)
	if reactivity.get("updated", 0) == 0:
		return {}
	return {
		"reactivity_updated": reactivity.get("updated", 0),
		"reactivity_now_satisfied": reactivity.get("now_satisfied", 0),
		"reactivity_now_unsatisfied": reactivity.get("now_unsatisfied", 0),
	}


## The union of (1) MCP-registered tools and (2) all installed plugins'
## declared tools: the "available_tools" set skill-deps resolution uses. A
## tool counts as available if it is in the MCP registry OR declared by an
## installed plugin, running or not (invocation time enforces that).
static func available_tools(manager) -> Dictionary:
	var available: Dictionary = {}
	if typeof(SingletonObject) != TYPE_NIL and "mcp_manager" in SingletonObject \
			and SingletonObject.mcp_manager != null \
			and "tool_registry" in SingletonObject.mcp_manager:
		for tool_name in (SingletonObject.mcp_manager.tool_registry as Dictionary):
			available[tool_name] = true
	if manager.get_db() != null:
		for def in manager.get_db().get_all():
			for tool_entry in def.tools:
				var tname := str(tool_entry.get("name", ""))
				if not tname.is_empty():
					available[tname] = true
	return available


## Tests point this at their own Docket (a ToolRegistry).
static var docket_override = null


## The docket manager, via SingletonObject when present, else null.
static func docket():
	if docket_override != null:
		return docket_override
	if typeof(SingletonObject) != TYPE_NIL and "docket_manager" in SingletonObject:
		return SingletonObject.docket_manager
	return null


## The DOCKET_JOURNAL for applying `def`: the definition, the project a move
## retires (or ""), and the current content of every customised skill or
## knowledge record the update is about to overwrite with consent.
static func _journal(def, plan: Dictionary, knowledge_plan: Dictionary, decisions: Dictionary,
		retired_project: String) -> Dictionary:
	var entries := []
	for action in plan.get("actions", []) + knowledge_plan.get("actions", []):
		var item: Dictionary = action.get("entry", action.get("skill", {}))
		var item_id := str(action.get("id", item.get("id", "")))
		if str(action.get("action", "")) != SkillSeeder.RECONCILE_PROMPT_REQUIRED or not decisions.get(item_id, false):
			continue
		var existing: Dictionary = action.get("existing", {})
		var fields := {}
		for field in (Knowledge.CONTENT_FIELDS[existing.type] if action.has("entry") else SKILL_FIELDS):
			if existing.get(field) != null:
				fields[field] = existing[field]
		entries.append({"id": str(existing.get("id", "")), "fields": fields,
			"project": str(knowledge_plan.get("project", "")) if action.has("entry") else ""})
	return {"attempted": def.to_dict(), "retired_project": retired_project, "entries": entries}


## Record in `result`, and log, that `def`'s knowledge project is not loaded.
static func _note_missing_project(def, knowledge_plan: Dictionary, result: Dictionary) -> void:
	if knowledge_plan.get("missing_project", false):
		result["knowledge_missing_project"] = def.knowledge_project
		push_warning("[PluginContentSeeding] '%s' knowledge was not seeded: Docket project '%s' is not open" % [
			def.id, def.knowledge_project])
