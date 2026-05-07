## Skill-seeding pipeline for plugin install (DCR 019df57b T3).
##
## Pure-logic helpers that resolve tool_deps, look up existing records by
## (plugin_id, manifest skill id), and materialise new skills via docket_create.
## No UI here — the install dialog is owned by PluginManager.
##
## Storage convention: a plugin-seeded skill record uses the docket `key` field
## to hold the manifest skill id (e.g. "minerva_demo_make_thing").  This is
## distinct from the docket auto-generated `id` (UUIDv7).  Lookups for
## idempotency / update reconciliation / uninstall query by source + key.
class_name PluginSkillSeeder extends RefCounted

const PluginSkillRecordScript = preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")


## Resolve tool_deps for each skill in the manifest against the available tool set.
##
## available_tools: Dictionary keyed by tool name (any value).  Typically
## SingletonObject.mcp_manager.tool_registry.  Tools declared in the plugin's
## own manifest (def.tools[].name) are always considered satisfied — they'll
## come online when the plugin starts.
##
## Returns: Array of {skill: Dictionary, unsatisfied: Array[String]}, parallel
## to def.skills, in the same order.
static func resolve_deps(def, available_tools: Dictionary) -> Array:
	var own_tool_names: Dictionary = {}
	for t in def.tools:
		var name := str(t.get("name", ""))
		if not name.is_empty():
			own_tool_names[name] = true

	var resolved: Array = []
	for skill in def.skills:
		var deps_raw = skill.get("tool_deps", [])
		var unsatisfied: Array = []
		if deps_raw is Array:
			for dep in deps_raw:
				var dep_name := str(dep)
				if dep_name.is_empty():
					continue
				if not (own_tool_names.has(dep_name) or available_tools.has(dep_name)):
					unsatisfied.append(dep_name)
		resolved.append({"skill": skill, "unsatisfied": unsatisfied})
	return resolved


## Build the docket_create payload for a plugin-seeded skill.
##
## Stores the manifest skill id in `key` for stable lookup.  Captures all
## lifecycle metadata: source, customised=false (initial), pristine_hash,
## pristine_content (verbatim manifest entry), unsatisfied_deps, deprecated=false.
static func build_install_record(plugin_id: String, skill_entry: Dictionary, unsatisfied: Array) -> Dictionary:
	var tool_deps_copy: Array = []
	if skill_entry.get("tool_deps", []) is Array:
		tool_deps_copy = (skill_entry.get("tool_deps", []) as Array).duplicate()
	var optimization_copy: Dictionary = {}
	if skill_entry.get("optimization", {}) is Dictionary:
		optimization_copy = (skill_entry.get("optimization", {}) as Dictionary).duplicate(true)

	return {
		"type": "skill",
		# Stable lookup key — manifest skill id (e.g. "minerva_demo_make_thing").
		# Distinct from the docket record's auto-generated UUIDv7 id.
		"key": str(skill_entry.get("id", "")),
		# Content fields.
		"title": str(skill_entry.get("title", "")),
		"summary": str(skill_entry.get("summary", "")),
		# Manifest uses `system_prompt`; docket's column is `prompt_text` (shared
		# with the prompt knowledge type).  Map at this boundary; the manifest's
		# verbatim copy still lives in pristine_content below.
		"prompt_text": str(skill_entry.get("system_prompt", "")),
		"outcome": str(skill_entry.get("outcome", "")),
		"preconditions": str(skill_entry.get("preconditions", "")),
		"steps": str(skill_entry.get("steps", "")),
		"tool_deps": tool_deps_copy,
		"target": str(skill_entry.get("target", "all")),
		"optimization": optimization_copy,
		# Plugin-shipped lifecycle metadata (DCR 019df57b).
		"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + plugin_id,
		"customised": false,
		"pristine_hash": PluginSkillRecordScript.compute_hash(skill_entry),
		"pristine_content": skill_entry.duplicate(true),
		"unsatisfied_deps": unsatisfied.duplicate(),
		"deprecated": false,
	}


## Look up an existing plugin-seeded skill record by (plugin_id, manifest skill id).
##
## docket_caller: any object exposing a `call_tool(name, args)` method.  In
## production this is SingletonObject.docket_manager; in tests pass a
## ToolRegistry directly (call_tool is the same shape).
##
## Returns the full record dict, or {} if none found.
static func find_existing_record(plugin_id: String, manifest_skill_id: String, docket_caller) -> Dictionary:
	if docket_caller == null:
		return {}
	var query_result = docket_caller.call_tool("docket_query", {
		"filter": {
			"type": "skill",
			"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + plugin_id,
			"key": manifest_skill_id,
		},
	})
	if not (query_result is Dictionary):
		return {}
	var items: Array = query_result.get("items", [])
	if items.is_empty():
		return {}
	# Re-fetch via docket_get for the full record (lean query may omit fields).
	var first_id := str(items[0].get("id", ""))
	if first_id.is_empty():
		return {}
	var full = docket_caller.call_tool("docket_get", {"id": first_id})
	if full is Dictionary and not full.has("error"):
		return full
	return {}


## Materialise resolved skills into the docket as new records.  Idempotent:
##
##   - No existing record       → docket_create  (counted as `seeded`)
##   - Existing, hash matches   → no action      (counted as `skipped`)
##   - Existing, hash differs   → no action      (counted as `deferred_to_update`,
##                                                T4 reconciliation handles it)
##
## Returns: {"seeded": int, "skipped": int, "deferred_to_update": int}.
## On individual create errors, logs and continues — one bad skill doesn't fail
## the whole install.
static func materialize(plugin_id: String, resolved: Array, docket_caller) -> Dictionary:
	var seeded := 0
	var skipped := 0
	var deferred := 0
	if docket_caller == null:
		return {"seeded": 0, "skipped": 0, "deferred_to_update": 0, "error": "no_docket_caller"}

	for entry in resolved:
		var skill = entry.get("skill", {})
		var unsatisfied = entry.get("unsatisfied", [])
		var manifest_skill_id := str(skill.get("id", ""))
		if manifest_skill_id.is_empty():
			continue

		var pristine_hash := PluginSkillRecordScript.compute_hash(skill)
		var existing := find_existing_record(plugin_id, manifest_skill_id, docket_caller)

		if not existing.is_empty():
			var existing_hash := str(existing.get("pristine_hash", ""))
			if existing_hash == pristine_hash:
				skipped += 1
				continue
			else:
				# Content changed since last install — T4 reconciliation owns
				# the update path (silent for pristine, prompt for customised).
				deferred += 1
				continue

		var record := build_install_record(plugin_id, skill, unsatisfied)
		var create_result = docket_caller.call_tool("docket_create", record)
		if create_result is Dictionary and not create_result.has("error"):
			seeded += 1
		else:
			push_warning("[PluginSkillSeeder] docket_create failed for skill '%s' of plugin '%s': %s" %
				[manifest_skill_id, plugin_id, str(create_result)])

	return {"seeded": seeded, "skipped": skipped, "deferred_to_update": deferred}


# ---------------------------------------------------------------------------
# Update reconciliation (DCR 019df57b T4)
# ---------------------------------------------------------------------------

## Action kinds emitted by plan_reconcile.
const RECONCILE_SEED := "seed"               # not in docket → docket_create
const RECONCILE_SILENT_UPDATE := "silent_update"  # pristine + hash differs → overwrite
const RECONCILE_PROMPT_REQUIRED := "prompt_required"  # customised + hash differs → ask user
const RECONCILE_NO_CHANGE := "no_change"     # hash matches → skip


## Phase 1 of T4: plan the reconcile actions for a new plugin manifest version.
##
## Inspects each skill in def.skills against the existing docket records and
## classifies the outcome.  Pure logic — no docket writes happen here.
## Caller is responsible for awaiting any prompts (PROMPT_REQUIRED actions)
## and then invoking apply_reconcile with the user's decisions.
##
## Returns:
##   {
##     "actions": [
##       {"action": "seed",            "skill": Dict, "unsatisfied": Array},
##       {"action": "silent_update",   "skill": Dict, "unsatisfied": Array, "record_id": "..."},
##       {"action": "prompt_required", "skill": Dict, "unsatisfied": Array, "record_id": "...", "existing": Dict},
##       {"action": "no_change",       "skill": Dict, "record_id": "..."},
##     ],
##     "deprecate_record_ids": ["...", ...],  # records to mark deprecated=true
##   }
static func plan_reconcile(def, available_tools: Dictionary, docket_caller) -> Dictionary:
	var actions: Array = []
	var deprecate_ids: Array = []
	if docket_caller == null:
		return {"actions": [], "deprecate_record_ids": []}

	# Build the set of manifest-skill-ids present in the NEW manifest.
	var current_manifest_ids: Dictionary = {}
	for skill in def.skills:
		var sid := str(skill.get("id", ""))
		if not sid.is_empty():
			current_manifest_ids[sid] = true

	# Phase 1a: classify per skill in the new manifest.
	var resolved: Array = resolve_deps(def, available_tools)
	for entry in resolved:
		var skill = entry.get("skill", {})
		var unsatisfied = entry.get("unsatisfied", [])
		var manifest_skill_id := str(skill.get("id", ""))
		if manifest_skill_id.is_empty():
			continue

		var existing := find_existing_record(def.id, manifest_skill_id, docket_caller)
		var new_hash := PluginSkillRecordScript.compute_hash(skill)

		if existing.is_empty():
			actions.append({
				"action": RECONCILE_SEED,
				"skill": skill,
				"unsatisfied": unsatisfied,
			})
			continue

		var existing_hash := str(existing.get("pristine_hash", ""))
		var record_id := str(existing.get("id", ""))
		if existing_hash == new_hash:
			actions.append({
				"action": RECONCILE_NO_CHANGE,
				"skill": skill,
				"record_id": record_id,
			})
			continue

		var is_customised: bool = bool(existing.get("customised", false))
		if not is_customised:
			actions.append({
				"action": RECONCILE_SILENT_UPDATE,
				"skill": skill,
				"unsatisfied": unsatisfied,
				"record_id": record_id,
			})
		else:
			actions.append({
				"action": RECONCILE_PROMPT_REQUIRED,
				"skill": skill,
				"unsatisfied": unsatisfied,
				"record_id": record_id,
				"existing": existing,
			})

	# Phase 1b: identify previously-installed records absent from the new manifest.
	var existing_query = docket_caller.call_tool("docket_query", {
		"filter": {
			"type": "skill",
			"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + def.id,
		},
	})
	if existing_query is Dictionary:
		var items: Array = existing_query.get("items", [])
		for item in items:
			var record_id := str(item.get("id", ""))
			if record_id.is_empty():
				continue
			var full = docket_caller.call_tool("docket_get", {"id": record_id})
			if not (full is Dictionary):
				continue
			var rec_key := str(full.get("key", ""))
			if not current_manifest_ids.has(rec_key):
				# Already deprecated? Skip — re-running reconcile shouldn't churn.
				if not bool(full.get("deprecated", false)):
					deprecate_ids.append(record_id)

	return {"actions": actions, "deprecate_record_ids": deprecate_ids}


## Phase 2 of T4: commit the planned reconcile actions to docket.
##
## decisions: Dictionary keyed by manifest skill id → bool.
##   For PROMPT_REQUIRED actions: true = accept (overwrite, keep customised),
##   false or absent = decline (refresh pristine_content for later diff,
##   leave user's edits intact).
##
## Returns counts:
##   {seeded, silent_updated, prompted_accepted, prompted_declined, deprecated, unchanged}
static func apply_reconcile(plan: Dictionary, decisions: Dictionary, docket_caller) -> Dictionary:
	var seeded := 0
	var silent_updated := 0
	var prompted_accepted := 0
	var prompted_declined := 0
	var deprecated_count := 0
	var unchanged := 0
	if docket_caller == null:
		return {"seeded": 0, "silent_updated": 0, "prompted_accepted": 0,
				"prompted_declined": 0, "deprecated": 0, "unchanged": 0}

	var actions: Array = plan.get("actions", [])
	for entry in actions:
		var action: String = str(entry.get("action", ""))
		var skill = entry.get("skill", {})
		var manifest_skill_id := str(skill.get("id", ""))
		match action:
			RECONCILE_NO_CHANGE:
				unchanged += 1
			RECONCILE_SEED:
				# Defer to materialize-style create.
				var unsatisfied = entry.get("unsatisfied", [])
				var record := build_install_record(_extract_plugin_id(plan, skill), skill, unsatisfied)
				var create_result = docket_caller.call_tool("docket_create", record)
				if create_result is Dictionary and not create_result.has("error"):
					seeded += 1
			RECONCILE_SILENT_UPDATE:
				_apply_overwrite(entry, docket_caller)
				silent_updated += 1
			RECONCILE_PROMPT_REQUIRED:
				var accepted: bool = bool(decisions.get(manifest_skill_id, false))
				if accepted:
					_apply_overwrite(entry, docket_caller)
					prompted_accepted += 1
				else:
					# Decline: keep user edits, but refresh pristine_content
					# so a later "show me what upstream changed" view has the
					# latest snapshot to diff against.
					docket_caller.call_tool("docket_update", {
						"id": str(entry.get("record_id", "")),
						"pristine_content": (skill as Dictionary).duplicate(true),
					})
					prompted_declined += 1

	# Mark deprecated.
	for record_id in plan.get("deprecate_record_ids", []):
		var update_result = docket_caller.call_tool("docket_update", {
			"id": str(record_id),
			"deprecated": true,
		})
		if update_result is Dictionary and not update_result.has("error"):
			deprecated_count += 1

	return {
		"seeded": seeded,
		"silent_updated": silent_updated,
		"prompted_accepted": prompted_accepted,
		"prompted_declined": prompted_declined,
		"deprecated": deprecated_count,
		"unchanged": unchanged,
	}


## Apply the new manifest content to an existing record, refreshing pristine_hash.
## Used by both silent_update (pristine path) and prompted_accept paths.
static func _apply_overwrite(action_entry: Dictionary, docket_caller) -> void:
	var skill: Dictionary = action_entry.get("skill", {})
	var unsatisfied: Array = action_entry.get("unsatisfied", [])
	var record_id: String = str(action_entry.get("record_id", ""))
	if record_id.is_empty():
		return
	var tool_deps_copy: Array = []
	if skill.get("tool_deps", []) is Array:
		tool_deps_copy = (skill.get("tool_deps", []) as Array).duplicate()
	var optimization_copy: Dictionary = {}
	if skill.get("optimization", {}) is Dictionary:
		optimization_copy = (skill.get("optimization", {}) as Dictionary).duplicate(true)
	docket_caller.call_tool("docket_update", {
		"id": record_id,
		"title": str(skill.get("title", "")),
		"summary": str(skill.get("summary", "")),
		# Same manifest→docket mapping as build_install_record.
		"prompt_text": str(skill.get("system_prompt", "")),
		"outcome": str(skill.get("outcome", "")),
		"preconditions": str(skill.get("preconditions", "")),
		"steps": str(skill.get("steps", "")),
		"tool_deps": tool_deps_copy,
		"target": str(skill.get("target", "all")),
		"optimization": optimization_copy,
		"pristine_hash": PluginSkillRecordScript.compute_hash(skill),
		"pristine_content": skill.duplicate(true),
		"unsatisfied_deps": unsatisfied.duplicate(),
		# Caller passes customised=true unchanged in the prompted-accept case;
		# reconciler doesn't touch the customised flag here.
	})


## Best-effort plugin-id recovery for SEED actions inside apply_reconcile.
## SEED entries don't carry plugin_id directly; we recover it from any sibling
## non-SEED entry's record's source field.  Falls back to "" if no other action
## is present (only happens for a brand-new plugin with skills, which would
## normally have gone through materialize() not reconcile()).
static func _extract_plugin_id(plan: Dictionary, skill: Dictionary) -> String:
	var manifest_id := str(skill.get("id", ""))
	# Pattern: "minerva_<plugin_id>_<rest>". Pull plugin id by stripping the
	# fixed prefix and the trailing rest (everything after the next underscore).
	if manifest_id.begins_with("minerva_"):
		var after := manifest_id.substr(8)  # drop "minerva_"
		var underscore := after.find("_")
		if underscore > 0:
			return after.substr(0, underscore)
	return ""


# ---------------------------------------------------------------------------
# Cross-plugin tool_deps reactivity (DCR 019df57b T7)
# ---------------------------------------------------------------------------

## Recompute unsatisfied_deps for every skill record after a plugin lifecycle
## change.  Called by PluginManager after install / update / uninstall settles.
##
## For each skill record (any source), compares tool_deps against the current
## available_tools.  Updates the record in docket only if unsatisfied_deps
## actually changed — avoids spurious updated_at bumps that would noise the
## audit log.
##
## Returns:
##   updated         — total records whose unsatisfied_deps was changed
##   now_satisfied   — records that went from non-empty unsat → empty (became pickable)
##   now_unsatisfied — records that went from empty unsat → non-empty (got hidden)
##
## Failures here log but don't propagate — DoD says lifecycle reactivity must
## not roll back the install/uninstall transaction that triggered it.
static func recompute_unsatisfied(available_tools: Dictionary, docket_caller) -> Dictionary:
	var updated := 0
	var now_satisfied := 0
	var now_unsatisfied := 0
	if docket_caller == null:
		return {"updated": 0, "now_satisfied": 0, "now_unsatisfied": 0}

	var query_result = docket_caller.call_tool("docket_query", {
		"filter": {"type": "skill"},
	})
	if not (query_result is Dictionary):
		return {"updated": 0, "now_satisfied": 0, "now_unsatisfied": 0}
	var items: Array = query_result.get("items", [])

	for item in items:
		var record_id := str(item.get("id", ""))
		if record_id.is_empty():
			continue
		var full = docket_caller.call_tool("docket_get", {"id": record_id})
		if not (full is Dictionary):
			continue

		var deps_raw = full.get("tool_deps", [])
		if not (deps_raw is Array):
			continue
		var current_unsat: Array = []
		var existing_unsat = full.get("unsatisfied_deps", [])
		if existing_unsat is Array:
			current_unsat = existing_unsat

		var new_unsat: Array = []
		for dep in deps_raw:
			var dep_name := str(dep)
			if dep_name.is_empty():
				continue
			if not available_tools.has(dep_name):
				new_unsat.append(dep_name)

		if _arrays_equal_unordered(new_unsat, current_unsat):
			continue

		var update_result = docket_caller.call_tool("docket_update", {
			"id": record_id,
			"unsatisfied_deps": new_unsat,
		})
		if update_result is Dictionary and not update_result.has("error"):
			updated += 1
			var was_unsat: bool = not current_unsat.is_empty()
			var is_unsat: bool = not new_unsat.is_empty()
			if was_unsat and not is_unsat:
				now_satisfied += 1
			elif not was_unsat and is_unsat:
				now_unsatisfied += 1
		else:
			push_warning("[PluginSkillSeeder] reactivity update failed for record '%s': %s" %
				[record_id, str(update_result)])

	return {"updated": updated, "now_satisfied": now_satisfied, "now_unsatisfied": now_unsatisfied}


## Order-independent array equality.  Used by recompute_unsatisfied to skip
## docket writes when the new and old lists match (regardless of element order).
static func _arrays_equal_unordered(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for x in a:
		if not b.has(x):
			return false
	return true


# ---------------------------------------------------------------------------
# Uninstall (DCR 019df57b T6)
# ---------------------------------------------------------------------------

## Handle plugin-skill cleanup at uninstall time per D5:
##   - pristine record (customised=false): hard-delete via docket_delete.
##   - customised record (customised=true): convert source → "user", clear
##     pristine_hash and pristine_content (no longer reconcilable), keep
##     unsatisfied_deps as-is (T7 will recompute when uninstall settles).
##
## No modal interruptions — DoD specifies a single toast on the UI side.
## Returns: {"deleted": int, "kept": int, "kept_skill_ids": Array[String]}.
##   kept_skill_ids contains docket UUIDs of converted records, intended for
##   the UI's toast-click → "show me the orphans" filter affordance.
static func unseed(plugin_id: String, docket_caller) -> Dictionary:
	var deleted := 0
	var kept := 0
	var kept_ids: Array = []
	if docket_caller == null:
		return {"deleted": 0, "kept": 0, "kept_skill_ids": []}

	var query_result = docket_caller.call_tool("docket_query", {
		"filter": {
			"type": "skill",
			"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + plugin_id,
		},
	})
	if not (query_result is Dictionary):
		return {"deleted": 0, "kept": 0, "kept_skill_ids": []}
	var items: Array = query_result.get("items", [])

	for item in items:
		var record_id := str(item.get("id", ""))
		if record_id.is_empty():
			continue
		# Re-fetch full record to read customised flag (lean query may omit it).
		var full = docket_caller.call_tool("docket_get", {"id": record_id})
		if not (full is Dictionary):
			continue
		var is_customised: bool = bool(full.get("customised", false))

		if is_customised:
			var update_result = docket_caller.call_tool("docket_update", {
				"id": record_id,
				"source": PluginSkillRecordScript.SOURCE_USER,
				"pristine_hash": "",
				"pristine_content": {},
			})
			if update_result is Dictionary and not update_result.has("error"):
				kept += 1
				kept_ids.append(record_id)
			else:
				push_warning("[PluginSkillSeeder] docket_update (unseed-convert) failed for record '%s': %s" %
					[record_id, str(update_result)])
		else:
			var delete_result = docket_caller.call_tool("docket_delete", {"id": record_id})
			if delete_result is Dictionary and not delete_result.has("error"):
				deleted += 1
			else:
				push_warning("[PluginSkillSeeder] docket_delete failed for record '%s': %s" %
					[record_id, str(delete_result)])

	return {"deleted": deleted, "kept": kept, "kept_skill_ids": kept_ids}
