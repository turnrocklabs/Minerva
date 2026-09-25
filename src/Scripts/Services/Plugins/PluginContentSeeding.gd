extends RefCounted
## What a plugin's lifecycle does to the Docket content it ships: its skills
## (PluginSkillSeeder) and its knowledge (PluginKnowledgeSeeder), seeded at
## install, reconciled at update and after a rolled-back update, and unseeded
## at uninstall. Called by PluginManager (`manager`), which asks the user
## through PluginSkillConsent; all Docket access goes through the seeders'
## docket_* calls, awaited on docket(). When Docket cannot be reached, nothing
## is written and the result says so (content_skipped).

const SkillSeeder := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const Knowledge := preload("res://Scripts/Services/Plugins/PluginKnowledgeSeeder.gd")
const SkillConsent := preload("res://Scripts/Services/Plugins/PluginSkillConsent.gd")
const Txn := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
const SeedingDocket := preload("res://Scripts/Services/Plugins/PluginSeedingDocket.gd")

## Where a journaled record stands at a rollback (_journal_state).
const JOURNAL_WRITTEN := "written"
const JOURNAL_RESTORED := "restored"
const JOURNAL_EDITED := "edited"
const JOURNAL_GONE := "gone"
const JOURNAL_UNREACHABLE := "unreachable"

## The skill record fields an accepted update overwrites (and a rollback puts
## back from the journal).
const SKILL_FIELDS := ["title", "summary", "prompt_text", "outcome", "preconditions", "steps",
	"tool_deps", "target", "optimization", "customised", "pristine_hash"]
## A knowledge record's provenance, put back with its content.
const KNOWLEDGE_SEAL := ["pristine_hash", "pristine_content"]
## The skill fields a person or an update changes (compared, not provenance).
const SKILL_CONTENT := Knowledge.SKILL_CONTENT


## Resolve tool_deps + (optionally) confirm with the user + materialise skill
## and knowledge records for a newly installed `def` (one consent covers
## both). Consent collected before the install began is final: nothing is
## asked now, and a question it did not cover counts as declined. Inside an
## install transaction (consent.journal_dir) the operation's Docket journal
## is saved first, so a rollback unseeds what this seeds; if it cannot be,
## nothing is seeded.
static func seed_install(manager, def, auto_confirm: bool, consent: Dictionary) -> Dictionary:
	var docket_caller := docket()
	var why := docket_caller.unavailable()
	if not why.is_empty():
		return {"content_skipped": _unreached(def, "seeded", why)}
	var resolved: Array = SkillSeeder.resolve_deps(def, available_tools(manager))
	var accepted: bool = bool(consent.get("seed", false)) if consent.get("collected", false) else auto_confirm
	if not auto_confirm and not consent.get("collected", false):
		accepted = await SkillConsent.ask_seed(manager, def, resolved)
	if not accepted:
		return {"skills_seeded": 0, "skills_skipped": 0, "skills_deferred_to_update": 0, "skills_declined": true}

	var knowledge_plan: Dictionary = await Knowledge.plan(def, docket_caller) if not def.knowledge.is_empty() else {}
	if not _save_journal(consent, def, _journal(def, {}, knowledge_plan, {}, "")):
		return {"content_skipped": _skipped(def, consent)}
	var materialised: Dictionary = await SkillSeeder.materialize(def.id, resolved, docket_caller)
	var seeded := {
		"skills_seeded": materialised.get("seeded", 0),
		"skills_skipped": materialised.get("skipped", 0),
		"skills_deferred_to_update": materialised.get("deferred_to_update", 0),
	}
	if not knowledge_plan.is_empty():
		seeded["knowledge"] = await Knowledge.apply(knowledge_plan, {}, docket_caller)
		_note_missing_project(def, knowledge_plan, seeded)
	return _finish(seeded, docket_caller, def.id, "seeded")


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
## of every record about to take the update (customised ones with consent,
## and pristine knowledge, seal included) are first saved as the
## operation's Docket journal (PluginInstallTransaction.CONTENT_PENDING), so a
## rollback, even after a crash, can undo it all; if that cannot be saved,
## nothing is written to Docket. A rollback
## itself (consent.rollback) seeds nothing and moves back, retiring the
## attempted project's records only if it wrote any (consent.previous_written).
## Returns the counts to merge into the caller's result. `operation`, when
## given, is the Docket binding of an operation this reconcile is part of.
static func reconcile(manager, previous_def, def, consent: Dictionary, auto_confirm: bool,
		operation: SeedingDocket = null) -> Dictionary:
	var docket_caller := operation if operation != null else docket()
	var result := {}
	var why: String = docket_caller.unavailable()
	if not why.is_empty():
		return {"content_skipped": _unreached(def, "updated", why)}

	# Phase 1: classify each skill and knowledge action (no docket writes yet).
	var plan: Dictionary = await SkillSeeder.plan_reconcile(def, available_tools(manager), docket_caller)
	var has_knowledge: bool = not (def.knowledge.is_empty() and previous_def.knowledge.is_empty())
	var knowledge_plan: Dictionary = await Knowledge.plan(def, docket_caller) if has_knowledge else {}
	# A plan Docket stopped (a failed read, a changed project) is not asked
	# about, nor applied.
	if not docket_caller.incomplete().is_empty():
		return _finish(result, docket_caller, def.id, "updated")

	# Phase 2: collect user decisions for prompt_required actions.
	var changed: Array = []
	var decisions: Dictionary = await update_decisions(manager, def,
		plan.get("actions", []) + knowledge_plan.get("actions", []), consent, auto_confirm, changed)
	if not changed.is_empty():
		# Left as they are this time: neither taken nor recorded as declined,
		# so the person is asked about this version again.
		for p in [plan, knowledge_plan]:
			p["actions"] = p.get("actions", []).filter(func(action) -> bool:
				return not str(action.get("id", action.get("entry", action.get("skill", {})).get("id", ""))) in changed)
		result["content_consent_changed"] = changed
		push_warning("[PluginContentSeeding] '%s': %s changed after the person was asked, so were left as they are" % [
			def.id, ", ".join(changed)])
	var rollback: bool = consent.get("rollback", false)
	if rollback or not consent.get("seed_new", true):
		for p in [plan, knowledge_plan]:
			p["actions"] = p.get("actions", []).filter(func(action) -> bool:
				return str(action.get("action", "")) != SkillSeeder.RECONCILE_SEED)

	# Phase 3: commit.
	# A rollback retires only knowledge the attempted version wrote.
	var moving: bool = previous_def.knowledge_project != def.knowledge_project and has_knowledge \
		and not knowledge_plan.get("missing_project", false) and (rollback or consent.get("seed_new", true)) \
		and consent.get("previous_written", true)
	var journal := _journal(def, plan, knowledge_plan, decisions, previous_def.knowledge_project if moving else "")
	if not _save_journal(consent, def, journal):
		return {"content_skipped": _skipped(def, consent)}
	result["reconcile"] = await SkillSeeder.apply_reconcile(plan, decisions, docket_caller)
	if not await Knowledge._saved("", docket_caller):
		result.reconcile["failed"] = result.reconcile.get("failed", 0) + 1
	if moving:
		result["knowledge_retired"] = await Knowledge.retire(def.id, previous_def.knowledge_project, docket_caller)
	if has_knowledge:
		result["knowledge"] = await Knowledge.apply(knowledge_plan, decisions, docket_caller)
		_note_missing_project(def, knowledge_plan, result)
	await _record_written(consent, def, journal, docket_caller)
	result.merge(await recompute_reactivity(manager, docket_caller))
	return _finish(result, docket_caller, def.id, "updated")


## Replace each journal entry's planned `after` with the record as Docket
## stored it (which can differ: skill optimization values are coerced to
## integers, empty fields dropped), and save the journal again, so a
## rollback recognises the update's own text. If that save fails, the
## planned `after` stands; a skill then compares as changed since, and is
## held for the person rather than overwritten.
static func _record_written(consent: Dictionary, def, journal: Dictionary, docket_caller) -> void:
	if str(consent.get("journal_dir", "")).is_empty() or journal.entries.is_empty():
		return
	for entry in journal.entries:
		var project := str(entry.get("project", ""))
		if not project.is_empty() and not await Knowledge.project_loaded(project, docket_caller):
			continue
		var args := {"id": entry.get("id", "")}
		if not project.is_empty():
			args["project"] = project
		var stored: Dictionary = await docket_caller.call_tool("docket_get", args)
		if not Knowledge._ok(stored):
			continue
		var fields: Array = SKILL_CONTENT if str(entry.get("type", "skill")) == "skill" \
			else Knowledge.CONTENT_FIELDS[entry.type]
		var written := {}
		for field in fields:
			written[field] = stored.get(field)
		entry["after"] = written
	_save_journal(consent, def, journal)


## After an update of `attempted_def`'s plugin was rolled back, put its Docket
## content back in line with what is installed again: the restored definition,
## with no questions and every customised record keeping its text, then the
## records the update overwrote put back as they were from `journal`;
## or, when no record is left (a first install undone, or the plugin removed
## since), that text put back and then the plugin's content unseeded.
## journal_left holds the journal entries not settled yet, for a retry to
## judge again: a record whose project is not loaded, whose write or save
## failed, or that the person changed since the update (also listed in
## journal_conflicts; one since deleted is done).
static func reconcile_after_rollback(manager, attempted_def, journal: Dictionary) -> Dictionary:
	var docket_caller := docket()
	# Knowledge the attempted version wrote in a project that is not loaded
	# now is out of reach: the rest is repaired, and the repair stays
	# unfinished (complete() is false) until that project is loaded again.
	var written: bool = journal.get("knowledge_written", not attempted_def.knowledge.is_empty())
	var unreachable: bool = written and not await Knowledge.project_loaded(attempted_def.knowledge_project, docket_caller)
	var states: Array = []
	for before in journal.get("entries", []):
		states.append(await _journal_state(before, docket_caller))
	var restored = manager.get_db().get_by_id(attempted_def.id)
	var result := {}
	if restored != null:
		result = await reconcile(manager, attempted_def, restored, {"collected": true, "update_decisions": {},
			"rollback": true, "previous_written": written}, false, docket_caller)
	# The person's text goes back before an unseed, which then keeps it as
	# theirs; but only over what the update wrote (_journal_state, judged
	# before the reconcile above changed anything).
	var put_back := 0
	var left := []
	var conflicts := []
	var entries: Array = journal.get("entries", [])
	for i in entries.size():
		var before: Dictionary = entries[i]
		var project := str(before.get("project", ""))
		match states[i]:
			JOURNAL_WRITTEN:
				var changes: Dictionary = before.get("fields", {}).duplicate()
				changes["id"] = before.get("id", "")
				if not project.is_empty():
					changes["project"] = project
				# Rechecked: the project may have closed during the reconcile.
				var put: Dictionary = {"error": "not loaded"}
				if project.is_empty() or await Knowledge.project_loaded(project, docket_caller):
					put = await docket_caller.call_tool("docket_update", changes)
				if Knowledge._ok(put):
					put_back += 1
				elif not str(put.get("error", "")).begins_with("Item not found"):
					left.append(before)
			JOURNAL_RESTORED:
				if not await Knowledge._saved(project, docket_caller):
					left.append(before)
			JOURNAL_EDITED:
				# Changed since by the person: their newer text stays, and text
				# they had before the update is held until they decide.
				if before.get("accepted", true):
					left.append(before)
					conflicts.append(before)
			JOURNAL_UNREACHABLE:
				left.append(before)
	if restored == null:
		result.merge(await unseed(manager, attempted_def.id, docket_caller))
	if unreachable:
		result["knowledge_missing_project"] = attempted_def.knowledge_project
	result["customised_put_back"] = put_back
	result["journal_left"] = left
	if not conflicts.is_empty():
		result["journal_conflicts"] = conflicts
	return _finish(result, docket_caller, attempted_def.id, "put back")


## Where a journaled record stands: still as the update wrote it
## (JOURNAL_WRITTEN, including a knowledge overwrite whose seal never
## landed), already back as the journal holds it (JOURNAL_RESTORED), changed
## since (JOURNAL_EDITED), deleted (JOURNAL_GONE), or out of reach now.
static func _journal_state(before: Dictionary, docket_caller) -> String:
	var project := str(before.get("project", ""))
	# docket_* calls put an unknown project's reads and writes in the primary one.
	if not docket_caller.unavailable().is_empty() \
			or not (project.is_empty() or await Knowledge.project_loaded(project, docket_caller)):
		return JOURNAL_UNREACHABLE
	var args := {"id": before.get("id", "")}
	if not project.is_empty():
		args["project"] = project
	var current: Dictionary = await docket_caller.call_tool("docket_get", args)
	if current.has("error"):
		return JOURNAL_GONE if str(current.error).begins_with("Item not found") else JOURNAL_UNREACHABLE
	if not before.get("after") is Dictionary:
		return JOURNAL_WRITTEN
	var type := str(before.get("type", "skill"))
	var now := Knowledge.record_digest(type, current)
	if now == Knowledge.record_digest(type, before.after):
		return JOURNAL_WRITTEN
	return JOURNAL_RESTORED if now == Knowledge.record_digest(type, before.get("fields", {})) else JOURNAL_EDITED


## Whether each customised skill or knowledge record among `actions` (from
## plan_reconcile / PluginKnowledgeSeeder.plan) takes the update, keyed by its
## manifest id: from consent collected before the install began (an item not
## asked about then keeps its customisation; one accepted whose record has
## changed since it was shown is not taken, and its id is added to `changed`
## for the caller to leave that record as it is), from auto_confirm, or by
## asking.
static func update_decisions(manager, def, actions: Array, consent: Dictionary, auto_confirm: bool,
		changed: Array = []) -> Dictionary:
	var decisions := {}
	for action in actions:
		if str(action.get("action", "")) != SkillSeeder.RECONCILE_PROMPT_REQUIRED:
			continue
		var item: Dictionary = action.get("entry", action.get("skill", {}))
		var item_id := str(action.get("id", item.get("id", "")))
		if consent.get("collected", false):
			var accepted := bool(consent.get("update_decisions", {}).get(item_id, false))
			var seen: Dictionary = consent.get("update_seen", {})
			if accepted and seen.get(item_id, "") != Knowledge.record_digest(
					str(item.get("type", "skill")) if action.has("entry") else "skill", action.get("existing", {})):
				accepted = false
				changed.append(item_id)
			decisions[item_id] = accepted
		else:
			decisions[item_id] = auto_confirm or await SkillConsent.ask_update(manager, def, action.get("existing", {}), item)
	return decisions


## Whether a reconcile_after_rollback or unseed `result` finished: no Docket
## write or save failed, no project it needed was missing, and no journal
## entry is left to put back.
static func complete(result: Dictionary) -> bool:
	var knowledge: Dictionary = result.get("knowledge", {})
	var retired: Dictionary = result.get("knowledge_retired", {})
	return not result.has("content_skipped") and not result.has("content_incomplete") \
		and result.get("reconcile", {}).get("failed", 0) == 0 \
		and knowledge.get("failed", 0) == 0 and not knowledge.has("missing_project") \
		and not result.has("knowledge_missing_project") \
		and retired.get("failed", 0) == 0 and not retired.has("missing_project") \
		and result.get("skills_failed", 0) == 0 and result.get("journal_left", []).is_empty()


## Why a result that is not complete() did not finish, for the person.
static func unfinished_reason(result: Dictionary) -> String:
	var reasons: Array[String] = []
	if result.has("content_skipped"):
		reasons.append(str(result.content_skipped))
	if result.has("content_incomplete"):
		reasons.append(str(result.content_incomplete))
	for held in result.get("journal_conflicts", []):
		reasons.append("'%s' (%s) was changed since its update, so the text it had before that update, held in the file below, was not put back over the change" % [
			str(held.get("fields", {}).get("title", "")), str(held.get("id", ""))])
	if result.has("knowledge_missing_project"):
		reasons.append("Docket project '%s' is not open" % result.knowledge_missing_project)
	elif result.get("knowledge", {}).has("missing_project") or result.get("knowledge_retired", {}).has("missing_project"):
		reasons.append("a Docket project it uses is not open")
	var unwritten: int = result.get("journal_left", []).size() - result.get("journal_conflicts", []).size()
	if unwritten > 0:
		reasons.append("%d saved text(s) could not be put back (their project is not open, or could not be written)" %
			unwritten)
	if result.get("reconcile", {}).get("failed", 0) > 0 or result.get("knowledge", {}).get("failed", 0) > 0 \
			or result.get("knowledge_retired", {}).get("failed", 0) > 0 or result.get("skills_failed", 0) > 0:
		reasons.append("Docket could not save some of its changes")
	return ", and ".join(reasons) if not reasons.is_empty() else "Docket could not save some of its changes"


## What a person is told about `result`'s content beyond its counts: that it
## was not written (content_skipped), was written only in part
## (content_incomplete), or kept the text of items changed after they were
## asked about; "" when there is nothing to tell.
static func content_note(result: Dictionary) -> String:
	var notes: Array[String] = []
	for key in ["content_skipped", "content_incomplete"]:
		if result.has(key):
			notes.append(str(result[key]))
	if not result.get("content_consent_changed", []).is_empty():
		notes.append("%d customised item(s) changed after you were asked, so they kept their text" %
			result.content_consent_changed.size())
	return "; ".join(notes)


## An update's install committed: the records its knowledge_project move
## retired (journal.retired_project) are unseeded there. Returns whether
## that finished (false while the project is not loaded or a write failed).
static func content_committed(journal: Dictionary) -> bool:
	var retired := str(journal.get("retired_project", ""))
	if retired.is_empty() or not journal.get("attempted") is Dictionary:
		return true
	var docket_caller := docket()
	var unseeded: Dictionary = await Knowledge.unseed(str(journal.attempted.get("id", "")), retired, docket_caller)
	return unseeded.failed == 0 and not unseeded.has("missing_project") and docket_caller.incomplete().is_empty()


## Remove `plugin_id`'s skills and knowledge (in every loaded project):
## pristine records are deleted, customised ones become the user's
## (source "user", provenance cleared). Returns the result fields.
## `operation`, when given, is the Docket binding of an operation this is part
## of.
static func unseed(manager, plugin_id: String, operation: SeedingDocket = null) -> Dictionary:
	var docket_caller := operation if operation != null else docket()
	var why: String = docket_caller.unavailable()
	if not why.is_empty():
		var note := "%s's skills and knowledge were not removed: %s" % [plugin_id, why]
		push_warning("[PluginContentSeeding] " + note)
		return {"content_skipped": note}
	var result := {}
	var skills: Dictionary = await SkillSeeder.unseed(plugin_id, docket_caller)
	if skills.get("deleted", 0) > 0 or skills.get("kept", 0) > 0:
		result["skills_deleted"] = skills.get("deleted", 0)
		result["skills_kept"] = skills.get("kept", 0)
		result["skills_kept_ids"] = skills.get("kept_skill_ids", [])
	if skills.get("failed", 0) > 0:
		result["skills_failed"] = skills.failed
	var knowledge: Dictionary = await Knowledge.unseed_everywhere(plugin_id, docket_caller)
	if knowledge.get("deleted", 0) > 0 or knowledge.get("kept", 0) > 0 or knowledge.get("failed", 0) > 0:
		result["knowledge"] = knowledge
	result.merge(await recompute_reactivity(manager, docket_caller))
	return _finish(result, docket_caller, plugin_id, "removed")


## Recompute unsatisfied_deps for every skill record after a plugin lifecycle
## change; returns the reactivity_* result fields when anything changed.
## `operation`, when given, is the Docket binding of an operation this is
## part of (a stopped one writes nothing more).
static func recompute_reactivity(manager, operation: SeedingDocket = null) -> Dictionary:
	var docket_caller := operation if operation != null else docket()
	if not docket_caller.unavailable().is_empty():
		return {}
	var reactivity: Dictionary = await SkillSeeder.recompute_unsatisfied(available_tools(manager), docket_caller)
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


## Tests point this at their own Docket (a ToolRegistry, or a
## PluginSeedingDocket over whatever stands in for it).
static var docket_override = null


## Docket as seeding reaches it (PluginSeedingDocket), from whichever owns
## Docket's files: the embedded DocketManager while it exists, else the
## Docket plugin through DocketHost, even while that cannot be reached (the
## seeding is then reported, never done in the embedded one's place).
static func docket() -> SeedingDocket:
	if docket_override is SeedingDocket:
		return docket_override
	if docket_override != null:
		return SeedingDocket.new(docket_override, false)
	if typeof(SingletonObject) != TYPE_NIL and "docket_manager" in SingletonObject \
			and SingletonObject.docket_manager != null:
		return SeedingDocket.new(SingletonObject.docket_manager, false)
	var host = SingletonObject.get("docket_host") if typeof(SingletonObject) != TYPE_NIL else null
	if host != null and host.state != "inactive":
		return SeedingDocket.new(host, true)
	return SeedingDocket.new(null, false)


## The Docket journal for applying `def`: the definition, the project a move
## retires (or ""), and the current content of every record the update is
## about to overwrite: customised ones taking it with consent, and pristine
## knowledge (with its seal).
static func _journal(def, plan: Dictionary, knowledge_plan: Dictionary, decisions: Dictionary,
		retired_project: String) -> Dictionary:
	var entries := []
	for action in plan.get("actions", []) + knowledge_plan.get("actions", []):
		var item: Dictionary = action.get("entry", action.get("skill", {}))
		var item_id := str(action.get("id", item.get("id", "")))
		var kind := str(action.get("action", ""))
		var accepted: bool = kind == SkillSeeder.RECONCILE_PROMPT_REQUIRED and decisions.get(item_id, false)
		# A knowledge overwrite writes its text, then seals it (pristine_hash)
		# in a second write: a crash between would leave the record looking
		# customised, so silent ones are saved too, seal included.
		var silent_knowledge: bool = kind == SkillSeeder.RECONCILE_SILENT_UPDATE and action.has("entry")
		if not (accepted or silent_knowledge):
			continue
		var existing: Dictionary = action.get("existing", {})
		var fields := {}
		for field in (Knowledge.CONTENT_FIELDS[existing.type] + KNOWLEDGE_SEAL if action.has("entry") else SKILL_FIELDS):
			if existing.get(field) != null:
				fields[field] = existing[field]
		# What the update writes, so a rollback can tell it from a later edit
		# (_record_written replaces it with the form Docket stores).
		var after: Dictionary = Knowledge._content(item) if action.has("entry") else {}
		if not action.has("entry"):
			var written := SkillSeeder.build_install_record(def.id, item, action.get("unsatisfied", []))
			for field in SKILL_CONTENT:
				after[field] = written.get(field)
		entries.append({"id": str(existing.get("id", "")), "fields": fields, "after": after,
			"type": str(existing.get("type", "skill")), "accepted": accepted,
			"project": str(knowledge_plan.get("project", "")) if action.has("entry") else ""})
	# Whether applying `def` writes knowledge in its project (a plan has no
	# work there when that project is not loaded), so a rollback must reach it.
	var writes_knowledge: bool = not (knowledge_plan.get("actions", []).is_empty()
		and knowledge_plan.get("deprecate_record_ids", []).is_empty())
	return {"attempted": def.to_dict(), "retired_project": retired_project, "entries": entries,
		"knowledge_written": writes_knowledge}


## Save `journal` as the Docket journal of the install transaction in
## consent.journal_dir (none: nothing to save). Returns whether it is saved.
static func _save_journal(consent: Dictionary, def, journal: Dictionary) -> bool:
	var journal_dir := str(consent.get("journal_dir", ""))
	return journal_dir.is_empty() or Txn.save_content(journal_dir, def.id, journal)


## `result`, noting when the operation `docket_caller` served stopped before
## it finished: `plugin_id`'s content was only partly `done`
## (content_incomplete), with the changes that may or may not have been made
## (content_uncertain).
static func _finish(result: Dictionary, docket_caller: SeedingDocket, plugin_id: String, done: String) -> Dictionary:
	var why := docket_caller.incomplete()
	if why.is_empty():
		return result
	result["content_incomplete"] = "%s's skills and knowledge were only partly %s: %s" % [plugin_id, done, why]
	# Why it stopped is the reason: a project it could not bind (ambiguous,
	# unreachable) is not reported missing too.
	if not docket_caller.was_missing(str(result.get("knowledge_missing_project", ""))):
		result.erase("knowledge_missing_project")
	push_warning("[PluginContentSeeding] " + result.content_incomplete)
	if not docket_caller.uncertain().is_empty():
		result["content_uncertain"] = docket_caller.uncertain()
	return result


## Log and return that `def`'s skills and knowledge were not `done` because
## Docket could not be reached (`why`).
static func _unreached(def, done: String, why: String) -> String:
	var note := "%s's skills and knowledge were not %s: %s" % [def.id, done, why]
	push_warning("[PluginContentSeeding] " + note)
	return note


## Log and return why `def`'s skills and knowledge were left as they were.
static func _skipped(def, consent: Dictionary) -> String:
	var skipped := "%s's skills and knowledge were not updated: their undo record could not be saved in %s" % [
		def.id, Txn.content_path(str(consent.get("journal_dir", ""))).get_base_dir()]
	push_warning("[PluginContentSeeding] " + skipped)
	return skipped


## Record in `result`, and log, that `def`'s knowledge project is not loaded.
static func _note_missing_project(def, knowledge_plan: Dictionary, result: Dictionary) -> void:
	if knowledge_plan.get("missing_project", false) or result.get("knowledge", {}).has("missing_project"):
		result["knowledge_missing_project"] = def.knowledge_project
		push_warning("[PluginContentSeeding] '%s' knowledge was not seeded: Docket project '%s' is not open" % [
			def.id, def.knowledge_project])
